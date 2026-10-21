defmodule ImagePipe.Cache.RecentTable do
  # An ETS table of at most a limit of rows, `{key, value, used}`, that
  # forgets the least recently used of a few sampled rows when full. Its
  # owner creates the table. A table that is missing while its owner
  # restarts is read as empty and skips writes, since its users keep only
  # shortcuts in it.
  #
  # `used` is the second a row was last read or written, updated at most
  # once a second per key.
  @moduledoc false

  @spec get(atom(), term(), integer()) :: term() | nil
  def get(table, key, now \\ now()) do
    case :ets.lookup(table, key) do
      [{^key, value, used}] ->
        if used < now, do: :ets.update_element(table, key, {3, now})
        value

      [] ->
        nil
    end
  rescue
    ArgumentError -> nil
  end

  # Inserting a new key into a full table evicts a row that wasn't used
  # recently first.
  @spec put(atom(), term(), term(), pos_integer(), integer()) :: :ok
  def put(table, key, value, limit, now \\ now()) do
    make_room(table, key, limit)
    :ets.insert(table, {key, value, now})
    :ok
  rescue
    ArgumentError -> :ok
  end

  # Like `put/5`, but keeps a row already stored under `key`.
  @spec put_new(atom(), term(), term(), pos_integer()) :: :ok
  def put_new(table, key, value, limit) do
    make_room(table, key, limit)
    :ets.insert_new(table, {key, value, now()})
    :ok
  rescue
    ArgumentError -> :ok
  end

  @spec delete(atom(), term()) :: :ok
  def delete(table, key) do
    :ets.delete(table, key)
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

  # Forgets the least recently used row of a few random hash slots. A table
  # has about as many slots as rows, and about a third are empty.
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
