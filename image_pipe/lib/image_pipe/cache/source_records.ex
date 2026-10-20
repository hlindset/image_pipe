defmodule ImagePipe.Cache.SourceRecords do
  # Keeps the records of an instance's originals in memory, so an unchanged
  # local file isn't read and hashed again on every request, and a cached
  # image from an origin can be found without downloading the original. The
  # process owns the table; requests read and write it directly.
  #
  # A full table forgets the least recently used of a few sampled records.
  @moduledoc false
  use GenServer

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

  # A table that is missing while its owner restarts is read as empty and
  # skips writes: the record is only a shortcut past a fetch or a hash.
  #
  # Each row carries the second it was last used, written at most once a
  # second per key, so eviction can forget the least recently used.
  @spec get(atom(), String.t(), integer()) :: ImagePipe.Source.Record.t() | nil
  def get(table, key, now \\ now()) do
    case :ets.lookup(table, key) do
      [{^key, record, used}] ->
        if used < now, do: :ets.update_element(table, key, {3, now})
        record

      [] ->
        nil
    end
  rescue
    ArgumentError -> nil
  end

  # Keeps at most `limit` records: inserting a new key into a full table
  # evicts a record that wasn't used recently first.
  @spec put(atom(), String.t(), ImagePipe.Source.Record.t() | nil, pos_integer(), integer()) ::
          :ok
  def put(table, key, record, limit, now \\ now())

  def put(table, key, nil, _limit, _now) do
    :ets.delete(table, key)
    :ok
  rescue
    ArgumentError -> :ok
  end

  def put(table, key, record, limit, now) do
    make_room(table, key, limit)
    :ets.insert(table, {key, record, now})
    :ok
  rescue
    ArgumentError -> :ok
  end

  # Like `put/4`, but keeps a record already stored under `key`, which is
  # newer than one read back from disk.
  @spec put_new(atom(), String.t(), ImagePipe.Source.Record.t(), pos_integer()) :: :ok
  def put_new(table, key, record, limit) do
    make_room(table, key, limit)
    :ets.insert_new(table, {key, record, now()})
    :ok
  rescue
    ArgumentError -> :ok
  end

  defp now, do: System.monotonic_time(:second)

  defp make_room(table, key, limit) do
    if :ets.info(table, :size) >= limit and not :ets.member(table, key),
      do: evict(table)
  end

  @samples 5
  @tries 16

  # Forgets the least recently used record of a few random hash slots. A
  # table has about as many slots as records, and about a third are empty.
  defp evict(table) do
    case sample(table, :ets.info(table, :size), @samples, @tries, []) do
      [] -> :ets.delete(table, :ets.first(table))
      rows -> :ets.delete(table, rows |> Enum.min_by(&elem(&1, 2)) |> elem(0))
    end
  end

  defp sample(_table, _size, 0, _tries, rows), do: rows
  defp sample(_table, _size, _slots, 0, rows), do: rows

  defp sample(table, size, slots, tries, rows) do
    case :ets.slot(table, :rand.uniform(size) - 1) do
      [_ | _] = slot -> sample(table, size, slots - 1, tries - 1, slot ++ rows)
      _empty -> sample(table, size, slots, tries - 1, rows)
    end
  end
end
