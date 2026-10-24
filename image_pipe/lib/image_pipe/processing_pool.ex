defmodule ImagePipe.ProcessingPool do
  use Boundary, top_level?: true, deps: [ImagePipe.Telemetry], exports: []
  use GenServer

  alias ImagePipe.ProcessingPool.Events
  alias ImagePipe.Telemetry
  alias ImagePipe.Telemetry.RequestContext

  @schema NimbleOptions.new!(
            name: [
              type: :atom,
              doc: "Name that `ImagePipe.config/1`'s `:processing_pool` refers to."
            ],
            max_concurrency: [
              type: :pos_integer,
              required: true,
              doc: "Most images processed at once."
            ],
            low_priority_max_concurrency: [
              type: :pos_integer,
              doc: """
              Most low-priority images processed at once. Defaults to half of \
              `:max_concurrency`, rounded down, and at least `1`.
              """
            ],
            max_queue: [
              type: :non_neg_integer,
              default: 1024,
              doc: """
              Most requests waiting for a turn. A request that finds the queue full \
              fails with `{:processing, :overloaded}`, unless it has normal priority \
              and a low-priority request is waiting. Then the newest waiting \
              low-priority request fails instead. With `0`, requests never wait. \
              The encode of an image decoded while its original downloaded is \
              a second turn for its request, and isn't counted or turned away.
              """
            ],
            queue_timeout: [
              type: :pos_integer,
              default: 10_000,
              doc: """
              Longest wait for a turn, in milliseconds. A request that waits longer \
              fails with `{:processing, :queue_timeout}`.
              """
            ],
            processing_timeout: [
              type: :pos_integer,
              default: 30_000,
              doc: """
              Request deadline once processing starts, in milliseconds, from reading \
              the original to encoding the last byte. Without a usable spool \
              directory, it also covers sending all but the last 4 MB to a slow \
              client. A request that takes longer \
              fails with `{:processing, :timeout}`. Its worker keeps the slot until \
              the current operation and cleanup finish.
              """
            ]
          )

  @moduledoc """
  Limits how many images are processed at once, with a queue for requests that
  wait for a turn and a deadline for each image.

  An `ImagePipe` instance starts one, configured with its `:pool` option,
  unless its configuration names one in `:processing_pool`. Start a pool
  yourself to share it between instances:

      children = [
        {ImagePipe.ProcessingPool, name: MyApp.Pool, max_concurrency: 8, max_queue: 16},
        {ImagePipe, name: MyApp.Images, processing_pool: MyApp.Pool, sources: [...]},
        MyAppWeb.Endpoint
      ]

  Every configuration that names the pool with `:processing_pool` shares its
  capacity, across mounts and `ImagePipe.run/4` calls on the same node.
  Workers finishing after a timeout or cancellation keep their slots until
  their operations and cleanup finish.
  [Limiting concurrent processing](processing-controls.md) covers choosing the
  limits and what counts toward them.

  ## Errors

  `ImagePipe.run/4` returns these errors, and a request gets a `503` for each:

    * `{:processing, :overloaded}` - the queue is full.
    * `{:processing, :queue_timeout}` - the request waited longer than
      `:queue_timeout`.
    * `{:processing, :timeout}` - the image took longer than
      `:processing_timeout`.
    * `{:processing, :unavailable}` - the pool isn't running.

  Over HTTP, the `503` for `:overloaded` or `:queue_timeout` has a
  `Retry-After` header: `:queue_timeout` in whole seconds, rounded up.

  A request with low priority waits for spare capacity. It starts only when
  no normal request is waiting and fewer than `:low_priority_max_concurrency`
  low-priority requests hold slots. A normal request that finds the queue
  full takes the place of the newest waiting low-priority request, which
  fails with `{:processing, :overloaded}`.

  ## Options

  #{NimbleOptions.docs(@schema)}
  """

  @doc false
  def options_schema, do: @schema.schema

  @doc "Starts a pool with validated admission and timeout options."
  def start_link(opts) do
    case NimbleOptions.validate(opts, @schema) do
      {:ok, opts} -> GenServer.start_link(__MODULE__, opts, Keyword.take(opts, [:name]))
      {:error, error} -> raise ArgumentError, Exception.message(error)
    end
  end

  @doc false
  def run(nil, fun, _config), do: fun.()

  def run(pool, fun, config) do
    owner = self()
    notification = :erlang.alias()
    request = RequestContext.capture()

    task =
      Task.Supervisor.async_nolink(ImagePipe.ProcessingPool.Tasks, fn ->
        RequestContext.adopt(request)
        task_result(pool, owner, notification, config, fun)
      end)

    try do
      await_result(task)
    after
      :erlang.unalias(notification)
    end
  end

  defp await_result(%Task{ref: ref, pid: worker} = task) do
    receive do
      {^ref, {:returned, result}} ->
        Task.ignore(task)
        result

      {^ref, {:raised, kind, reason, stacktrace}} ->
        Task.ignore(task)
        :erlang.raise(kind, reason, stacktrace)

      {:processing_timeout, ^worker} ->
        Task.ignore(task)
        {:error, {:processing, :timeout}}

      {:DOWN, ^ref, :process, ^worker, {:shutdown, {:processing, reason}}} ->
        {:error, {:processing, reason}}

      {:DOWN, ^ref, :process, ^worker, _reason} ->
        {:error, {:processing, :worker_down}}
    end
  end

  defp task_result(pool, owner, notification, config, fun) do
    {:returned, within(pool, owner, notification, config, fun)}
  catch
    :exit, {:shutdown, {:processing, _} = reason} -> {:returned, {:error, reason}}
    kind, reason -> {:raised, kind, reason, __STACKTRACE__}
  end

  @doc false
  def within(nil, _owner, _config, fun), do: fun.()

  def within(pool, owner, config, fun) do
    within(pool, owner, owner, config, fun)
  end

  @doc false
  def within(nil, _owner, _notification, _config, fun), do: fun.()

  def within(pool, owner, notification, config, fun) do
    case acquire(pool, owner, notification, config) do
      {:ok, token, context, _deadline} ->
        RequestContext.within(context, fn -> invoke_and_release(pool, token, fun) end)

      {:error, _} = error ->
        error
    end
  end

  @doc false
  # Like `within/5`, but returns `{:ok, result, deadline}` with the turn's
  # processing deadline, which a later turn for the same request continues
  # with through the `:processing_continuation` config key. Without a pool
  # there is no deadline.
  def within_turn(nil, _owner, _notification, _config, fun), do: {:ok, fun.(), nil}

  def within_turn(pool, owner, notification, config, fun) do
    case acquire(pool, owner, notification, config) do
      {:ok, token, context, deadline} ->
        result = RequestContext.within(context, fn -> invoke_and_release(pool, token, fun) end)
        {:ok, result, deadline}

      {:error, _} = error ->
        error
    end
  end

  defp acquire(pool, owner, notification, config) do
    # The pool monitors both lifetimes. Owner exit must not interrupt native work.
    Process.unlink(owner)

    call(
      pool,
      {:acquire, owner, notification, RequestContext.capture(), Telemetry.telemetry_opts(config),
       Keyword.get(config, :processing_priority, :normal), now(),
       Keyword.get(config, :processing_continuation)}
    )
  end

  @doc false
  def cancel(pool, worker), do: call(pool, {:cancel, worker})

  defp invoke_and_release(pool, token, fun) do
    result = invoke(pool, token, fun)

    case call(pool, {:release, token, outcome(result)}) do
      :ok -> result
      {:error, _reason} = error -> error
    end
  end

  defp invoke(pool, token, fun) do
    fun.()
  catch
    kind, reason ->
      call(pool, {:release, token, :processing_error})
      :erlang.raise(kind, reason, __STACKTRACE__)
  end

  @doc """
  Returns the number of workers holding processing slots and of requests
  waiting, in total and for low priority, as
  `%{active: 3, queued: 1, low_active: 1, low_queued: 1}`.

  Active workers include those finishing after a timeout or cancellation.
  """
  def stats(pool), do: GenServer.call(pool, :stats)

  @doc false
  # Seconds until every request queued now has started or timed out, for a
  # `Retry-After` header, or nil when the pool isn't running. Read without a
  # call, since the pool's queue is longest exactly when this is needed.
  def retry_after(pool) do
    case GenServer.whereis(pool) do
      pid when is_pid(pid) -> :persistent_term.get({__MODULE__, pid, :retry_after}, nil)
      nil -> nil
    end
  end

  @impl true
  def init(opts) do
    Process.flag(:trap_exit, true)

    limits =
      opts
      |> Map.new()
      |> Map.put_new_lazy(:low_priority_max_concurrency, fn ->
        max(div(opts[:max_concurrency], 2), 1)
      end)

    :persistent_term.put({__MODULE__, self(), :retry_after}, ceil(limits.queue_timeout / 1000))

    {:ok,
     %{
       limits: limits,
       jobs: %{},
       owners: %{},
       queues: %{continuation: :queue.new(), normal: :queue.new(), low: :queue.new()},
       active: 0,
       low_active: 0
     }}
  end

  @impl true
  def handle_call(:stats, _from, state) do
    stats =
      Map.merge(counts(state), %{
        low_active: state.low_active,
        low_queued: :queue.len(state.queues.low)
      })

    {:reply, stats, state}
  end

  # A continuation is a later turn for a request that already held one, such
  # as the encode after an overlapped decode. It keeps that turn's processing
  # deadline, waits in its own queue that is served first, in order, and is
  # never turned away as overloaded. Overlap never runs for low priority, so
  # it has normal priority.
  def handle_call(
        {:acquire, owner, notification, context, config, priority, _requested_at, deadline},
        from,
        state
      )
      when is_integer(deadline) do
    span =
      Events.start(
        config,
        :admission,
        context,
        Map.merge(counts(state), %{priority: priority, continuation: true})
      )

    if now() >= deadline do
      Events.stop(span, :timeout)
      {:reply, {:error, {:processing, :timeout}}, state}
    else
      job =
        new_job(from, {owner, notification, context, config, priority}, span, deadline, deadline)

      queued? = not admissible?(state, priority)
      {:noreply, enqueue_or_admit(track(state, job), job.token, job, queued?)}
    end
  end

  def handle_call(
        {:acquire, owner, notification, context, config, priority, requested_at, nil},
        from,
        state
      ) do
    queued? = not admissible?(state, priority)

    span =
      Events.start(
        config,
        :admission,
        context,
        Map.merge(counts(state), %{priority: priority, continuation: false})
      )

    expired? = now() >= requested_at + state.limits.queue_timeout
    state = if queued? and not expired?, do: make_room(state, priority), else: state

    cond do
      queued? and waiting(state) >= state.limits.max_queue ->
        Events.stop(span, :overloaded)
        {:reply, {:error, {:processing, :overloaded}}, state}

      expired? ->
        Events.stop(span, :queue_timeout)
        {:reply, {:error, {:processing, :queue_timeout}}, state}

      true ->
        deadline = requested_at + state.limits.queue_timeout
        job = new_job(from, {owner, notification, context, config, priority}, span, deadline, nil)
        {:noreply, enqueue_or_admit(track(state, job), job.token, job, queued?)}
    end
  end

  def handle_call({:release, token, result}, _from, state) do
    job = Map.fetch!(state.jobs, token)
    result = job.result || release_result(job, result)
    state = complete(state, token, result)
    reply = if result in [:timeout, :cancelled], do: {:error, {:processing, result}}, else: :ok
    {:reply, reply, drain(state)}
  end

  def handle_call({:cancel, worker}, _from, state) do
    case Enum.find(state.jobs, fn {_token, job} -> job.worker == worker end) do
      {token, job} -> {:reply, :ok, cancel_job(state, token, job)}
      nil -> {:reply, :ok, state}
    end
  end

  @impl true
  def handle_info({:deadline, token, phase, deadline}, state) do
    case Map.fetch(state.jobs, token) do
      {:ok, %{phase: :queued, deadline: ^deadline} = job} when phase == :queued ->
        GenServer.reply(job.from, {:error, {:processing, expiry(job)}})
        {:noreply, state |> complete(token, expiry(job)) |> drain()}

      {:ok, %{phase: :active, deadline: ^deadline, result: nil} = job} when phase == :active ->
        send(job.notification, {:processing_timeout, job.worker})
        {:noreply, put_job(state, token, %{job | result: :timeout})}

      _expired_timer ->
        {:noreply, state}
    end
  end

  def handle_info({:DOWN, ref, :process, _pid, _reason}, state) do
    case Map.fetch(state.owners, ref) do
      {:ok, token} ->
        job = Map.fetch!(state.jobs, token)
        {:noreply, cancel_job(state, token, job)}

      :error ->
        case Map.fetch(state.jobs, ref) do
          {:ok, job} ->
            {:noreply, state |> complete(ref, job.result || :worker_down) |> drain()}

          :error ->
            {:noreply, state}
        end
    end
  end

  def handle_info({:EXIT, _pid, _reason}, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state) do
    :persistent_term.erase({__MODULE__, self(), :retry_after})

    Enum.each(state.jobs, fn {_token, job} ->
      Process.exit(job.worker, {:shutdown, {:processing, :unavailable}})
      Events.stop(job.span, :unavailable)
    end)
  end

  @impl true
  def format_status(status), do: Map.put(status, :state, counts(status.state))

  defp enqueue_or_admit(state, token, job, false), do: admit(state, token, job)

  defp enqueue_or_admit(state, token, job, true) do
    job = %{job | timer: timer(token, :queued, job.deadline)}
    queues = Map.update!(state.queues, job.queue, &:queue.in(token, &1))
    put_job(%{state | queues: queues}, token, job)
  end

  defp new_job(
         from,
         {owner, notification, context, config, priority},
         span,
         deadline,
         continuation
       ) do
    {worker, _tag} = from

    %{
      token: Process.monitor(worker),
      worker: worker,
      owner: owner,
      notification: notification,
      owner_ref: Process.monitor(owner),
      from: from,
      context: context,
      config: config,
      priority: priority,
      span: span,
      phase: :queued,
      deadline: deadline,
      continuation: continuation,
      queue: if(continuation, do: :continuation, else: priority),
      timer: nil,
      result: nil
    }
  end

  defp track(state, job), do: %{state | owners: Map.put(state.owners, job.owner_ref, job.token)}

  # A continuation's queued deadline is its processing deadline.
  defp expiry(%{continuation: nil}), do: :queue_timeout
  defp expiry(_continuation), do: :timeout

  # A low-priority request takes a free slot only under its own limit.
  defp admissible?(state, :normal), do: state.active < state.limits.max_concurrency

  defp admissible?(state, :low),
    do:
      admissible?(state, :normal) and
        state.low_active < state.limits.low_priority_max_concurrency

  # A normal request that finds the queue full takes the place of the newest
  # low-priority waiter.
  defp make_room(state, :normal) do
    with true <- waiting(state) >= state.limits.max_queue,
         {{:value, token}, _rest} <- :queue.out_r(state.queues.low) do
      job = Map.fetch!(state.jobs, token)
      GenServer.reply(job.from, {:error, {:processing, :overloaded}})
      complete(state, token, :overloaded)
    else
      _ -> state
    end
  end

  defp make_room(state, :low), do: state

  defp admit(state, token, job) do
    cancel_timer(job.timer)
    Events.stop(job.span, :admitted)

    span =
      Events.start(
        job.config,
        :execute,
        job.context,
        Map.put(counts(state), :priority, job.priority)
      )

    deadline = job.continuation || now() + state.limits.processing_timeout
    Process.link(job.worker)
    GenServer.reply(job.from, {:ok, token, Events.context(span), deadline})

    job = %{
      job
      | phase: :active,
        span: span,
        deadline: deadline,
        timer: timer(token, :active, deadline)
    }

    low_active = state.low_active + if(job.priority == :low, do: 1, else: 0)
    put_job(%{state | active: state.active + 1, low_active: low_active}, token, job)
  end

  defp drain(state) do
    case next_waiter(state) do
      nil ->
        state

      name ->
        {{:value, token}, queue} = :queue.out(Map.fetch!(state.queues, name))
        job = Map.fetch!(state.jobs, token)
        state = %{state | queues: %{state.queues | name => queue}}

        case now() < job.deadline and is_nil(job.result) do
          true ->
            state |> admit(token, job) |> drain()

          false ->
            GenServer.reply(job.from, {:error, {:processing, expiry(job)}})
            state |> complete(token, job.result || expiry(job)) |> drain()
        end
    end
  end

  # Strict priority: continuations first, then normal waiters, and a
  # low-priority waiter only when no normal one is waiting.
  defp next_waiter(state) do
    cond do
      not admissible?(state, :normal) -> nil
      not :queue.is_empty(state.queues.continuation) -> :continuation
      not :queue.is_empty(state.queues.normal) -> :normal
      not :queue.is_empty(state.queues.low) and admissible?(state, :low) -> :low
      true -> nil
    end
  end

  defp complete(state, token, result) do
    {job, jobs} = Map.pop!(state.jobs, token)
    cancel_timer(job.timer)
    Process.unlink(job.worker)
    Process.demonitor(token, [:flush])
    Process.demonitor(job.owner_ref, [:flush])
    Events.stop(job.span, result)

    %{
      state
      | jobs: jobs,
        owners: Map.delete(state.owners, job.owner_ref),
        queues: Map.update!(state.queues, job.queue, &:queue.delete(token, &1)),
        active: state.active - if(job.phase == :active, do: 1, else: 0),
        low_active:
          state.low_active - if(job.phase == :active and job.priority == :low, do: 1, else: 0)
    }
  end

  defp put_job(state, token, job), do: %{state | jobs: Map.put(state.jobs, token, job)}

  defp cancel_job(state, token, %{phase: :queued} = job) do
    GenServer.reply(job.from, {:error, {:processing, :cancelled}})
    state |> complete(token, :cancelled) |> drain()
  end

  defp cancel_job(state, token, %{phase: :active} = job),
    do: put_job(state, token, %{job | result: job.result || :cancelled})

  defp counts(state), do: %{active: state.active, queued: queued(state)}
  defp queued(state), do: :queue.len(state.queues.continuation) + waiting(state)

  # The requests `max_queue` limits. Continuations held a turn already, so
  # they wait on top of it.
  defp waiting(state), do: :queue.len(state.queues.normal) + :queue.len(state.queues.low)
  # A worker finishing after its deadline, before the timer fires, times out
  # as if the timer had fired, including the notification its owner waits on.
  defp release_result(job, result) do
    if now() >= job.deadline do
      send(job.notification, {:processing_timeout, job.worker})
      :timeout
    else
      result
    end
  end

  defp now, do: System.monotonic_time(:millisecond)

  defp timer(token, phase, deadline),
    do: Process.send_after(self(), {:deadline, token, phase, deadline}, max(0, deadline - now()))

  defp cancel_timer(nil), do: :ok
  defp cancel_timer(ref), do: Process.cancel_timer(ref)
  defp outcome({:error, _}), do: :processing_error
  defp outcome({:reply, _, _, {:error, _}}), do: :processing_error
  defp outcome({:reply, _, _, :ok}), do: :cancelled
  defp outcome(:halted), do: :cancelled
  defp outcome(_), do: :ok

  defp call(pool, message) do
    GenServer.call(pool, message, :infinity)
  catch
    :exit, _reason -> {:error, {:processing, :unavailable}}
  end
end
