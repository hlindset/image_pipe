defmodule ImagePipe.Source.HTTP.DnsCache do
  @moduledoc false

  # The target check resolves the origin before every request, even when a
  # pooled connection is open, so answers are kept for a fixed lifetime. The OS
  # resolver doesn't report TTLs, and switching to OTP's own DNS client would
  # change how every deployment resolves names. The check still runs the
  # address policy on cached answers, and fetches connect only to checked
  # addresses, so a cached answer can be stale but never unchecked.
  #
  # Only answers with addresses are kept, so a host that doesn't resolve is
  # looked up again on the next request. Concurrent misses for a host share
  # one lookup, which runs outside the server so other hosts don't wait on it.
  # A lookup that has run longer than a healthy one would, such as one stuck
  # in the resolver's retries during an outage, isn't joined: the next miss
  # starts its own, so requests recover as soon as DNS does. A full table
  # caches no new hosts until a sweep removes expired answers.

  use GenServer

  @lifetime 10_000
  @join_within 1_000
  @max_entries 10_000

  @type lookup :: (String.t() -> {:ok, [:inet.ip_address()]} | {:error, term()})

  def start_link(opts) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, Keyword.put(opts, :name, name), name: name)
  end

  @doc """
  Resolves `host` from the cache, or with `lookup` on a miss. While the cache
  isn't running, such as during a restart, it calls `lookup` directly.
  """
  @spec resolve(GenServer.server(), String.t(), lookup()) ::
          {:ok, [:inet.ip_address()]} | {:error, term()}
  def resolve(cache \\ __MODULE__, host, lookup) do
    case fresh(cache, host) do
      {:ok, addresses} -> {:ok, addresses}
      :miss -> GenServer.call(cache, {:resolve, host, lookup}, :infinity)
    end
  catch
    :exit, {_reason, {GenServer, :call, _args}} -> lookup.(host)
  end

  @doc "Removes `host`'s cached answer."
  @spec invalidate(GenServer.server(), String.t()) :: :ok
  def invalidate(cache \\ __MODULE__, host) do
    :ets.delete(cache, host)
    :ok
  rescue
    ArgumentError -> :ok
  end

  defp fresh(cache, host) do
    now = now()

    case :ets.lookup(cache, host) do
      [{^host, addresses, expires_at}] when now < expires_at -> {:ok, addresses}
      _miss -> :miss
    end
  rescue
    ArgumentError -> :miss
  end

  @impl true
  def init(opts) do
    table = Keyword.fetch!(opts, :name)
    :ets.new(table, [:named_table, :public, read_concurrency: true])
    lifetime = Keyword.get(opts, :lifetime, @lifetime)
    schedule(lifetime)

    {:ok,
     %{
       table: table,
       lifetime: lifetime,
       join_within: Keyword.get(opts, :join_within, @join_within),
       max_entries: Keyword.get(opts, :max_entries, @max_entries),
       pending: %{}
     }}
  end

  @impl true
  def handle_call({:resolve, host, lookup}, from, state) do
    # Another caller's lookup may have stored an answer since this caller
    # missed.
    case fresh(state.table, host) do
      {:ok, addresses} -> {:reply, {:ok, addresses}, state}
      :miss -> {:noreply, join_or_start(state, host, lookup, from)}
    end
  end

  @impl true
  def handle_info({:resolved, pid, result}, state) do
    {{host, waiters, _started, ref}, pending} = Map.pop!(state.pending, pid)
    Process.demonitor(ref, [:flush])
    store(state, host, result)
    Enum.each(waiters, &GenServer.reply(&1, result))
    {:noreply, %{state | pending: pending}}
  end

  def handle_info({:DOWN, _ref, :process, pid, reason}, state) do
    {{_host, waiters, _started, _ref}, pending} = Map.pop!(state.pending, pid)
    Enum.each(waiters, &GenServer.reply(&1, {:error, reason}))
    {:noreply, %{state | pending: pending}}
  end

  def handle_info(:sweep, state) do
    now = now()
    :ets.select_delete(state.table, [{{:_, :_, :"$1"}, [{:"=<", :"$1", now}], [true]}])
    schedule(state.lifetime)
    {:noreply, state}
  end

  defp join_or_start(state, host, lookup, from) do
    now = now()

    joinable =
      Enum.find(state.pending, fn {_pid, {pending_host, _waiters, started, _ref}} ->
        pending_host == host and now - started < state.join_within
      end)

    case joinable do
      {pid, {^host, waiters, started, ref}} ->
        put_in(state.pending[pid], {host, [from | waiters], started, ref})

      nil ->
        server = self()
        {pid, ref} = spawn_monitor(fn -> send(server, {:resolved, self(), lookup.(host)}) end)
        put_in(state.pending[pid], {host, [from], now, ref})
    end
  end

  defp store(state, host, {:ok, [_ | _] = addresses}) do
    if :ets.member(state.table, host) or :ets.info(state.table, :size) < state.max_entries do
      :ets.insert(state.table, {host, addresses, now() + state.lifetime})
    end
  end

  defp store(_state, _host, _result), do: :ok

  defp schedule(lifetime), do: Process.send_after(self(), :sweep, max(lifetime, 1_000))

  defp now, do: System.monotonic_time(:millisecond)
end
