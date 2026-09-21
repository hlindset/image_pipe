defmodule ImagePipe.ProcessingPool do
  @moduledoc """
  Node-local admission and deadlines for image processing.

  Start under your supervision tree and select the same pool in each mount or
  Elixir client that should share its capacity:

      {ImagePipe.ProcessingPool,
       name: MyApp.Images, max_concurrency: 4, max_queue: 8,
       queue_timeout: 1_000, processing_timeout: 30_000}

      ImagePipe.config(processing_pool: MyApp.Images, sources: sources)

  `:max_concurrency` is required. `:max_queue` defaults to zero (reject overflow),
  `:queue_timeout` to 1,000 ms, and `:processing_timeout` to 30,000 ms. Both
  timeouts must be finite positive integers. Waiting is FIFO. All generated
  terminals, including `info`, share the pool; cached responses bypass it.

  The processing deadline starts on admission and includes source consumption,
  decode, transforms, encoding, and demand pauses until the stream is closed.
  Source transfer and delivery call timeouts remain separate limits.

  Cancellation terminates the BEAM worker. Native operations may finish later;
  this is not a hard CPU-preemption or native-memory ceiling. A permit remains
  occupied until its worker returns from its resource brackets or goes down.
  """
  use Boundary, top_level?: true, deps: [ImagePipe.Telemetry], exports: []
  use GenServer

  alias ImagePipe.ProcessingPool.Events
  alias ImagePipe.Telemetry
  alias ImagePipe.Telemetry.Trace.Stack

  @schema NimbleOptions.new!(
            name: [type: :atom],
            max_concurrency: [type: :pos_integer, required: true],
            max_queue: [type: :non_neg_integer, default: 0],
            queue_timeout: [type: :pos_integer, default: 1_000],
            processing_timeout: [type: :pos_integer, default: 30_000]
          )

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
    context = Stack.context()

    task =
      Task.Supervisor.async_nolink(ImagePipe.ProcessingPool.Tasks, fn ->
        Stack.adopt(context)
        task_result(pool, owner, config, fun)
      end)

    case Task.yield(task, :infinity) do
      {:ok, {:returned, result}} ->
        result

      {:ok, {:raised, kind, reason, stacktrace}} ->
        :erlang.raise(kind, reason, stacktrace)

      {:exit, {:shutdown, {:processing, reason}}} ->
        {:error, {:processing, reason}}

      {:exit, _reason} ->
        {:error, {:processing, :worker_down}}
    end
  end

  @doc false
  def run(pool, fun), do: run(pool, fun, [])

  defp task_result(pool, owner, config, fun) do
    {:returned, within(pool, owner, config, fun)}
  catch
    :exit, {:shutdown, {:processing, _} = reason} -> {:returned, {:error, reason}}
    kind, reason -> {:raised, kind, reason, __STACKTRACE__}
  end

  @doc false
  def within(nil, _owner, _config, fun), do: fun.()

  def within(pool, owner, config, fun) do
    request = {:acquire, owner, Stack.context(), Telemetry.telemetry_opts(config), now()}

    case call(pool, request) do
      {:ok, token, context} ->
        Stack.adopt(context)

        try do
          result = invoke(pool, token, fun)

          case call(pool, {:release, token, outcome(result)}) do
            :ok -> result
            {:error, reason} -> exit({:shutdown, reason})
          end
        after
          if context, do: Stack.pop()
        end

      {:error, _} = error ->
        error
    end
  end

  defp invoke(pool, token, fun) do
    fun.()
  catch
    kind, reason ->
      call(pool, {:release, token, :processing_error})
      :erlang.raise(kind, reason, __STACKTRACE__)
  end

  @doc "Returns current running and queued job counts."
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

  def handle_call({:acquire, owner, context, config, requested_at}, {worker, _} = from, state) do
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
    reply = if result == :timeout, do: {:error, {:processing, :timeout}}, else: :ok
    {:reply, reply, drain(state)}
  end

  @impl true
  def handle_info({:deadline, token, phase, deadline}, state) do
    case Map.fetch(state.jobs, token) do
      {:ok, %{phase: :queued, deadline: ^deadline} = job} when phase == :queued ->
        GenServer.reply(job.from, {:error, {:processing, :queue_timeout}})
        {:noreply, state |> complete(token, :queue_timeout) |> drain()}

      {:ok, %{phase: :active, deadline: ^deadline} = job} when phase == :active ->
        Process.exit(job.worker, {:shutdown, {:processing, :timeout}})
        {:noreply, put_job(state, token, %{job | result: :timeout})}

      _expired_timer ->
        {:noreply, state}
    end
  end

  def handle_info({:DOWN, ref, :process, _pid, _reason}, state) do
    case Map.fetch(state.owners, ref) do
      {:ok, token} ->
        job = Map.fetch!(state.jobs, token)
        Process.exit(job.worker, {:shutdown, {:processing, :cancelled}})
        {:noreply, put_job(state, token, %{job | result: job.result || :cancelled})}

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
