defmodule ImagePipe.Cache.SharedFileSystem.Sources do
  @moduledoc false
  use GenServer

  alias ImagePipe.Cache.SharedFileSystem.IO.Admission
  alias ImagePipe.Cache.SharedFileSystem.Selection

  @enforce_keys [:table]
  defstruct @enforce_keys

  def start_link(table, opts), do: GenServer.start_link(__MODULE__, {table, opts})

  # Resolve once at startup. The supervisor-owned route survives worker restarts.
  def client(supervisor) do
    [{__MODULE__, worker, _, _}] = Supervisor.which_children(supervisor)
    GenServer.call(worker, :client, 5_000)
  end

  def lookup(client, key, timeout), do: call(client, {:lookup, key}, timeout)

  def acquire(client, key, timeout) do
    case request(client, {:acquire, key}, timeout) do
      {pid, {:ok, lease, outcome}} ->
        GenServer.cast(pid, {:accept, lease, self()})
        {:ok, lease, outcome}

      {_pid, result} ->
        result
    end
  end

  def release(client, lease) do
    case route(client) do
      {:ok, pid, _gate} -> GenServer.cast(pid, {:release, lease, self()})
      _unavailable -> :ok
    end
  end

  def publish(client, key, lease, record, timeout),
    do: call(client, {:publish, key, lease, record}, timeout)

  def discover(client, key, lease, candidate, timeout),
    do: call(client, {:discover, key, lease, candidate}, timeout)

  def invalidate(client, key, revision, timeout),
    do: call(client, {:invalidate, key, revision}, timeout)

  def stats(client, timeout), do: call(client, :stats, timeout)

  defp call(client, message, timeout), do: client |> request(message, timeout) |> elem(1)

  defp request(client, message, timeout) do
    deadline = System.monotonic_time(:millisecond) + timeout

    with {:ok, pid, gate} <- route(client),
         {:ok, ticket} <- Admission.claim(gate, message) do
      {pid, GenServer.call(pid, {:admitted, ticket, message, deadline}, timeout)}
    else
      error -> {nil, error}
    end
  catch
    :exit, {:timeout, _call} -> {nil, {:error, :timeout}}
    :exit, _reason -> {nil, {:error, :unavailable}}
  end

  defp route(client) do
    [{:route, pid, gate}] = :ets.lookup(client.table, :route)
    {:ok, pid, gate}
  rescue
    ArgumentError -> {:error, :unavailable}
  end

  @impl true
  def init({table, opts}) do
    now = opts[:clock].()

    selection =
      case :ets.lookup(table, :high_water) do
        [] -> Selection.new(opts, now)
        [{:high_water, previous}] -> Selection.recover(opts, max(previous, now))
      end

    gate = Admission.new(opts[:max_pending], opts[:max_request_bytes])
    :ets.insert(table, [{:route, self(), gate}, {:high_water, selection.high_water}])
    Process.send_after(self(), :watch_admission, 1_000)

    {:ok,
     %{
       table: table,
       gate: gate,
       admission_monitors: %{},
       selection: selection,
       clock: opts[:clock],
       max_locks: opts[:max_locks],
       max_waiters: opts[:max_waiters],
       locks: %{},
       leases: %{},
       waiters: 0
     }}
  end

  @impl true
  def handle_call(:client, _from, state), do: {:reply, %__MODULE__{table: state.table}, state}

  def handle_call({:admitted, ticket, message, deadline}, from, state) do
    Admission.release(state.gate, ticket)
    state = %{state | admission_monitors: Admission.forget(state.admission_monitors, ticket)}

    {now, state} = observe_clock(state)

    case deadline > System.monotonic_time(:millisecond) do
      true -> dispatch(message, from, deadline, {now, state})
      false -> {:reply, {:error, :timeout}, state}
    end
  end

  defp observe_clock(state) do
    now = state.clock.()
    high_water = max(now, state.selection.high_water)
    :ets.insert(state.table, {:high_water, high_water})
    {now, %{state | selection: %{state.selection | high_water: high_water}}}
  end

  defp dispatch({:lookup, key}, _from, _remaining, {now, state}) do
    {reply, selection} = Selection.lookup(state.selection, key, now)
    {:reply, reply, %{state | selection: selection}}
  end

  defp dispatch({:acquire, key}, from, deadline, {_now, state}) do
    case Map.fetch(state.locks, key) do
      :error when map_size(state.locks) >= state.max_locks ->
        {:reply, {:error, :saturated}, state}

      :error ->
        {lease, state} = monitor(state, key, from, deadline, :offered)
        locks = Map.put(state.locks, key, %{owner: lease, waiters: []})
        {:reply, {:ok, lease, :acquired}, %{state | locks: locks}}

      {:ok, _lock} when state.waiters >= state.max_waiters ->
        {:reply, {:error, :saturated}, state}

      {:ok, lock} ->
        {lease, state} = monitor(state, key, from, deadline, :waiting)
        locks = Map.put(state.locks, key, %{lock | waiters: lock.waiters ++ [lease]})
        {:noreply, %{state | locks: locks, waiters: state.waiters + 1}}
    end
  end

  defp dispatch({operation, key, lease, value}, {pid, _tag}, _remaining, {now, state})
       when operation in [:publish, :discover] do
    case Map.get(state.leases, lease) do
      %{key: ^key, pid: ^pid, status: :active} ->
        {reply, selection} = apply(Selection, operation, [state.selection, key, value, now])
        {:reply, reply, %{state | selection: selection}}

      _lost ->
        {:reply, {:error, :ownership_lost}, state}
    end
  end

  defp dispatch({:invalidate, key, revision}, _from, _remaining, {now, state}),
    do:
      {:reply, :ok,
       %{state | selection: Selection.invalidate(state.selection, key, revision, now)}}

  defp dispatch(:stats, _from, _remaining, {_now, state}),
    do:
      {:reply,
       Map.merge(Selection.stats(state.selection), %{
         locks: map_size(state.locks),
         waiters: state.waiters
       }), state}

  defp monitor(state, key, {pid, _tag} = from, deadline, status) do
    lease = Process.monitor(pid)
    remaining = max(deadline - System.monotonic_time(:millisecond), 0)
    timer = Process.send_after(self(), {:expire, lease}, remaining)
    entry = %{key: key, pid: pid, from: from, timer: timer, status: status, deadline: deadline}
    {lease, %{state | leases: Map.put(state.leases, lease, entry)}}
  end

  @impl true
  def handle_cast({:accept, lease, pid}, state) do
    case Map.get(state.leases, lease) do
      %{pid: ^pid, status: :offered} = entry ->
        case entry.deadline > System.monotonic_time(:millisecond) do
          true ->
            Process.cancel_timer(entry.timer)
            leases = Map.put(state.leases, lease, %{entry | status: :active})
            {:noreply, %{state | leases: leases}}

          false ->
            {:noreply, forget(state, lease)}
        end

      _lost ->
        {:noreply, state}
    end
  end

  def handle_cast({:release, lease, pid}, state) do
    case Map.get(state.leases, lease) do
      %{pid: ^pid} -> {:noreply, forget(state, lease)}
      _lost -> {:noreply, state}
    end
  end

  @impl true
  def handle_info({:expire, lease}, state) do
    case Map.get(state.leases, lease) do
      %{status: status, from: from} when status in [:offered, :waiting] ->
        GenServer.reply(from, {:error, :timeout})
        {:noreply, forget(state, lease)}

      _active_or_lost ->
        {:noreply, state}
    end
  end

  def handle_info({:DOWN, ref, :process, _pid, _reason}, state) do
    case Map.pop(state.admission_monitors, ref) do
      {nil, _monitors} ->
        {:noreply, forget(state, ref)}

      {ticket, monitors} ->
        Admission.release(state.gate, ticket)
        {:noreply, %{state | admission_monitors: monitors}}
    end
  end

  def handle_info(:watch_admission, state) do
    monitors = Admission.watch(state.gate, state.admission_monitors)
    Process.send_after(self(), :watch_admission, 1_000)
    {:noreply, %{state | admission_monitors: monitors}}
  end

  defp forget(state, lease) do
    case Map.pop(state.leases, lease) do
      {nil, _leases} ->
        state

      {entry, leases} ->
        Process.demonitor(lease, [:flush])
        Process.cancel_timer(entry.timer)
        state = %{state | leases: leases}
        lock = Map.fetch!(state.locks, entry.key)
        release_lock(state, entry, lease, lock)
    end
  end

  defp release_lock(state, entry, lease, %{owner: lease, waiters: []}),
    do: %{state | locks: Map.delete(state.locks, entry.key)}

  defp release_lock(state, entry, lease, %{owner: lease, waiters: [next | rest]}) do
    successor = Map.fetch!(state.leases, next)
    leases = Map.put(state.leases, next, %{successor | status: :offered})
    locks = Map.put(state.locks, entry.key, %{owner: next, waiters: rest})
    state = %{state | leases: leases, locks: locks, waiters: state.waiters - 1}

    case successor.deadline > System.monotonic_time(:millisecond) do
      true ->
        GenServer.reply(successor.from, {:ok, next, :coalesced})
        state

      false ->
        GenServer.reply(successor.from, {:error, :timeout})
        forget(state, next)
    end
  end

  defp release_lock(state, entry, lease, lock) do
    locks = Map.put(state.locks, entry.key, %{lock | waiters: List.delete(lock.waiters, lease)})
    %{state | locks: locks, waiters: state.waiters - 1}
  end

  @impl true
  def format_status(_status), do: %{state: :redacted}
end
