defmodule ImagePipe.Cache.SharedFileSystem.Usage do
  @moduledoc false

  alias ImagePipe.Cache.SharedFileSystem.{Discovery, Transient}
  alias ImagePipe.Cache.SharedFileSystem.Inventory.Storage
  alias ImagePipe.Cache.SharedFileSystem.IO, as: CacheIO

  @bytes 4_096

  def publish(pool, partition, stats, now, timeout) do
    deadline = deadline(timeout)
    id = Base.encode16(:crypto.strong_rand_bytes(16), case: :lower)
    stage = Path.join([partition.path, "staging", id])

    encoded =
      :erlang.term_to_binary(
        {1, partition.id, id, now, stats.bytes, stats.pending_bytes, stats.cleanup_bytes}
      )

    with {:ok, lease} <-
           CacheIO.reserve(
             pool,
             byte_size(encoded),
             {Transient, :remove, [stage]},
             remaining(deadline)
           ) do
      result =
        run(pool, {Storage, :publish, [partition.path, stage, encoded, "usage"]}, deadline, lease)

      CacheIO.close(pool, lease)
      result
    end
  end

  def snapshot(pool, root, now, limits, timeout) do
    deadline = deadline(timeout)

    with {:ok, {:ok, partitions, status}} <-
           CacheIO.run(
             pool,
             {Discovery, :partitions, [root, limits.partitions]},
             limits.partitions * 4_096,
             remaining(deadline)
           ) do
      initial = %{
        bytes: 0,
        partitions: length(partitions),
        reported: 0,
        unavailable: 0,
        scan: status,
        result: :complete
      }

      report = collect_partitions(partitions, initial, pool, now, limits, deadline)

      result = if remaining(deadline) == 0, do: :timeout, else: report.result
      {:ok, %{report | result: result}}
    end
  end

  defp collect_partitions(partitions, initial, pool, now, limits, deadline) do
    Enum.reduce_while(partitions, initial, fn partition, report ->
      case remaining(deadline) do
        0 -> {:halt, %{report | result: :timeout}}
        _remaining -> {:cont, collect(pool, partition, now, limits, deadline, report)}
      end
    end)
  end

  # The low watermark leaves room for delayed reports and concurrent publishers.
  # Gaps in the snapshot can still underestimate storage; this is never a quota.
  def target(local, current, total, maximum, root_target, low_ratio) do
    low = trunc(root_target * low_ratio)

    cond do
      total > root_target -> min(current, div(local * low, total))
      total < low -> maximum
      true -> current
    end
  end

  defp collect(pool, partition, now, limits, deadline, report) do
    with {:ok, encoded} <-
           run(pool, {Storage, :read, [Path.join(partition.path, "usage"), @bytes]}, deadline),
         {:ok, bytes} <- decode(encoded, partition.id, now, limits) do
      %{report | bytes: report.bytes + bytes, reported: report.reported + 1}
    else
      _unusable -> %{report | unavailable: report.unavailable + 1}
    end
  end

  defp decode(<<131, 80, _rest::binary>>, _id, _now, _limits), do: {:error, :invalid_usage}

  defp decode(encoded, id, now, limits) do
    case :erlang.binary_to_term(encoded, [:safe, :used]) do
      {{1, ^id, publication, created, retained, pending, cleanup}, used}
      when used == byte_size(encoded) ->
        validate(publication, created, [retained, pending, cleanup], now, limits)

      _invalid ->
        {:error, :invalid_usage}
    end
  rescue
    ArgumentError -> {:error, :invalid_usage}
  end

  defp validate(publication, created, counts, now, limits)
       when is_binary(publication) and byte_size(publication) == 32 and is_integer(created) do
    cond do
      not Enum.all?(counts, &(is_integer(&1) and &1 >= 0)) ->
        {:error, :invalid_usage}

      created > now + limits.clock_skew or now - created > limits.max_age ->
        {:error, :stale_usage}

      true ->
        {:ok, Enum.sum(counts)}
    end
  end

  defp validate(_publication, _created, _counts, _now, _limits), do: {:error, :invalid_usage}

  defp run(pool, operation, deadline, lease \\ nil) do
    case CacheIO.run(pool, operation, @bytes * 64, remaining(deadline), lease) do
      {:ok, result} -> result
      error -> error
    end
  end

  defp deadline(timeout), do: System.monotonic_time(:millisecond) + timeout
  defp remaining(deadline), do: max(deadline - System.monotonic_time(:millisecond), 0)
end
