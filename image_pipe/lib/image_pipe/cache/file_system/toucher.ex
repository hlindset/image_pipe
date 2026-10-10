defmodule ImagePipe.Cache.FileSystem.Toucher do
  # Keeps an entry's metadata mtime at the time it was last read, so idle
  # expiry measures time since the last read without file I/O on the read
  # path. A read inserts the key hash into this cache's ETS set. Every interval
  # the toucher takes the recorded hashes and sets the mtime of each entry's
  # `.meta`, skipping entries removed meanwhile. A clean shutdown touches what
  # is pending, so a crash loses at most one interval of reads.
  #
  # The interval is an hour, or a quarter of `max_age` when that is shorter,
  # so a read is saved well before the entry could expire.
  #
  # The table is named after the cache's root and path prefix. Another cache
  # with the same root and prefix in this VM waits on the table's owner and
  # takes the table over when that owner stops.
  @moduledoc false

  use GenServer

  require Record

  alias ImagePipe.Cache.FileSystem.Store

  Record.defrecordp(:file_info, Record.extract(:file_info, from_lib: "kernel/include/file.hrl"))

  @max_interval_ms 60 * 60 * 1000

  def child_spec(opts) do
    %{
      id: {__MODULE__, Keyword.fetch!(opts, :root), Keyword.get(opts, :path_prefix, "")},
      start: {__MODULE__, :start_link, [opts]}
    }
  end

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

  @doc "Records a read of the entry `key_hash` in the cache `opts` configures."
  def record(opts, key_hash) do
    :ets.insert(table(opts), {key_hash})
    :ok
  rescue
    # No instance runs this cache's toucher, or it is restarting.
    ArgumentError -> :ok
  end

  @impl true
  def init(opts) do
    Process.flag(:trap_exit, true)

    state = %{
      table: table(opts),
      opts: Keyword.take(opts, [:root, :path_prefix]),
      interval_ms: interval_ms(Keyword.get(opts, :max_age)),
      owner?: false
    }

    {:ok, claim(state)}
  end

  @impl true
  def handle_info(:touch, state) do
    touch(state)
    schedule(state)
    {:noreply, state}
  end

  # The toucher that owned the table stopped, so this one takes it over.
  def handle_info({:DOWN, _ref, :process, _pid, _reason}, state), do: {:noreply, claim(state)}

  @impl true
  def terminate(_reason, %{owner?: true} = state), do: touch(state)
  def terminate(_reason, _state), do: :ok

  # Two waiting touchers can see the owner stop together. The one whose
  # `:ets.new/2` loses waits on the winner.
  defp claim(state) do
    :ets.new(state.table, [:named_table, :public, :set, write_concurrency: true])
    schedule(state)
    %{state | owner?: true}
  rescue
    ArgumentError -> wait_on_owner(state)
  end

  # The owner can stop between the failed create and this lookup.
  defp wait_on_owner(state) do
    case :ets.info(state.table, :owner) do
      :undefined ->
        claim(state)

      owner ->
        Process.monitor(owner)
        state
    end
  end

  defp interval_ms(nil), do: @max_interval_ms
  defp interval_ms(max_age), do: min(@max_interval_ms, max(1_000, div(max_age * 1000, 4)))

  defp schedule(state), do: Process.send_after(self(), :touch, state.interval_ms)

  # A read recorded after its entry's touch in this pass waits for the next.
  defp touch(state) do
    now = System.os_time(:second)
    info = file_info(mtime: now, atime: now)

    for {key_hash} <- :ets.tab2list(state.table) do
      :ets.delete(state.table, key_hash)

      # An entry removed meanwhile fails with :enoent and stays removed.
      with {:ok, paths} <- Store.paths_from_hash(key_hash, state.opts),
           do: :file.write_file_info(paths.meta_path, info, [{:time, :posix}, :raw])
    end

    :ok
  end

  # Roots and prefixes are static host configuration, so the derived atoms
  # are bounded.
  defp table(opts) do
    key = {Keyword.fetch!(opts, :root), Keyword.get(opts, :path_prefix, "")}

    suffix =
      :crypto.hash(:sha256, :erlang.term_to_binary(key))
      |> Base.encode16(case: :lower)
      |> binary_part(0, 16)

    Module.concat(__MODULE__, suffix)
  end
end
