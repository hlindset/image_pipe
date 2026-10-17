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
  # A full table caches nothing new until a sweep removes expired answers.

  use GenServer

  @lifetime 10_000
  @max_entries 10_000

  @type lookup :: (String.t() -> {:ok, [:inet.ip_address()]} | {:error, term()})

  def start_link(opts) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, Keyword.put(opts, :name, name), name: name)
  end

  @doc "Resolves `host` from the cache, or with `lookup` on a miss."
  @spec resolve(GenServer.server(), String.t(), lookup()) ::
          {:ok, [:inet.ip_address()]} | {:error, term()}
  def resolve(cache \\ __MODULE__, host, lookup) do
    now = now()

    case :ets.lookup(cache, host) do
      [{^host, addresses, expires_at}] when now < expires_at -> {:ok, addresses}
      _miss -> GenServer.call(cache, {:resolve, host, lookup}, :infinity)
    end
  end

  @doc "Removes `host`'s cached answer."
  @spec invalidate(GenServer.server(), String.t()) :: :ok
  def invalidate(cache \\ __MODULE__, host) do
    :ets.delete(cache, host)
    :ok
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
       max_entries: Keyword.get(opts, :max_entries, @max_entries),
       pending: %{}
     }}
  end

  @impl true
  def handle_call({:resolve, host, lookup}, from, state) do
    case state.pending do
      %{^host => {ref, waiters}} ->
        {:noreply, put_in(state.pending[host], {ref, [from | waiters]})}

      _none ->
        server = self()

        {_pid, ref} =
          spawn_monitor(fn -> send(server, {:resolved, host, run(lookup, host)}) end)

        {:noreply, put_in(state.pending[host], {ref, [from]})}
    end
  end

  @impl true
  def handle_info({:resolved, host, result}, state) do
    {{ref, waiters}, pending} = Map.pop!(state.pending, host)
    Process.demonitor(ref, [:flush])
    store(state, host, result)
    Enum.each(waiters, &GenServer.reply(&1, result))
    {:noreply, %{state | pending: pending}}
  end

  def handle_info({:DOWN, ref, :process, _pid, reason}, state) do
    case Enum.find(state.pending, fn {_host, {pending_ref, _}} -> pending_ref == ref end) do
      {host, {^ref, waiters}} ->
        Enum.each(waiters, &GenServer.reply(&1, {:error, reason}))
        {:noreply, %{state | pending: Map.delete(state.pending, host)}}

      nil ->
        {:noreply, state}
    end
  end

  def handle_info(:sweep, state) do
    now = now()
    :ets.select_delete(state.table, [{{:_, :_, :"$1"}, [{:"=<", :"$1", now}], [true]}])
    schedule(state.lifetime)
    {:noreply, state}
  end

  defp run(lookup, host) do
    lookup.(host)
  catch
    kind, reason -> {:error, {kind, reason}}
  end

  defp store(state, host, {:ok, [_ | _] = addresses}) do
    if :ets.info(state.table, :size) < state.max_entries do
      :ets.insert(state.table, {host, addresses, now() + state.lifetime})
    end
  end

  defp store(_state, _host, _result), do: :ok

  defp schedule(lifetime), do: Process.send_after(self(), :sweep, max(lifetime, 1_000))

  defp now, do: System.monotonic_time(:millisecond)
end
