defmodule ImagePipe.Cache.SharedFileSystem.Search do
  @moduledoc false

  alias ImagePipe.Cache.SharedFileSystem.Discovery
  alias ImagePipe.Cache.SharedFileSystem.IO, as: CacheIO

  # A search has one deadline, including both a cached-list attempt and refresh.
  # Candidates remain untrusted until the requesting reader opens them.
  def run(pool, root, cached, kind, key, limits, timeout) do
    deadline = System.monotonic_time(:millisecond) + timeout

    case cached do
      nil -> refresh(pool, root, kind, key, limits, deadline)
      snapshot -> search_cached(pool, root, snapshot, kind, key, limits, deadline)
    end
  end

  defp search_cached(pool, root, snapshot, kind, key, limits, deadline) do
    case candidates(pool, snapshot.partitions, kind, key, limits, deadline) do
      {:ok, [], :complete} -> refresh(pool, root, kind, key, limits, deadline)
      result -> {combine_status(result, snapshot.status), nil}
    end
  end

  defp refresh(pool, root, kind, key, limits, deadline) do
    case run_io(pool, :partitions, [root, limits.partitions], limits, deadline) do
      {:ok, partitions, partition_status} ->
        result = candidates(pool, partitions, kind, key, limits, deadline)

        {combine_status(result, partition_status),
         %{partitions: partitions, status: partition_status}}

      error ->
        {error, nil}
    end
  end

  defp candidates(pool, partitions, kind, key, limits, deadline),
    do: run_io(pool, :candidates, [partitions, kind, key, limits.candidates], limits, deadline)

  defp combine_status({:ok, candidates, _status}, :limited), do: {:ok, candidates, :limited}
  defp combine_status(result, _status), do: result

  defp run_io(pool, function, args, limits, deadline) do
    timeout = max(deadline - System.monotonic_time(:millisecond), 0)

    case CacheIO.run(pool, {Discovery, function, args}, limits.bytes, timeout) do
      {:ok, result} -> result
      error -> error
    end
  end
end
