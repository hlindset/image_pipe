defmodule ImagePipe.Cache.SourceRecords do
  # Keeps the records of an instance's originals in memory, so an unchanged
  # local file isn't read and hashed again on every request, and a cached
  # image from an origin can be found without downloading the original. The
  # process owns the table; requests read and write it directly.
  #
  # A full table forgets the least recently used of a few sampled records.
  @moduledoc false
  use GenServer

  alias ImagePipe.Cache.RecentTable

  def child_spec(table),
    do: %{id: {__MODULE__, table}, start: {__MODULE__, :start_link, [table]}}

  def start_link(table), do: GenServer.start_link(__MODULE__, table)

  @impl true
  def init(table) do
    ^table =
      :ets.new(table, [
        :named_table,
        :public,
        :set,
        read_concurrency: true,
        write_concurrency: true
      ])

    {:ok, table}
  end

  @spec get(atom(), String.t(), integer()) :: ImagePipe.Source.Record.t() | nil
  def get(table, key, now \\ now()), do: RecentTable.get(table, key, now)

  # Keeps at most `limit` records. A nil record forgets the key.
  @spec put(atom(), String.t(), ImagePipe.Source.Record.t() | nil, pos_integer(), integer()) ::
          :ok
  def put(table, key, record, limit, now \\ now())
  def put(table, key, nil, _limit, _now), do: RecentTable.delete(table, key)
  def put(table, key, record, limit, now), do: RecentTable.put(table, key, record, limit, now)

  # Like `put/4`, but keeps a record already stored under `key`, which is
  # newer than one read back from disk.
  @spec put_new(atom(), String.t(), ImagePipe.Source.Record.t(), pos_integer()) :: :ok
  defdelegate put_new(table, key, record, limit), to: RecentTable

  defp now, do: System.monotonic_time(:second)
end
