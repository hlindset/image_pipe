defmodule ImagePipe.Cache.SharedFileSystem.Retainer do
  @moduledoc false
  use GenServer

  alias ImagePipe.Cache.SharedFileSystem.{Generation, Partition, Retention}
  alias ImagePipe.Cache.SharedFileSystem.IO.Admission

  @enforce_keys [:pid, :gate]
  defstruct @enforce_keys

  @schema NimbleOptions.new!(
            pool: [type: :any, required: true],
            tasks: [type: :pid, required: true],
            partition: [type: :any, required: true],
            limits: [type: :map, required: true],
            max_bytes: [type: :pos_integer, default: 128 * 1024 * 1024],
            max_entries: [type: :pos_integer, default: 4_096],
            max_victims: [type: :pos_integer, default: 16],
            max_pending: [type: :pos_integer, default: 32],
            max_request_bytes: [type: :pos_integer, default: 64 * 1024],
            timeout: [type: :pos_integer, default: 1_000]
          )

  def start_link(opts),
    do: GenServer.start_link(__MODULE__, NimbleOptions.validate!(opts, @schema))

  def client(pid), do: GenServer.call(pid, :client)
  def request(client, kind, key, timeout), do: call(client, {:request, kind, key}, timeout)
  def consider(client, descriptor, timeout), do: call(client, {:consider, descriptor}, timeout)
  def stats(client, timeout), do: call(client, :stats, timeout)
  def usage(client, timeout), do: call(client, :usage, timeout)
  def retry_cleanup(client, timeout), do: call(client, :retry_cleanup, timeout)
  def rotate(client, partition, timeout), do: call(client, {:rotate, partition}, timeout)
  def inventory(client, limit, timeout), do: call(client, {:inventory, limit}, timeout)
  def resize(client, capacity, timeout), do: call(client, {:resize, capacity}, timeout)

  def publish(client, kind, key, path, metadata, size, timeout),
    do: call(client, {:publish, kind, key, path, metadata, size}, timeout)

  defp call(client, message, timeout) do
    with {:ok, ticket} <- Admission.claim(client.gate, message) do
      GenServer.call(client.pid, {:admitted, ticket, message, now() + timeout}, timeout)
    end
  catch
    :exit, {:timeout, _call} -> {:error, :timeout}
    :exit, _reason -> {:error, :unavailable}
  end

  @impl true
  def init(opts) do
    gate = Admission.new(opts[:max_pending], opts[:max_request_bytes])
    Process.send_after(self(), :watch_admission, 1_000)

    policy =
      Retention.new(
        max_bytes: opts[:max_bytes],
        max_entries: opts[:max_entries],
        max_victims: opts[:max_victims],
        window_ratio: 0.01,
        protected_ratio: 0.8,
        sketch: [depth: 4, width: 4_096, sample_size: 40_960]
      )

    {:ok,
     %{opts: opts, gate: gate, monitors: %{}, policy: policy, job: nil, debt: 0, failure: nil}}
  end

  @impl true
  def handle_call(:client, _from, state),
    do: {:reply, %__MODULE__{pid: self(), gate: state.gate}, state}

  def handle_call({:admitted, ticket, message, deadline}, from, state) do
    Admission.release(state.gate, ticket)
    state = %{state | monitors: Admission.forget(state.monitors, ticket)}

    case deadline > now() do
      true -> accepted(message, from, deadline, state)
      false -> {:reply, {:error, :timeout}, state}
    end
  end

  defp accepted({:publish, kind, key, path, metadata, size}, from, deadline, state) do
    case {state.job, state.failure, state.opts[:partition]} do
      {nil, nil, %Partition{} = partition} ->
        plan = Partition.plan(partition, kind, key)

        case Generation.planned_descriptor(plan, metadata, size, state.opts[:limits]) do
          {:ok, candidate} ->
            publish_candidate(state, candidate, plan, path, metadata, from, deadline)

          error ->
            {:reply, error, state}
        end

      {_job, nil, %Partition{}} ->
        {:reply, {:error, :saturated}, state}

      _unavailable ->
        {:reply, {:error, :unavailable}, state}
    end
  end

  defp accepted(message, _from, _deadline, state), do: dispatch(message, state)

  defp publish_candidate(state, candidate, plan, path, metadata, from, deadline) do
    opts = state.opts

    case Retention.offer(state.policy, candidate) do
      {:reject, reason, _unchanged} ->
        {:reply, {:error, {:admission, reason}}, state}

      {:admit, _speculative, _victims} ->
        task =
          Task.Supervisor.async_nolink(opts[:tasks], fn ->
            Generation.publish_retained(
              opts[:pool],
              plan,
              path,
              metadata,
              opts[:limits],
              min(opts[:timeout], max(deadline - now(), 0))
            )
          end)

        {:noreply,
         %{
           state
           | job: %{
               ref: task.ref,
               phase: :publish,
               candidate: candidate,
               from: from,
               partition: opts[:partition]
             }
         }}
    end
  end

  defp dispatch({:rotate, partition}, state) do
    cond do
      state.opts[:partition] == partition ->
        {:reply, :ok, state}

      state.job != nil and state.failure == nil ->
        {:reply, {:error, :saturated}, state}

      true ->
        {:reply, :ok,
         %{
           state
           | opts: Keyword.put(state.opts, :partition, partition),
             policy: Retention.clear(state.policy)
         }}
    end
  end

  defp dispatch({:request, kind, key}, state),
    do: {:reply, :ok, %{state | policy: Retention.request(state.policy, kind, key)}}

  defp dispatch({:resize, capacity}, %{job: nil, failure: nil} = state) do
    {policy, victims, status} =
      Retention.resize(state.policy, min(capacity, state.opts[:max_bytes]))

    state = %{state | policy: policy, job: %{partition: state.opts[:partition]}}
    {:reply, {:ok, status}, cleanup(state, victims)}
  end

  defp dispatch({:resize, _capacity}, %{failure: nil} = state),
    do: {:reply, {:error, :saturated}, state}

  defp dispatch({:resize, _capacity}, state),
    do: {:reply, {:error, :unavailable}, state}

  defp dispatch({:inventory, limit}, state) do
    locations = Enum.map(Retention.ranked(state.policy, limit), & &1.location)
    {:reply, {:ok, state.opts[:partition], locations}, state}
  end

  defp dispatch(:stats, state), do: {:reply, usage_stats(state), state}

  defp dispatch(:usage, state),
    do: {:reply, {:ok, state.opts[:partition], usage_stats(state)}, state}

  defp dispatch(
         :retry_cleanup,
         %{failure: failure, job: %{phase: :cleanup, victims: victims}} = state
       )
       when not is_nil(failure),
       do: {:reply, :scheduled, cleanup(%{state | failure: nil}, victims)}

  defp dispatch(:retry_cleanup, state), do: {:reply, {:error, :unavailable}, state}

  defp dispatch({:consider, _descriptor}, %{failure: failure} = state) when not is_nil(failure),
    do: {:reply, {:error, :unavailable}, state}

  defp dispatch({:consider, descriptor}, %{job: %{candidate: candidate}} = state) do
    result =
      if descriptor.key_hash == candidate.key_hash, do: :coalesced, else: {:error, :saturated}

    {:reply, result, state}
  end

  defp dispatch({:consider, _descriptor}, %{job: job} = state) when not is_nil(job),
    do: {:reply, {:error, :saturated}, state}

  defp dispatch({:consider, descriptor}, state) do
    location = descriptor.location

    case Retention.retained(state.policy, location.kind, location.key) do
      nil -> schedule(state, descriptor)
      _retained -> {:reply, :retained, state}
    end
  end

  defp schedule(state, descriptor) do
    opts = state.opts
    source = descriptor.location
    plan = Partition.plan(opts[:partition], source.kind, source.key)
    location = Partition.location(plan.parent, plan.kind, plan.key, plan.generation)
    candidate = %{descriptor | location: location}

    case Retention.offer(state.policy, candidate) do
      {:reject, reason, _unchanged} ->
        {:reply, {:rejected, reason}, state}

      {:admit, _speculative, _victims} ->
        task =
          Task.Supervisor.async_nolink(opts[:tasks], fn ->
            Generation.adopt(opts[:pool], plan, source, opts[:limits], opts[:timeout])
          end)

        {:reply, :scheduled,
         %{
           state
           | job: %{
               ref: task.ref,
               phase: :adopt,
               candidate: candidate,
               partition: opts[:partition]
             }
         }}
    end
  end

  @impl true
  def handle_info({ref, result}, %{job: %{ref: ref}} = state) do
    Process.demonitor(ref, [:flush])
    reply_publication(state.job, result)
    {:noreply, complete(state, result)}
  end

  def handle_info({:DOWN, ref, :process, _pid, reason}, state) do
    case Map.pop(state.monitors, ref) do
      {nil, _monitors} ->
        {:noreply, failed_job(state, ref, reason)}

      {ticket, monitors} ->
        Admission.release(state.gate, ticket)
        {:noreply, %{state | monitors: monitors}}
    end
  end

  def handle_info(:watch_admission, state) do
    monitors = Admission.watch(state.gate, state.monitors)
    Process.send_after(self(), :watch_admission, 1_000)
    {:noreply, %{state | monitors: monitors}}
  end

  defp reply_publication(%{phase: :publish, from: from}, {:ok, descriptor}),
    do: GenServer.reply(from, {:ok, descriptor.location})

  defp reply_publication(%{phase: :publish, from: from}, error), do: GenServer.reply(from, error)
  defp reply_publication(_job, _result), do: :ok

  defp complete(%{job: %{phase: :publish}} = state, {:ok, candidate}),
    do: retain(%{state | job: %{state.job | candidate: candidate}}, candidate)

  defp complete(%{job: %{phase: :adopt, candidate: candidate}} = state, {:ok, _location}),
    do: retain(state, candidate)

  defp complete(%{job: %{phase: phase}} = state, {:error, reason})
       when phase in [:adopt, :publish] and
              reason in [:enoent, :corrupt, :body_too_large, :metadata_too_large, :saturated],
       do: %{state | job: nil}

  defp complete(%{job: %{phase: :cleanup}} = state, :ok),
    do: %{state | job: nil, debt: 0}

  defp complete(state, error), do: %{state | failure: error}

  defp retain(state, candidate) do
    case Retention.offer(state.policy, candidate) do
      {:admit, policy, victims} -> cleanup(%{state | policy: policy}, victims)
      {:reject, _reason, _unchanged} -> cleanup(state, [candidate])
    end
  end

  defp cleanup(state, []), do: %{state | job: nil}

  defp cleanup(state, victims) do
    opts = state.opts
    locations = Enum.map(victims, & &1.location)

    task =
      Task.Supervisor.async_nolink(opts[:tasks], fn ->
        Generation.evict(
          opts[:pool],
          state.job.partition,
          locations,
          opts[:limits],
          opts[:timeout]
        )
      end)

    %{
      state
      | job: Map.merge(state.job, %{ref: task.ref, phase: :cleanup, victims: victims}),
        debt: Enum.sum(Enum.map(victims, & &1.size_bytes))
    }
  end

  defp failed_job(%{job: %{ref: ref}} = state, ref, reason) do
    reply_publication(state.job, {:error, :unavailable})
    %{state | failure: {:worker_down, reason}}
  end

  defp failed_job(state, _ref, _reason), do: state

  defp pending_bytes(%{phase: phase, candidate: candidate}) when phase in [:adopt, :publish],
    do: candidate.size_bytes

  defp pending_bytes(_job), do: 0

  defp usage_stats(state),
    do:
      Map.merge(Retention.stats(state.policy), %{
        jobs: if(state.job, do: 1, else: 0),
        pending_bytes: pending_bytes(state.job),
        cleanup_bytes: state.debt,
        failure: state.failure
      })

  defp now, do: System.monotonic_time(:millisecond)

  @impl true
  def format_status(_status), do: %{state: :redacted}
end
