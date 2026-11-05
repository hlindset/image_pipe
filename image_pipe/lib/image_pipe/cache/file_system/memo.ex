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
  # It also keeps the bodies of recently hit small entries, so a hit sends
  # them without a file call. Admission alone stores and forgets bodies, so
  # it counts their bytes exactly. A request reads a body it doesn't find
  # from disk and asks Admission to keep it, with the epoch it took before
  # the read, and Admission keeps it only if the epoch hasn't moved.
  #
  # The tables and their counters, the limits, the epochs, and the body
  # bytes, are found through a persistent term per root, created once, like
  # the root's lookup counters.
  @moduledoc false

  alias ImagePipe.Cache.RecentTable

  @limit 1
  @slots 1024
  @body_bytes @slots + 2
  @max_body_bytes @slots + 3
  @max_body 65_536

  # Unless `max_remembered_entries` sets it, one row for each 50 KB the cache
  # may store and for each 50 KB of the memory limit, whichever is fewer,
  # from 1,000 to 50,000. A row takes about 1.4 KB, so the rows fit in 2.8%
  # of the limit above the floor.
  @spec limit_for(pos_integer(), pos_integer() | nil) :: pos_integer()
  def limit_for(max_size_bytes, memory_limit) do
    min(max_size_bytes, memory_limit || max_size_bytes)
    |> div(50_000)
    |> max(1_000)
    |> min(50_000)
  end

  # Creates the root's tables, owned by the calling process.
  @spec start(Path.t(), pos_integer(), non_neg_integer()) :: :ok
  def start(root, limit, max_body_bytes) do
    {table, counters} = ensure(root)
    :atomics.put(counters, @limit, limit)
    :atomics.put(counters, @body_bytes, 0)
    :atomics.put(counters, @max_body_bytes, max_body_bytes)
    for slot <- 0..(@slots - 1), do: :atomics.add(counters, index(slot), 1)

    for name <- [table, bodies(table)] do
      ^name =
        :ets.new(name, [
          :named_table,
          :public,
          :set,
          read_concurrency: true,
          write_concurrency: true
        ])
    end

    :ok
  end

  # Whether a body of `size` bytes may be kept in memory.
  @spec keeps_body?(Path.t(), non_neg_integer()) :: boolean()
  def keeps_body?(root, size) do
    case refs(root) do
      nil ->
        false

      {_table, counters} ->
        max = :atomics.get(counters, @max_body_bytes)
        max > 0 and size <= @max_body and size <= max
    end
  end

  @spec body(Path.t(), String.t()) :: binary() | nil
  def body(root, key_hash) do
    case refs(root) do
      nil -> nil
      {table, _counters} -> RecentTable.get(bodies(table), key_hash)
    end
  end

  # Keeps a body a request read from disk, unless its entry changed since
  # `epoch`, making room by forgetting bodies that weren't used recently.
  # Only Admission calls it.
  @spec keep_body(Path.t(), String.t(), integer() | nil, binary()) :: :ok
  def keep_body(root, key_hash, epoch, bytes) do
    {table, counters} = refs(root)
    bodies = bodies(table)
    size = byte_size(bytes)

    if epoch != nil and :atomics.get(counters, epoch_index(key_hash)) == epoch and
         keeps_body?(root, size) and not :ets.member(bodies, key_hash) and
         make_body_room(bodies, counters, size, 64) do
      :ets.insert(bodies, {key_hash, bytes, System.monotonic_time(:second)})
      :atomics.add(counters, @body_bytes, size)
    end

    :ok
  end

  defp make_body_room(bodies, counters, size, tries) do
    cond do
      :atomics.get(counters, @body_bytes) + size <= :atomics.get(counters, @max_body_bytes) ->
        true

      tries == 0 ->
        false

      true ->
        case RecentTable.least_used(bodies) do
          nil -> false
          key_hash -> drop_body(bodies, counters, key_hash)
        end

        make_body_room(bodies, counters, size, tries - 1)
    end
  end

  defp drop_body(bodies, counters, key_hash) do
    case :ets.take(bodies, key_hash) do
      [{^key_hash, bytes, _used}] -> :atomics.sub(counters, @body_bytes, byte_size(bytes))
      [] -> :ok
    end
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
      drop_body(bodies(table), counters, key_hash)
    end)
  end

  @doc false
  def limit(root), do: root |> refs() |> elem(1) |> :atomics.get(@limit)

  @doc false
  def size(root), do: root |> refs() |> elem(0) |> :ets.info(:size)

  @doc false
  def body_bytes(root), do: root |> refs() |> elem(1) |> :atomics.get(@body_bytes)

  @doc false
  def max_body_bytes(root), do: root |> refs() |> elem(1) |> :atomics.get(@max_body_bytes)

  defp bodies(table), do: Module.concat(table, Bodies)

  defp epoch_index(key_hash), do: key_hash |> :erlang.phash2(@slots) |> index()
  defp index(slot), do: slot + 2

  defp refs(root), do: :persistent_term.get({__MODULE__, root}, nil)

  # Roots are static host configuration, so the derived table names are
  # bounded.
  defp ensure(root) do
    case refs(root) do
      nil ->
        hash = :crypto.hash(:sha256, root) |> Base.encode16(case: :lower) |> binary_part(0, 16)
        refs = {Module.concat(__MODULE__, hash), :atomics.new(@slots + 3, signed: true)}
        :persistent_term.put({__MODULE__, root}, refs)
        refs

      refs ->
        refs
    end
  end
end
