defmodule ImagePipe.Cache.SharedFileSystem.Inventory do
  @moduledoc false

  alias ImagePipe.Cache.SharedFileSystem.Inventory.Storage
  alias ImagePipe.Cache.SharedFileSystem.IO, as: CacheIO
  alias ImagePipe.Cache.SharedFileSystem.Partition
  alias ImagePipe.Cache.SharedFileSystem.Transient

  # The retention owner supplies its own locations in descending usefulness.
  # Importing the resulting hints neither records demand nor adopts a body.
  def publish(pool, partition, locations, now, limits, timeout) do
    deadline = System.monotonic_time(:millisecond) + timeout
    id = Base.encode16(:crypto.strong_rand_bytes(16), case: :lower)
    stage = Path.join([partition.path, "staging", id])

    envelope = %{
      format: 1,
      incarnation: partition.id,
      publication: id,
      created_at: now,
      entries: []
    }

    with {:ok, encoded} <- encode(envelope, locations, limits),
         {:ok, lease} <-
           CacheIO.reserve(
             pool,
             byte_size(encoded),
             {Transient, :remove, [stage]},
             remaining(deadline)
           ) do
      result =
        run(pool, {Storage, :publish, [partition.path, stage, encoded]}, limits, deadline, lease)

      CacheIO.close(pool, lease)
      result
    end
  end

  def read(pool, partition, now, limits, timeout) do
    deadline = System.monotonic_time(:millisecond) + timeout

    with {:ok, encoded} <-
           run(
             pool,
             {Storage, :read, [Path.join(partition.path, "inventory"), limits.bytes]},
             limits,
             deadline,
             nil
           ) do
      decode(encoded, partition, now, limits)
    end
  end

  defp encode(envelope, locations, limits) do
    case :erlang.external_size(envelope) <= limits.bytes do
      false ->
        {:error, :inventory_too_large}

      true ->
        entries =
          locations
          |> Enum.take(limits.entries)
          |> Enum.reduce_while([], fn location, entries ->
            append_entry(location, entries, envelope, limits.bytes)
          end)

        {:ok, :erlang.term_to_binary(%{envelope | entries: Enum.reverse(entries)})}
    end
  end

  defp append_entry(location, entries, envelope, limit) do
    next = [Map.take(location, [:kind, :key, :generation]) | entries]

    case :erlang.external_size(%{envelope | entries: next}) <= limit do
      true -> {:cont, next}
      false -> {:halt, entries}
    end
  end

  defp decode(<<131, 80, _rest::binary>>, _partition, _now, _limits),
    do: {:error, :corrupt_inventory}

  defp decode(encoded, partition, now, limits) do
    case :erlang.binary_to_term(encoded, [:safe, :used]) do
      {envelope, used} when used == byte_size(encoded) ->
        validate(envelope, partition, now, limits)

      _trailing ->
        {:error, :corrupt_inventory}
    end
  rescue
    ArgumentError -> {:error, :corrupt_inventory}
  end

  defp validate(
         %{
           format: 1,
           incarnation: id,
           publication: publication,
           created_at: created,
           entries: entries
         },
         %{id: id} = partition,
         now,
         limits
       )
       when is_integer(created) and is_list(entries) do
    cond do
      not identifier?(publication, 32) or length(entries) > limits.entries or
          not Enum.all?(entries, &entry?/1) ->
        {:error, :corrupt_inventory}

      created > now + limits.clock_skew ->
        {:error, :untrusted_clock}

      now - created > limits.max_age ->
        {:error, :stale_inventory}

      true ->
        {:ok, Enum.map(entries, &location(partition, &1))}
    end
  end

  defp validate(_envelope, _partition, _now, _limits), do: {:error, :corrupt_inventory}

  defp entry?(%{kind: kind, key: key, generation: generation})
       when kind in [:outputs, :originals, :sources],
       do: identifier?(key, 64) and identifier?(generation, 32)

  defp entry?(_entry), do: false

  defp identifier?(value, size) when is_binary(value) and byte_size(value) == size,
    do: Regex.match?(~r/\A[0-9a-f]+\z/, value)

  defp identifier?(_value, _size), do: false

  defp location(partition, entry) do
    parent = Partition.key_directory(partition, entry.kind, entry.key)
    Partition.location(parent, entry.kind, entry.key, entry.generation)
  end

  defp run(pool, operation, limits, deadline, lease) do
    case CacheIO.run(pool, operation, 64 * limits.bytes, remaining(deadline), lease) do
      {:ok, result} -> result
      error -> error
    end
  end

  defp remaining(deadline), do: max(deadline - System.monotonic_time(:millisecond), 0)
end
