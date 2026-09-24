defmodule ImagePipe.Cache.SharedFileSystem.IO do
  @moduledoc false
  use GenServer, restart: :temporary

  @schema NimbleOptions.new!(
            max_operations: [type: :pos_integer, default: 4],
            max_bytes: [type: :pos_integer, default: 64 * 1024 * 1024],
            boot_timeout: [type: :pos_integer, default: 5_000]
          )

  def start_link(opts) do
    opts = NimbleOptions.validate!(opts, @schema)
    GenServer.start_link(__MODULE__, opts)
  end

  # bytes reserves the operation's worst-case working set, including its result.
  # Mount operations run in a separate VM; timing out never releases that budget.
  def run(pool, operation, bytes, timeout) do
    deadline = System.monotonic_time(:millisecond) + timeout
    GenServer.call(pool, {:run, operation, bytes, deadline}, timeout)
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
      {:ok,
       %{
         peer: peer,
         tasks: tasks,
         available?: true,
         jobs: %{},
         bytes: 0,
         max_bytes: opts[:max_bytes],
         max_operations: opts[:max_operations]
       }}
    else
      {:error, reason} -> {:stop, reason}
    end
  end

  @impl true
  def handle_call({:run, _operation, _bytes, _deadline}, _from, %{available?: false} = state) do
    {:reply, {:error, :unavailable}, state}
  end

  def handle_call({:run, operation, bytes, deadline}, from, state) do
    remaining = deadline - System.monotonic_time(:millisecond)

    cond do
      remaining <= 0 ->
        {:reply, {:error, :timeout}, state}

      map_size(state.jobs) >= state.max_operations or state.bytes + bytes > state.max_bytes ->
        {:reply, {:error, :saturated}, state}

      true ->
        peer = state.peer
        task = Task.Supervisor.async_nolink(state.tasks, fn -> invoke(peer, operation) end)
        timer = Process.send_after(self(), {:deadline, task.ref}, remaining)
        owner = Process.monitor(elem(from, 0))
        job = %{from: from, timer: timer, owner: owner, bytes: bytes}

        {:noreply,
         %{state | jobs: Map.put(state.jobs, task.ref, job), bytes: state.bytes + bytes}}
    end
  end

  @impl true
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
        Process.demonitor(job.owner, [:flush])
        Process.cancel_timer(job.timer)
        reply(job.from, result)
        {:noreply, %{state | jobs: jobs, bytes: state.bytes - job.bytes}}
    end
  end

  def handle_info({:deadline, ref}, state) do
    {:noreply, abandon(state, ref, {:error, :timeout})}
  end

  def handle_info({:DOWN, ref, :process, _pid, _reason}, state) do
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

        {:noreply, %{state | jobs: jobs}}
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
    jobs =
      Map.new(state.jobs, fn {ref, job} ->
        reply(job.from, {:error, :unavailable})
        {ref, %{job | from: nil}}
      end)

    %{state | available?: false, jobs: jobs}
  end

  defp reply(nil, _result), do: :ok
  defp reply(from, result), do: GenServer.reply(from, result)
end
