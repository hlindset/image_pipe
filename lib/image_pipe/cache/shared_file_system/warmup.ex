defmodule ImagePipe.Cache.SharedFileSystem.Warmup do
  @moduledoc false

  alias ImagePipe.Cache.SharedFileSystem.{Discovery, Generation, Inventory, Locations}
  alias ImagePipe.Cache.SharedFileSystem.IO, as: CacheIO

  def run(context, now, limits, timeout) do
    deadline = System.monotonic_time(:millisecond) + timeout

    with {:ok, {:ok, partitions, status}} <-
           CacheIO.run(
             context.pool,
             {Discovery, :partitions, [context.partition.root, limits.partitions]},
             limits.partitions * 4_096,
             remaining(deadline)
           ) do
      lists = inventories(context, partitions, now, limits.inventory, deadline)
      {candidates, candidate_status} = interleave(lists, limits.candidates, [])

      seed(context, candidates, deadline, %{
        checked: 0,
        imported: 0,
        partitions: status,
        candidates: candidate_status
      })
    end
  end

  defp inventories(context, partitions, now, limits, deadline) do
    Enum.reduce_while(partitions, [], fn partition, lists ->
      cond do
        remaining(deadline) == 0 ->
          {:halt, lists}

        partition.id == context.partition.id ->
          {:cont, lists}

        true ->
          {:cont, read_inventory(context.pool, partition, now, limits, deadline, lists)}
      end
    end)
    |> Enum.reverse()
  end

  defp read_inventory(pool, partition, now, limits, deadline, lists) do
    case Inventory.read(pool, partition, now, limits, remaining(deadline)) do
      {:ok, locations} -> [locations | lists]
      _unusable -> lists
    end
  end

  defp interleave(lists, 0, found),
    do: {Enum.reverse(found), if(Enum.any?(lists, &(&1 != [])), do: :limited, else: :complete)}

  defp interleave([], _remaining, found), do: {Enum.reverse(found), :complete}
  defp interleave([[] | rest], remaining, found), do: interleave(rest, remaining, found)

  defp interleave([[first | tail] | rest], remaining, found),
    do: interleave(rest ++ [tail], remaining - 1, [first | found])

  defp seed(_context, [], deadline, stats),
    do:
      {:ok, Map.put(stats, :result, if(remaining(deadline) == 0, do: :timeout, else: :complete))}

  defp seed(context, [candidate | rest], deadline, stats) do
    case remaining(deadline) do
      0 ->
        {:ok, Map.put(stats, :result, :timeout)}

      _remaining ->
        stats = %{stats | checked: stats.checked + 1}

        case Generation.metadata(context.pool, candidate, context.limits, remaining(deadline)) do
          {:ok, _metadata} -> import(context, candidate, rest, deadline, stats)
          _unusable -> seed(context, rest, deadline, stats)
        end
    end
  end

  defp import(context, candidate, rest, deadline, stats) do
    case Locations.seed(context.locations, [candidate], remaining(deadline)) do
      {:ok, count, :complete} ->
        seed(context, rest, deadline, %{stats | imported: stats.imported + count})

      {:ok, _count, :full} ->
        {:ok, Map.put(stats, :result, :full)}

      {:error, reason} ->
        {:ok, Map.put(stats, :result, reason)}
    end
  end

  defp remaining(deadline), do: max(deadline - System.monotonic_time(:millisecond), 0)
end
