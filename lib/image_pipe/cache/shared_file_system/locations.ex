defmodule ImagePipe.Cache.SharedFileSystem.Locations do
  @moduledoc false
  use GenServer

  alias ImagePipe.Cache.SharedFileSystem.Index
  alias ImagePipe.Cache.SharedFileSystem.IO.Admission
  alias ImagePipe.Cache.SharedFileSystem.Search

  @enforce_keys [:pid, :gate]
  defstruct @enforce_keys

  @schema NimbleOptions.new!(
            pool: [type: :any, required: true],
            root: [type: :string, required: true],
            tasks: [type: :pid, required: true],
            max_keys: [type: :pos_integer, default: 4_096],
            max_bytes: [type: :pos_integer, default: 4 * 1024 * 1024],
            max_locations: [type: :pos_integer, default: 3],
            warm_fraction: [type: :float, default: 0.25],
            max_pending: [type: :pos_integer, default: 32],
            max_request_bytes: [type: :pos_integer, default: 64 * 1024],
            max_jobs: [type: :pos_integer, default: 4],
            max_waiters: [type: :pos_integer, default: 128],
            max_partitions: [type: :pos_integer, default: 128],
            max_candidates: [type: :pos_integer, default: 16],
            search_bytes: [type: :pos_integer, default: 1024 * 1024],
            search_timeout: [type: :pos_integer, default: 1_000],
            partition_ttl: [type: :pos_integer, default: 30_000]
          )

  def start_link(opts) do
    opts = NimbleOptions.validate!(opts, @schema)
    fraction = opts[:warm_fraction]
    if fraction < 0 or fraction > 1, do: raise(ArgumentError, "warm_fraction must be in 0..1")
    GenServer.start_link(__MODULE__, opts)
  end

  def client(pid), do: GenServer.call(pid, :client)
  def hints(client, kind, key, timeout), do: call(client, {:hints, kind, key}, timeout)
  def remember(client, location, timeout), do: call(client, {:remember, location}, timeout)
  def forget(client, location, timeout), do: call(client, {:forget, location}, timeout)
  def warm(client, location, timeout), do: call(client, {:warm, location}, timeout)
  def seed(client, locations, timeout), do: call(client, {:seed, locations}, timeout)
  def stats(client, timeout), do: call(client, :stats, timeout)

  # :refresh is used when all candidates from a cached partition list were unusable.
  def discover(client, kind, key, mode, timeout),
    do: call(client, {:discover, kind, key, mode}, timeout)

  defp call(client, message, timeout) do
    deadline = now() + timeout

    with {:ok, ticket} <- Admission.claim(client.gate, message) do
      GenServer.call(client.pid, {:admitted, ticket, message, deadline}, timeout)
    end
  catch
    :exit, {:timeout, _call} -> {:error, :timeout}
    :exit, _reason -> {:error, :unavailable}
  end

  @impl true
  def init(opts) do
    gate = Admission.new(opts[:max_pending], opts[:max_request_bytes])
    Process.send_after(self(), :watch_admission, 1_000)

    {:ok,
     %{
       opts: opts,
       gate: gate,
       admission_monitors: %{},
       index: Index.new(opts),
       snapshot: nil,
       snapshot_started: 0,
       snapshot_expires: 0,
       sequence: 0,
       jobs: %{},
       waiters: %{}
     }}
  end

  @impl true
  def handle_call(:client, _from, state),
    do: {:reply, %__MODULE__{pid: self(), gate: state.gate}, state}

  def handle_call({:admitted, ticket, message, deadline}, from, state) do
    Admission.release(state.gate, ticket)
    state = %{state | admission_monitors: Admission.forget(state.admission_monitors, ticket)}

    case deadline > now() do
      true -> dispatch(message, from, deadline, state)
      false -> {:reply, {:error, :timeout}, state}
    end
  end

  defp dispatch({:hints, kind, key}, _from, _deadline, state),
    do: {:reply, {:ok, Index.lookup(state.index, kind, key)}, state}

  defp dispatch({operation, location}, _from, _deadline, state)
       when operation in [:remember, :forget, :warm],
       do: {:reply, :ok, %{state | index: apply(Index, operation, [state.index, location])}}

  defp dispatch(:stats, _from, _deadline, state),
    do:
      {:reply,
       Map.merge(Index.stats(state.index), %{
         jobs: map_size(state.jobs),
         waiters: map_size(state.waiters)
       }), state}

  defp dispatch({:seed, locations}, _from, _deadline, state) do
    {index, count, status} = Index.seed(state.index, locations)
    {:reply, {:ok, count, status}, %{state | index: index}}
  end

  defp dispatch({:discover, kind, key, mode}, from, deadline, state) do
    identity = {kind, key, mode}

    cond do
      map_size(state.waiters) >= state.opts[:max_waiters] ->
        {:reply, {:error, :saturated}, state}

      Map.has_key?(state.jobs, identity) ->
        {:noreply, add_waiter(state, identity, from, deadline)}

      map_size(state.jobs) >= state.opts[:max_jobs] ->
        {:reply, {:error, :saturated}, state}

      true ->
        state = start_search(state, identity)
        {:noreply, add_waiter(state, identity, from, deadline)}
    end
  end

  defp start_search(state, {kind, key, mode} = identity) do
    opts = state.opts
    snapshot = if mode == :cached and state.snapshot_expires > now(), do: state.snapshot

    limits = %{
      partitions: opts[:max_partitions],
      candidates: opts[:max_candidates],
      bytes: opts[:search_bytes]
    }

    task =
      Task.Supervisor.async_nolink(opts[:tasks], fn ->
        Search.run(opts[:pool], opts[:root], snapshot, kind, key, limits, opts[:search_timeout])
      end)

    sequence = state.sequence + 1
    job = %{ref: task.ref, sequence: sequence}
    %{state | jobs: Map.put(state.jobs, identity, job), sequence: sequence}
  end

  defp add_waiter(state, identity, {pid, _tag} = from, deadline) do
    ref = Process.monitor(pid)
    timer = Process.send_after(self(), {:expire, ref}, max(deadline - now(), 0))
    waiter = %{identity: identity, from: from, timer: timer, deadline: deadline}
    %{state | waiters: Map.put(state.waiters, ref, waiter)}
  end

  @impl true
  def handle_info({ref, {result, snapshot}}, state) when is_reference(ref) do
    Process.demonitor(ref, [:flush])
    {:noreply, complete(state, ref, result, snapshot)}
  end

  def handle_info({:expire, ref}, state) do
    case Map.get(state.waiters, ref) do
      nil -> :ok
      waiter -> GenServer.reply(waiter.from, {:error, :timeout})
    end

    {:noreply, remove_waiter(state, ref)}
  end

  def handle_info({:DOWN, ref, :process, _pid, _reason}, state) do
    case Map.pop(state.admission_monitors, ref) do
      {nil, _monitors} ->
        state = state |> remove_waiter(ref) |> complete(ref, {:error, :unavailable}, nil)
        {:noreply, state}

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

  defp complete(state, ref, result, snapshot) do
    case Enum.find(state.jobs, fn {_key, job} -> job.ref == ref end) do
      nil -> state
      {identity, job} -> finish(state, identity, job, result, snapshot)
    end
  end

  defp finish(state, identity, job, result, snapshot) do
    state = %{state | jobs: Map.delete(state.jobs, identity)}
    state = save_snapshot(state, job, snapshot)

    Enum.reduce(state.waiters, state, fn
      {ref, %{identity: ^identity} = waiter}, state ->
        reply = if waiter.deadline > now(), do: result, else: {:error, :timeout}
        GenServer.reply(waiter.from, reply)
        remove_waiter(state, ref)

      _other, state ->
        state
    end)
  end

  defp save_snapshot(state, _job, nil), do: state

  defp save_snapshot(state, job, snapshot) do
    case job.sequence >= state.snapshot_started do
      true ->
        %{
          state
          | snapshot: snapshot,
            snapshot_started: job.sequence,
            snapshot_expires: now() + state.opts[:partition_ttl]
        }

      false ->
        state
    end
  end

  defp remove_waiter(state, ref) do
    case Map.pop(state.waiters, ref) do
      {nil, _waiters} ->
        state

      {waiter, waiters} ->
        Process.demonitor(ref, [:flush])
        Process.cancel_timer(waiter.timer)
        %{state | waiters: waiters}
    end
  end

  defp now, do: System.monotonic_time(:millisecond)

  @impl true
  def format_status(_status), do: %{state: :redacted}
end
