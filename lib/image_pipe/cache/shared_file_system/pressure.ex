defmodule ImagePipe.Cache.SharedFileSystem.Pressure do
  @moduledoc false

  alias ImagePipe.Cache.SharedFileSystem.{Retainer, Usage}

  def run(context, opts, timeout) do
    deadline = System.monotonic_time(:millisecond) + timeout
    now = opts[:clock].()

    with {:ok, partition, stats} <- Retainer.usage(context.retainer, remaining(deadline)),
         :ok <- Usage.publish(context.pool, partition, stats, now, remaining(deadline)) do
      apply_target(context, partition, stats, now, opts, deadline)
    end
  end

  defp apply_target(context, partition, stats, now, opts, deadline) do
    case opts[:root_max_bytes] do
      nil ->
        {:ok, %{pressure: :disabled}}

      _maximum ->
        limits = %{
          partitions: opts[:usage_max_partitions],
          max_age: max(div(opts[:inventory_interval] * 3, 1_000), 1),
          clock_skew: opts[:clock_skew]
        }

        with {:ok, snapshot} <-
               Usage.snapshot(context.pool, partition.root, now, limits, remaining(deadline)) do
          resize(context, stats, snapshot, opts, deadline)
        end
    end
  end

  defp resize(context, stats, snapshot, opts, deadline) do
    proposed =
      Usage.target(
        stats.bytes,
        stats.capacity,
        snapshot.bytes,
        opts[:max_retained_bytes],
        opts[:root_max_bytes],
        opts[:root_low_watermark]
      )

    # A partial view can justify reduction, but cannot justify expansion.
    target =
      case snapshot do
        %{scan: :complete, result: :complete, unavailable: 0} -> proposed
        _partial -> min(proposed, stats.capacity)
      end

    with {:ok, status} <- Retainer.resize(context.retainer, target, remaining(deadline)) do
      {:ok, Map.merge(snapshot, %{pressure: status, target: target})}
    end
  end

  defp remaining(deadline), do: max(deadline - System.monotonic_time(:millisecond), 0)
end
