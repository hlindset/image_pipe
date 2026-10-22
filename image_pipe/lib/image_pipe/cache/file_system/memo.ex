defmodule ImagePipe.Cache.FileSystem.Memo do
  # Keeps the metadata of a cache's recently hit entries in memory, so a hit
  # reads only the body from disk. A cache root's Admission owns its table
  # and, after each change to an entry's files, forgets the entry here.
  #
  # A request remembers metadata it read from disk only if its entry didn't
  # change while it read: it takes the entry's epoch before the read and
  # checks it after the insert. Admission bumps the epoch before it deletes
  # the row, so a change either moves the epoch before the check or deletes
  # the inserted row. Entries share 1,024 epochs by hash, so a change to one
  # entry rarely drops another's fill. Every epoch moves when the table is
  # created, so a fill that started before a restart isn't remembered.
  #
  # The table and its counters, the limit and the epochs, are found through a
  # persistent term per root, created once, like the root's lookup counters.
  @moduledoc false

  alias ImagePipe.Cache.RecentTable

  @limit 1
  @slots 1024

  # Unless `max_remembered_entries` sets it, one row for each 50 KB the cache
  # may store, from 1,000 to 50,000.
  @spec limit_for(pos_integer()) :: pos_integer()
  def limit_for(max_size_bytes), do: max_size_bytes |> div(50_000) |> max(1_000) |> min(50_000)

  # Creates the root's table, owned by the calling process.
  @spec start(Path.t(), pos_integer()) :: :ok
  def start(root, limit) do
    {table, counters} = ensure(root)
    :atomics.put(counters, @limit, limit)
    for slot <- 0..(@slots - 1), do: :atomics.add(counters, index(slot), 1)

    ^table =
      :ets.new(table, [
        :named_table,
        :public,
        :set,
        read_concurrency: true,
        write_concurrency: true
      ])

    :ok
  end

  @spec get(Path.t(), String.t()) :: term() | nil
  def get(root, key_hash) do
    case refs(root) do
      nil -> nil
      {table, _counters} -> RecentTable.get(table, key_hash)
    end
  end

  # The epoch to pass to `remember/4` for a read of `key_hash` that starts
  # now.
  @spec epoch(Path.t(), String.t()) :: integer() | nil
  def epoch(root, key_hash) do
    case refs(root) do
      nil -> nil
      {_table, counters} -> :atomics.get(counters, epoch_index(key_hash))
    end
  end

  @spec remember(Path.t(), String.t(), integer() | nil, term()) :: :ok
  def remember(_root, _key_hash, nil, _value), do: :ok

  def remember(root, key_hash, epoch, value) do
    {table, counters} = refs(root)
    RecentTable.put(table, key_hash, value, :atomics.get(counters, @limit))

    if :atomics.get(counters, epoch_index(key_hash)) != epoch,
      do: RecentTable.delete(table, key_hash)

    :ok
  end

  # Forgets a row a request found out of date.
  @spec drop(Path.t(), String.t()) :: :ok
  def drop(root, key_hash) do
    case refs(root) do
      nil -> :ok
      {table, _counters} -> RecentTable.delete(table, key_hash)
    end
  end

  # Forgets entries whose files changed. Admission calls it after the change.
  @spec forget(Path.t(), [String.t()]) :: :ok
  def forget(_root, []), do: :ok

  def forget(root, key_hashes) do
    {table, counters} = refs(root)

    Enum.each(key_hashes, fn key_hash ->
      :atomics.add(counters, epoch_index(key_hash), 1)
      RecentTable.delete(table, key_hash)
    end)
  end

  @doc false
  def limit(root), do: root |> refs() |> elem(1) |> :atomics.get(@limit)

  @doc false
  def size(root), do: root |> refs() |> elem(0) |> :ets.info(:size)

  defp epoch_index(key_hash), do: key_hash |> :erlang.phash2(@slots) |> index()
  defp index(slot), do: slot + 2

  defp refs(root), do: :persistent_term.get({__MODULE__, root}, nil)

  # Roots are static host configuration, so the derived table names are
  # bounded.
  defp ensure(root) do
    case refs(root) do
      nil ->
        hash = :crypto.hash(:sha256, root) |> Base.encode16(case: :lower) |> binary_part(0, 16)
        refs = {Module.concat(__MODULE__, hash), :atomics.new(@slots + 1, signed: true)}
        :persistent_term.put({__MODULE__, root}, refs)
        refs

      refs ->
        refs
    end
  end
end
