defmodule ImagePipe.Cache.SharedFileSystem.Retainer do
  @moduledoc false
  use GenServer

  alias ImagePipe.Cache.SharedFileSystem.{Generation, Locations, Partition, Retention}
  alias ImagePipe.Cache.SharedFileSystem.IO.Admission
  alias ImagePipe.Telemetry

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
            timeout: [type: :pos_integer, default: 1_000],
            telemetry_prefix: [type: {:list, :atom}, default: [:image_pipe]]
          )

  def start_link(opts),
    do: GenServer.start_link(__MODULE__, NimbleOptions.validate!(opts, @schema))

  def client(pid), do: GenServer.call(pid, :client)
  def request(client, kind, key, timeout), do: call(client, {:request, kind, key}, timeout)

  def consider(client, descriptor, timeout, locations \\ nil),
    do: call(client, {:consider, descriptor, locations}, timeout)

  def stats(client, timeout), do: call(client, :stats, timeout)
  def usage(client, timeout), do: call(client, :usage, timeout)
  def retry(client, timeout), do: call(client, :retry, timeout)
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

    case offer(state, candidate, :publish) do
      {:reject, reason, _unchanged} ->
        {:reply, {:error, {:admission, reason}}, state}

      {:admit, _speculative, _victims} ->
        receipt = make_ref()
        observer = {self(), receipt}

        task =
          Task.Supervisor.async_nolink(opts[:tasks], fn ->
            Generation.publish_retained(
              opts[:pool],
              plan,
              path,
              metadata,
              opts[:limits],
              min(opts[:timeout], max(deadline - now(), 0)),
              observer
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
               receipt: receipt,
               completion: nil,
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

  defp dispatch(:usage, state) do
    report(state, :usage)
    {:reply, {:ok, state.opts[:partition], usage_stats(state)}, state}
  end

  defp dispatch(
         :retry,
         %{failure: failure, job: %{phase: :cleanup, victims: victims}} = state
       )
       when not is_nil(failure),
       do: {:reply, :scheduled, cleanup(%{state | failure: nil}, victims)}

  defp dispatch(:retry, %{failure: failure, job: %{phase: :reconcile}} = state)
       when not is_nil(failure), do: {:reply, :scheduled, reconcile(state)}

  defp dispatch(:retry, %{failure: nil} = state), do: {:reply, :idle, state}
  defp dispatch(:retry, state), do: {:reply, {:error, :unavailable}, state}

  defp dispatch({:consider, _descriptor, _locations}, %{failure: failure} = state)
       when not is_nil(failure),
       do: {:reply, {:error, :unavailable}, state}

  defp dispatch({:consider, descriptor, _locations}, %{job: %{candidate: candidate}} = state) do
    result =
      if descriptor.key_hash == candidate.key_hash, do: :coalesced, else: {:error, :saturated}

    {:reply, result, state}
  end

  defp dispatch({:consider, _descriptor, _locations}, %{job: job} = state) when not is_nil(job),
    do: {:reply, {:error, :saturated}, state}

  defp dispatch({:consider, descriptor, locations}, state) do
    location = descriptor.location

    case Retention.retained(state.policy, location.kind, location.key) do
      nil -> schedule(state, descriptor, locations)
      _retained -> {:reply, :retained, state}
    end
  end

  defp schedule(state, descriptor, locations) do
    opts = state.opts
    source = descriptor.location
    plan = Partition.plan(opts[:partition], source.kind, source.key)
    location = Partition.location(plan.parent, plan.kind, plan.key, plan.generation)
    candidate = %{descriptor | location: location}

    case offer(state, candidate, :adopt) do
      {:reject, reason, _unchanged} ->
        {:reply, {:rejected, reason}, state}

      {:admit, _speculative, _victims} ->
        receipt = make_ref()
        observer = {self(), receipt}

        task =
          Task.Supervisor.async_nolink(opts[:tasks], fn ->
            Generation.adopt(opts[:pool], plan, source, opts[:limits], opts[:timeout], observer)
          end)

        {:reply, :scheduled,
         %{
           state
           | job: %{
               ref: task.ref,
               phase: :adopt,
               locations: locations,
               candidate: candidate,
               receipt: receipt,
               completion: nil,
               partition: opts[:partition]
             }
         }}
    end
  end

  @impl true
  def handle_info({ref, result}, %{job: %{ref: ref}} = state) do
    Process.demonitor(ref, [:flush])
    reply_publication(state.job, result)
    next = state |> complete(result) |> recover_completion()
    report(next, state.job.phase, job_result(result))
    {:noreply, next}
  end

  def handle_info(
        {:shared_io_complete, receipt, result},
        %{job: %{receipt: receipt, phase: phase}} = state
      )
      when phase in [:publish, :adopt] do
    state = %{state | job: %{state.job | completion: result}}
    next = recover_completion(state)
    report(next, :completion_receipt, receipt_result(result))
    {:noreply, next}
  end

  def handle_info({:shared_io_complete, _receipt, _result}, state), do: {:noreply, state}

  def handle_info({:DOWN, ref, :process, _pid, reason}, state) do
    case Map.pop(state.monitors, ref) do
      {nil, _monitors} ->
        next = state |> failed_job(ref, reason) |> recover_completion()
        if next != state, do: report(next, :worker_down, :unknown)
        {:noreply, next}

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

  defp complete(%{job: %{phase: :reconcile}} = state, {:ok, candidate}),
    do: retain(%{state | job: %{state.job | candidate: candidate}}, candidate)

  defp complete(%{job: %{phase: phase}} = state, {:error, reason})
       when phase in [:adopt, :publish] and
              reason in [:enoent, :corrupt, :body_too_large, :metadata_too_large, :saturated],
       do: %{state | job: nil}

  defp complete(%{job: %{phase: :cleanup}} = state, :ok),
    do: %{state | job: nil, debt: 0}

  defp complete(state, error), do: %{state | failure: error}

  defp recover_completion(%{failure: nil} = state), do: state

  defp recover_completion(%{job: %{phase: phase, completion: completion}} = state)
       when phase in [:publish, :adopt] do
    case completion do
      {:not_started, _error} -> %{state | job: nil, failure: nil}
      {:finished, {:ok, {:ok, _location}}} -> reconcile(state)
      {:finished, {:ok, {:error, {:commit, _reason}}}} -> reconcile(state)
      {:finished, {:ok, {:error, _precommit_failure}}} -> %{state | job: nil, failure: nil}
      _uncertain -> state
    end
  end

  defp recover_completion(state), do: state

  defp reconcile(state) do
    state = %{state | failure: nil}

    case state.job.partition == state.opts[:partition] do
      false -> cleanup(state, [state.job.candidate])
      true -> reconcile_current(state)
    end
  end

  defp reconcile_current(state) do
    opts = state.opts
    location = state.job.candidate.location

    task =
      Task.Supervisor.async_nolink(opts[:tasks], fn ->
        with {:ok, envelope} <-
               Generation.metadata(opts[:pool], location, opts[:limits], opts[:timeout]),
             do: {:ok, Generation.descriptor(location, envelope)}
      end)

    %{state | job: %{state.job | ref: task.ref, phase: :reconcile}}
  end

  defp retain(state, candidate) do
    case offer(state, candidate, :retain) do
      {:admit, policy, victims} ->
        remember(state.job, candidate, state.opts[:timeout])
        cleanup(%{state | policy: policy}, victims)

      {:reject, _reason, _unchanged} ->
        cleanup(state, [candidate])
    end
  end

  defp remember(%{locations: %Locations{} = locations}, candidate, timeout),
    do: Locations.remember_async(locations, candidate.location, timeout)

  defp remember(_job, _candidate, _timeout), do: :ok

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

  defp pending_bytes(%{phase: phase, candidate: candidate})
       when phase in [:adopt, :publish, :reconcile],
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

  defp offer(state, candidate, operation) do
    Telemetry.span(
      state.opts,
      [:cache, :shared_admission],
      %{operation: operation, pool: candidate.location.kind},
      fn ->
        case Retention.offer(state.policy, candidate) do
          {:admit, _policy, victims} = decision ->
            {decision, %{result: :admitted, victim_count: length(victims)}}

          {:reject, reason, _policy} = decision ->
            {decision, %{result: :rejected, reason: reason, victim_count: 0}}
        end
      end
    )
  end

  defp report(state, operation, job_result \\ nil) do
    metadata =
      if job_result,
        do: %{operation: operation, job_result: job_result},
        else: %{operation: operation}

    Telemetry.span(state.opts, [:cache, :shared_retention], metadata, fn ->
      stats = usage_stats(state)

      {:ok,
       %{
         result: if(state.failure == nil, do: :ok, else: :cache_error),
         logical_bytes: stats.bytes,
         pending_bytes: stats.pending_bytes,
         cleanup_bytes: stats.cleanup_bytes,
         target_bytes: stats.capacity,
         entries: stats.entries,
         jobs: stats.jobs
       }}
    end)
  end

  defp job_result(:ok), do: :ok
  defp job_result({:ok, _value}), do: :ok
  defp job_result({:error, _reason}), do: :error

  defp receipt_result({:not_started, _error}), do: :not_started
  defp receipt_result({:finished, {:ok, result}}), do: job_result(result)
  defp receipt_result({:finished, _uncertain}), do: :unknown

  @impl true
  def format_status(_status), do: %{state: :redacted}
end
