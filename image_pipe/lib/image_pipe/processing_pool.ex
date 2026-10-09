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
            max_queue: [
              type: :non_neg_integer,
              default: 64,
              doc: """
              Most requests waiting for a turn. A request that finds the queue full \
              fails with `{:processing, :overloaded}`. With `0`, requests never wait.
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
              the original to sending the last byte. A request that takes longer \
              fails with `{:processing, :timeout}`. Its worker keeps the slot until \
              the current operation and cleanup finish.
              """
            ]
          )

  @moduledoc """
  Limits how many images are processed at once, with a queue for requests that
  wait for a turn and a deadline for each image.

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

  defp within(pool, owner, notification, config, fun) do
    # The pool monitors both lifetimes. Owner exit must not interrupt native work.
    Process.unlink(owner)

    request =
      {:acquire, owner, notification, RequestContext.capture(), Telemetry.telemetry_opts(config),
       now()}

    case call(pool, request) do
      {:ok, token, context} ->
        RequestContext.within(context, fn -> invoke_and_release(pool, token, fun) end)

      {:error, _} = error ->
        error
    end
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
  Returns the number of workers holding processing slots and of requests waiting, as
  `%{active: 3, queued: 0}`.

  Active workers include those finishing after a timeout or cancellation.
  """
  def stats(pool), do: GenServer.call(pool, :stats)

  @impl true
  def init(opts) do
    Process.flag(:trap_exit, true)

    {:ok,
     %{
       limits: Map.new(opts),
       jobs: %{},
       owners: %{},
       queue: :queue.new(),
       active: 0
     }}
  end

  @impl true
  def handle_call(:stats, _from, state) do
    {:reply, %{active: state.active, queued: :queue.len(state.queue)}, state}
  end

  def handle_call(
        {:acquire, owner, notification, context, config, requested_at},
        {worker, _} = from,
        state
      ) do
    queued? = state.active >= state.limits.max_concurrency
    span = Events.start(config, :admission, context, counts(state))

    cond do
      queued? and :queue.len(state.queue) >= state.limits.max_queue ->
        Events.stop(span, :overloaded)
        {:reply, {:error, {:processing, :overloaded}}, state}

      now() >= requested_at + state.limits.queue_timeout ->
        Events.stop(span, :queue_timeout)
        {:reply, {:error, {:processing, :queue_timeout}}, state}

      true ->
        token = Process.monitor(worker)
        owner_ref = Process.monitor(owner)

        job = %{
          worker: worker,
          owner: owner,
          notification: notification,
          owner_ref: owner_ref,
          from: from,
          context: context,
          config: config,
          span: span,
          phase: :queued,
          deadline: requested_at + state.limits.queue_timeout,
          timer: nil,
          result: nil
        }

        state = %{state | owners: Map.put(state.owners, owner_ref, token)}
        {:noreply, enqueue_or_admit(state, token, job, queued?)}
    end
  end

  def handle_call({:release, token, result}, _from, state) do
    job = Map.fetch!(state.jobs, token)
    result = job.result || if(now() >= job.deadline, do: :timeout, else: result)
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
        GenServer.reply(job.from, {:error, {:processing, :queue_timeout}})
        {:noreply, state |> complete(token, :queue_timeout) |> drain()}

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
    put_job(%{state | queue: :queue.in(token, state.queue)}, token, job)
  end

  defp admit(state, token, job) do
    cancel_timer(job.timer)
    Events.stop(job.span, :admitted)
    span = Events.start(job.config, :execute, job.context, counts(state))
    deadline = now() + state.limits.processing_timeout
    Process.link(job.worker)
    GenServer.reply(job.from, {:ok, token, Events.context(span)})

    job = %{
      job
      | phase: :active,
        span: span,
        deadline: deadline,
        timer: timer(token, :active, deadline)
    }

    put_job(%{state | active: state.active + 1}, token, job)
  end

  defp drain(state) when state.active >= state.limits.max_concurrency, do: state

  defp drain(state) do
    case :queue.out(state.queue) do
      {:empty, _} ->
        state

      {{:value, token}, queue} ->
        job = Map.fetch!(state.jobs, token)
        state = %{state | queue: queue}

        case now() < job.deadline and is_nil(job.result) do
          true ->
            state |> admit(token, job) |> drain()

          false ->
            GenServer.reply(job.from, {:error, {:processing, :queue_timeout}})
            state |> complete(token, job.result || :queue_timeout) |> drain()
        end
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
        queue: :queue.delete(token, state.queue),
        active: state.active - if(job.phase == :active, do: 1, else: 0)
    }
  end

  defp put_job(state, token, job), do: %{state | jobs: Map.put(state.jobs, token, job)}

  defp cancel_job(state, token, %{phase: :queued} = job) do
    GenServer.reply(job.from, {:error, {:processing, :cancelled}})
    state |> complete(token, :cancelled) |> drain()
  end

  defp cancel_job(state, token, %{phase: :active} = job),
    do: put_job(state, token, %{job | result: job.result || :cancelled})

  defp counts(state), do: %{active: state.active, queued: :queue.len(state.queue)}
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
