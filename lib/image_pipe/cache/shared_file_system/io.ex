defmodule ImagePipe.Cache.SharedFileSystem.IO do
  @moduledoc false
  use GenServer, restart: :temporary

  alias ImagePipe.Cache.SharedFileSystem.IO.{Admission, Leases}

  @enforce_keys [:pid, :admission]
  defstruct @enforce_keys

  @schema NimbleOptions.new!(
            max_operations: [type: :pos_integer, default: 4],
            max_bytes: [type: :pos_integer, default: 64 * 1024 * 1024],
            max_pending: [type: :pos_integer, default: 16],
            max_request_bytes: [type: :pos_integer, default: 1024 * 1024],
            max_resources: [type: :pos_integer, default: 32],
            max_resource_bytes: [type: :pos_integer, default: 256 * 1024 * 1024],
            boot_timeout: [type: :pos_integer, default: 5_000]
          )

  def start_link(opts) do
    opts = NimbleOptions.validate!(opts, @schema)
    GenServer.start_link(__MODULE__, opts)
  end

  # Obtain once during adapter startup, then share this local handle with callers.
  def client(pid), do: GenServer.call(pid, :client)

  # bytes reserves the operation's worst-case working set, including its result.
  # Mount operations run in a separate VM; timing out never releases that budget.
  def run(pool, operation, bytes, timeout, lease \\ nil, observer \\ nil) do
    deadline = System.monotonic_time(:millisecond) + timeout

    request =
      case observer do
        nil -> {:run, operation, bytes, deadline, lease}
        observer -> {:observed_run, operation, bytes, deadline, lease, observer}
      end

    call(pool, request, timeout)
  end

  def reserve(pool, bytes, cleanup, timeout) do
    deadline = System.monotonic_time(:millisecond) + timeout

    case call(pool, {:reserve, bytes, cleanup, deadline}, timeout) do
      {:ok, token} = result ->
        GenServer.cast(pool.pid, {:accept, token})
        result

      error ->
        error
    end
  end

  def release(pool, lease, timeout), do: call(pool, {:release, lease}, timeout)

  def close(pool, lease), do: GenServer.cast(pool.pid, {:close, lease})

  def retry_cleanup(pool), do: GenServer.cast(pool.pid, :retry_cleanup)

  defp call(pool, message, timeout) do
    with {:ok, ticket} <- Admission.claim(pool.admission, message) do
      # Only the receiver releases admission. A timeout may leave the payload
      # in its mailbox, so the caller must not make that slot reusable.
      GenServer.call(pool.pid, {:admitted, ticket, message}, timeout)
    end
  catch
    :exit, {:timeout, _call} -> {:error, :timeout}
    :exit, _reason -> {:error, :unavailable}
  end

  @impl true
  def init(opts) do
    Process.flag(:trap_exit, true)
    paths = Enum.flat_map(:code.get_path(), &[~c"-pa", &1])

    peer_opts = %{
      connection: :standard_io,
      peer_down: :crash,
      shutdown: :halt,
      wait_boot: opts[:boot_timeout],
      args: [~c"+S", ~c"1:1", ~c"+SDio", ~c"1", ~c"+SDcpu", ~c"1"] ++ paths
    }

    with {:ok, peer, _node} <- :peer.start_link(peer_opts),
         {:ok, _apps} <- :peer.call(peer, :application, :ensure_all_started, [:elixir]),
         {:ok, tasks} <- Task.Supervisor.start_link() do
      Process.send_after(self(), :watch_admission, 1_000)

      {:ok,
       %{
         admission: Admission.new(opts[:max_pending], opts[:max_request_bytes]),
         admission_monitors: %{},
         peer: peer,
         tasks: tasks,
         available?: true,
         jobs: %{},
         leases: Leases.new(opts[:max_resources], opts[:max_resource_bytes]),
         bytes: 0,
         max_bytes: opts[:max_bytes],
         max_operations: opts[:max_operations]
       }}
    else
      {:error, reason} -> {:stop, reason}
    end
  end

  @impl true
  def handle_call(:client, _from, state) do
    {:reply, %__MODULE__{pid: self(), admission: state.admission}, state}
  end

  def handle_call({:admitted, ticket, request}, from, state) do
    Admission.release(state.admission, ticket)
    monitors = Admission.forget(state.admission_monitors, ticket)
    handle_request(request, from, %{state | admission_monitors: monitors})
  end

  defp handle_request(_request, _from, %{available?: false} = state) do
    {:reply, {:error, :unavailable}, state}
  end

  defp handle_request({:reserve, bytes, cleanup, deadline}, from, state) do
    case deadline - System.monotonic_time(:millisecond) do
      remaining when remaining > 0 ->
        {reply, leases} = Leases.reserve(state.leases, elem(from, 0), bytes, cleanup, remaining)
        {:reply, reply, %{state | leases: leases}}

      _expired ->
        {:reply, {:error, :timeout}, state}
    end
  end

  defp handle_request({:release, lease}, from, state) do
    case Leases.close(state.leases, lease, from) do
      {:ok, leases} -> {:noreply, cleanup(%{state | leases: leases})}
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  defp handle_request({:run, operation, bytes, deadline, lease}, from, state) do
    start_operation(operation, bytes, deadline, lease, nil, from, state)
  end

  defp handle_request({:observed_run, operation, bytes, deadline, lease, observer}, from, state) do
    case start_operation(operation, bytes, deadline, lease, observer, from, state) do
      {:reply, error, state} ->
        notify(observer, {:not_started, error})
        {:reply, error, state}

      accepted ->
        accepted
    end
  end

  defp start_operation(operation, bytes, deadline, lease, observer, from, state) do
    remaining = deadline - System.monotonic_time(:millisecond)

    cond do
      remaining <= 0 ->
        {:reply, {:error, :timeout}, state}

      not Leases.open?(state.leases, lease) ->
        {:reply, {:error, :released}, state}

      map_size(state.jobs) >= state.max_operations or state.bytes + bytes > state.max_bytes ->
        {:reply, {:error, :saturated}, state}

      true ->
        peer = state.peer
        task = Task.Supervisor.async_nolink(state.tasks, fn -> invoke(peer, operation) end)
        timer = Process.send_after(self(), {:deadline, task.ref}, remaining)
        owner = Process.monitor(elem(from, 0))

        job = %{
          from: from,
          timer: timer,
          owner: owner,
          bytes: bytes,
          lease: lease,
          observer: observer,
          cleanup: false
        }

        {:noreply,
         %{state | jobs: Map.put(state.jobs, task.ref, job), bytes: state.bytes + bytes}}
    end
  end

  @impl true
  def handle_cast({:accept, token}, state) do
    {:noreply, %{state | leases: Leases.accept(state.leases, token)}}
  end

  def handle_cast(:retry_cleanup, state) do
    {:noreply, cleanup(%{state | leases: Leases.retry(state.leases)})}
  end

  def handle_cast({:close, lease}, state) do
    case Leases.close(state.leases, lease, nil) do
      {:ok, leases} -> {:noreply, cleanup(%{state | leases: leases})}
      {:error, _reason} -> {:noreply, state}
    end
  end

  @impl true
  def handle_info(:watch_admission, state) do
    # Catch callers killed between claiming a slot and sending their request.
    # Their DOWN is handled after earlier local messages from that caller.
    monitors = Admission.watch(state.admission, state.admission_monitors)
    Process.send_after(self(), :watch_admission, 1_000)
    {:noreply, %{state | admission_monitors: monitors}}
  end

  def handle_info({ref, {:error, :unavailable}}, state) when is_reference(ref) do
    case Map.has_key?(state.jobs, ref) do
      true ->
        # Losing the call channel does not acknowledge filesystem completion.
        # Retain both the operation and any transient resource reservation.
        Process.demonitor(ref, [:flush])
        {:noreply, unavailable(state)}

      false ->
        {:noreply, state}
    end
  end

  def handle_info({ref, result}, state) when is_reference(ref) do
    case Map.pop(state.jobs, ref) do
      {nil, _jobs} ->
        {:noreply, state}

      {job, jobs} ->
        Process.demonitor(ref, [:flush])
        finish_job(job, result)
        leases = complete_cleanup(state.leases, job, result)
        {:noreply, cleanup(%{state | jobs: jobs, bytes: state.bytes - job.bytes, leases: leases})}
    end
  end

  def handle_info({:deadline, ref}, state) do
    {:noreply, abandon(state, ref, {:error, :timeout})}
  end

  def handle_info({:offer_expired, token}, state) do
    {:noreply, cleanup(%{state | leases: Leases.expire(state.leases, token)})}
  end

  def handle_info({:DOWN, ref, :process, _pid, _reason}, state) do
    case Map.pop(state.admission_monitors, ref) do
      {nil, _monitors} ->
        owner_down(state, ref)

      {ticket, monitors} ->
        Admission.release(state.admission, ticket)
        {:noreply, %{state | admission_monitors: monitors}}
    end
  end

  def handle_info({:EXIT, pid, _reason}, state) when pid == state.peer or pid == state.tasks do
    {:noreply, unavailable(state)}
  end

  @impl true
  def terminate(_reason, state) do
    # No replacement helper is spawned after failure. Outstanding OS I/O may
    # outlive termination; automatic restart would lose its resource accounting.
    :peer.stop(state.peer)
  catch
    :exit, _reason -> :ok
  end

  defp invoke(peer, {module, function, args}) do
    {:ok, :peer.call(peer, module, function, args, :infinity)}
  catch
    :exit, _reason -> {:error, :unavailable}
    kind, reason -> {:error, {:operation, kind, reason}}
  end

  defp owner_down(state, ref) do
    case Map.has_key?(state.jobs, ref) do
      true ->
        # A lost call proxy is not evidence that its remote operation finished.
        {:noreply, unavailable(state)}

      false ->
        jobs =
          Map.new(state.jobs, fn
            {key, %{owner: ^ref} = job} -> {key, %{job | from: nil}}
            entry -> entry
          end)

        leases = Leases.owner_down(state.leases, ref)
        {:noreply, cleanup(%{state | jobs: jobs, leases: leases})}
    end
  end

  defp abandon(state, ref, result) do
    case Map.fetch(state.jobs, ref) do
      :error ->
        state

      {:ok, job} ->
        reply(job.from, result)
        %{state | jobs: Map.put(state.jobs, ref, %{job | from: nil})}
    end
  end

  defp unavailable(state) do
    Admission.disable(state.admission)

    jobs =
      Map.new(state.jobs, fn {ref, job} ->
        reply(job.from, {:error, :unavailable})
        {ref, %{job | from: nil}}
      end)

    %{state | available?: false, jobs: jobs, leases: Leases.unavailable(state.leases)}
  end

  defp cleanup(%{available?: false} = state), do: state

  defp cleanup(state) do
    active = MapSet.new(state.jobs, fn {_ref, job} -> job.lease end)
    capacity = state.max_operations - map_size(state.jobs)
    {operations, leases} = Leases.ready(state.leases, active, capacity)

    Enum.reduce(operations, %{state | leases: leases}, fn {lease, operation}, state ->
      peer = state.peer
      task = Task.Supervisor.async_nolink(state.tasks, fn -> invoke(peer, operation) end)
      job = %{from: nil, bytes: 0, lease: lease, cleanup: true}
      %{state | jobs: Map.put(state.jobs, task.ref, job)}
    end)
  end

  defp complete_cleanup(leases, %{cleanup: false}, _result), do: leases

  defp complete_cleanup(leases, %{lease: lease}, result),
    do: Leases.complete(leases, lease, result)

  defp finish_job(%{cleanup: true}, _result), do: :ok

  defp finish_job(job, result) do
    Process.demonitor(job.owner, [:flush])
    Process.cancel_timer(job.timer)
    notify(job.observer, {:finished, result})
    reply(job.from, result)
  end

  defp notify(nil, _result), do: :ok
  defp notify({pid, receipt}, result), do: send(pid, {:shared_io_complete, receipt, result})

  defp reply(nil, _result), do: :ok
  defp reply(from, result), do: GenServer.reply(from, result)
end
