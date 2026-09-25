defmodule ImagePipe.Cache.SharedFileSystem.Index do
  @moduledoc false

  def new(opts) do
    max_keys = Keyword.fetch!(opts, :max_keys)
    max_bytes = Keyword.fetch!(opts, :max_bytes)
    fraction = Keyword.fetch!(opts, :warm_fraction)

    %{
      entries: %{},
      order: :gb_trees.empty(),
      sequence: 0,
      bytes: 0,
      warm_keys: 0,
      warm_bytes: 0,
      max_keys: max_keys,
      max_bytes: max_bytes,
      max_locations: Keyword.fetch!(opts, :max_locations),
      max_warm_keys: floor(max_keys * fraction),
      max_warm_bytes: floor(max_bytes * fraction)
    }
  end

  # Looking at a hint is not a successful cache access.
  def lookup(index, kind, key) do
    case Map.get(index.entries, {kind, key}) do
      nil -> []
      entry -> :erlang.binary_to_term(entry.encoded, [:safe])
    end
  end

  def remember(index, location) do
    locations =
      [location | List.delete(lookup(index, location.kind, location.key), location)]
      |> Enum.take(index.max_locations)

    retain(index, {location.kind, location.key}, locations, :hot, index.max_bytes)
  end

  # Inventories never refresh existing recency or push requested keys out.
  def warm(index, location) do
    key = {location.kind, location.key}

    case Map.has_key?(index.entries, key) or index.max_warm_keys == 0 do
      true -> index
      false -> retain(index, key, [location], :warm, index.max_warm_bytes)
    end
  end

  # Ranked imports preserve the useful prefix instead of cycling warm victims.
  def seed(index, locations) do
    Enum.reduce_while(locations, {index, 0, :complete}, fn location, {index, count, :complete} ->
      key = {location.kind, location.key}

      case Map.has_key?(index.entries, key) do
        true -> {:cont, {index, count, :complete}}
        false -> seed_entry(index, location, key, count)
      end
    end)
  end

  defp seed_entry(index, location, key, count) do
    case fit_payload(key, [location], index.max_warm_bytes) do
      {_locations, bytes} ->
        case room?(index, bytes, :warm) do
          true -> {:cont, {warm(index, location), count + 1, :complete}}
          false -> {:halt, {index, count, :full}}
        end

      nil ->
        {:halt, {index, count, :full}}
    end
  end

  def forget(index, location) do
    key = {location.kind, location.key}

    case Map.fetch(index.entries, key) do
      :error ->
        index

      {:ok, entry} ->
        remaining = List.delete(lookup(index, location.kind, location.key), location)
        replace_locations(index, key, entry, remaining)
    end
  end

  def stats(index),
    do: %{
      keys: map_size(index.entries),
      bytes: index.bytes,
      warm_keys: index.warm_keys,
      warm_bytes: index.warm_bytes
    }

  defp retain(index, key, locations, priority, limit) do
    case fit_payload(key, locations, limit) do
      nil ->
        index

      {locations, bytes} ->
        case make_room(remove(index, key), bytes, priority) do
          nil ->
            index

          available ->
            order = {rank(priority), available.sequence + 1}

            entry = %{
              encoded: :erlang.term_to_binary(locations),
              bytes: bytes,
              order: order,
              priority: priority
            }

            insert(%{available | sequence: available.sequence + 1}, key, entry)
        end
    end
  end

  defp fit_payload(_key, [], _limit), do: nil

  defp fit_payload(key, locations, limit) do
    bytes = :erlang.external_size({key, locations})

    case bytes <= limit do
      true -> {locations, bytes}
      false -> fit_payload(key, Enum.drop(locations, -1), limit)
    end
  end

  defp make_room(index, bytes, priority) do
    case room?(index, bytes, priority) do
      true -> index
      false -> evict(index, bytes, priority)
    end
  end

  defp room?(index, bytes, priority) do
    map_size(index.entries) < index.max_keys and index.bytes + bytes <= index.max_bytes and
      (priority == :hot or
         (index.warm_keys < index.max_warm_keys and
            index.warm_bytes + bytes <= index.max_warm_bytes))
  end

  defp evict(index, _bytes, _priority) when map_size(index.entries) == 0, do: nil

  defp evict(index, bytes, priority) do
    {{rank, _sequence}, key} = :gb_trees.smallest(index.order)

    case priority == :hot or rank == 0 do
      true -> index |> remove(key) |> make_room(bytes, priority)
      false -> nil
    end
  end

  defp replace_locations(index, key, _entry, []), do: remove(index, key)

  defp replace_locations(index, key, entry, locations) do
    entry = %{
      entry
      | encoded: :erlang.term_to_binary(locations),
        bytes: :erlang.external_size({key, locations})
    }

    index |> remove(key) |> insert(key, entry)
  end

  defp insert(index, key, entry) do
    %{
      index
      | entries: Map.put(index.entries, key, entry),
        order: :gb_trees.insert(entry.order, key, index.order),
        bytes: index.bytes + entry.bytes,
        warm_keys: index.warm_keys + warm_charge(entry, 1),
        warm_bytes: index.warm_bytes + warm_charge(entry, entry.bytes)
    }
  end

  defp remove(index, key) do
    case Map.pop(index.entries, key) do
      {nil, _entries} ->
        index

      {entry, entries} ->
        %{
          index
          | entries: entries,
            order: :gb_trees.delete(entry.order, index.order),
            bytes: index.bytes - entry.bytes,
            warm_keys: index.warm_keys - warm_charge(entry, 1),
            warm_bytes: index.warm_bytes - warm_charge(entry, entry.bytes)
        }
    end
  end

  defp rank(:warm), do: 0
  defp rank(:hot), do: 1
  defp warm_charge(%{priority: :warm}, value), do: value
  defp warm_charge(%{priority: :hot}, _value), do: 0
end
