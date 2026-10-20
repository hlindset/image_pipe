defmodule ImagePipe.Cache.SourceRecords do
  # Keeps the records of an instance's originals in memory, so an unchanged
  # local file isn't read and hashed again on every request. The
  # process owns the table; requests read and write it directly.
  #
  # A full table evicts a random record. A miss costs only one more hash, so
  # nothing tracks which records are used.
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
  # skips writes: the record is only a shortcut past a hash.
  @spec get(atom(), String.t()) :: ImagePipe.Source.Record.t() | nil
  def get(table, key) do
    case :ets.lookup(table, key) do
      [{^key, record}] -> record
      [] -> nil
    end
  rescue
    ArgumentError -> nil
  end

  # Keeps at most `limit` records: inserting a new key into a full table
  # evicts a random record first.
  @spec put(atom(), String.t(), ImagePipe.Source.Record.t() | nil, pos_integer()) :: :ok
  def put(table, key, nil, _limit) do
    :ets.delete(table, key)
    :ok
  rescue
    ArgumentError -> :ok
  end

  def put(table, key, record, limit) do
    if :ets.info(table, :size) >= limit and not :ets.member(table, key),
      do: evict(table)

    :ets.insert(table, {key, record})
    :ok
  rescue
    ArgumentError -> :ok
  end

  # A random hash slot below the table's size usually holds a record. When it
  # doesn't, the first record goes instead.
  defp evict(table) do
    case :ets.slot(table, :rand.uniform(:ets.info(table, :size)) - 1) do
      [{key, _record} | _rest] -> :ets.delete(table, key)
      _empty -> :ets.delete(table, :ets.first(table))
    end
  end
end
