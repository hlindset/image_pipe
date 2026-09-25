defmodule ImagePipe.Cache.SharedFileSystem.Reclamation do
  @moduledoc false

  alias ImagePipe.Cache.SharedFileSystem.{Directory, Discovery, Partition, Retainer}
  alias ImagePipe.Cache.SharedFileSystem.IO, as: CacheIO

  def run(context, opts, timeout) do
    deadline = System.monotonic_time(:millisecond) + timeout
    partition = context.partition

    with {:ok, retired} <-
           run_io(
             context.pool,
             {__MODULE__, :retire,
              [
                partition.root,
                partition.id,
                System.system_time(:second),
                opts[:inactivity_grace],
                opts[:reclaim_max_partitions]
              ]},
             opts[:reclaim_max_partitions] * 4_096,
             deadline
           ),
         {:ok, swept} <-
           run_io(
             context.pool,
             {Directory, :sweep,
              [Path.join(partition.root, "trash"), opts[:reclaim_max_entries]]},
             1_048_576,
             deadline
           ) do
      CacheIO.retry_cleanup(context.pool)
      retry = Retainer.retry(context.retainer, remaining(deadline))
      {:ok, %{partitions: retired, trash: swept, cleanup_retry: retry}}
    end
  end

  # Called only through isolated I/O. A heartbeat is an eviction hint, not a lock.
  def retire(root, owner, now, grace, limit) do
    with {:ok, partitions, status} <- Discovery.partitions(root, limit) do
      initial = %{checked: 0, retired: 0, errors: 0, scan: status}
      {:ok, Enum.reduce(partitions, initial, &retire_candidate(&1, owner, now, grace, &2))}
    end
  end

  defp retire_candidate(%{id: owner}, owner, _now, _grace, stats), do: stats

  defp retire_candidate(partition, _owner, now, grace, stats) do
    stats = %{stats | checked: stats.checked + 1}

    case activity(partition) do
      {:ok, modified} when now - modified > grace -> retire_partition(partition, stats)
      {:ok, _fresh} -> stats
      {:error, :enoent} -> stats
      {:error, _reason} -> %{stats | errors: stats.errors + 1}
    end
  end

  defp activity(partition) do
    case File.lstat(partition.path, time: :posix) do
      {:ok, %File.Stat{type: :directory, mtime: created}} ->
        heartbeat_time(partition, created)

      {:ok, _unexpected} ->
        {:error, :invalid_partition}

      error ->
        error
    end
  end

  defp heartbeat_time(partition, created) do
    case File.lstat(Path.join(partition.path, "heartbeat"), time: :posix) do
      {:ok, %File.Stat{type: :regular, mtime: modified}} -> {:ok, modified}
      {:error, :enoent} -> {:ok, created}
      {:ok, _unexpected} -> {:error, :invalid_heartbeat}
      error -> error
    end
  end

  defp retire_partition(partition, stats) do
    case Partition.retire(partition) do
      {:ok, _retired} -> %{stats | retired: stats.retired + 1}
      {:error, _reason} -> %{stats | errors: stats.errors + 1}
    end
  end

  defp run_io(pool, operation, bytes, deadline) do
    case CacheIO.run(pool, operation, bytes, remaining(deadline)) do
      {:ok, result} -> result
      error -> error
    end
  end

  defp remaining(deadline), do: max(deadline - System.monotonic_time(:millisecond), 0)
end
