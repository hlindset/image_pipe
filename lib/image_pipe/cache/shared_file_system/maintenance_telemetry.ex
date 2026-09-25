defmodule ImagePipe.Cache.SharedFileSystem.MaintenanceTelemetry do
  @moduledoc false

  alias ImagePipe.Telemetry

  def run(opts, operation, fun) do
    Telemetry.span(opts, [:cache, :shared_maintenance], %{operation: operation}, fn ->
      result = fun.()
      {result, summary(operation, result)}
    end)
  end

  defp summary(:warmup, {:ok, stats}) do
    result =
      cond do
        stats.result not in [:complete, :full] -> :cache_error
        stats.partitions == :limited or stats.candidates == :limited -> :partial
        true -> :ok
      end

    %{result: result, checked: stats.checked, imported: stats.imported}
  end

  defp summary(:reclamation, {:ok, %{partitions: partitions, trash: trash, cleanup_retry: retry}}) do
    errors = partitions.errors + trash.errors

    result =
      cond do
        errors > 0 or match?({:error, _}, retry) -> :cache_error
        partitions.scan == :limited or trash.limited -> :partial
        true -> :ok
      end

    %{result: result, checked: partitions.checked, removed: trash.removed, errors: errors}
  end

  defp summary(:pressure, {:ok, %{pressure: :disabled, usage_publication: publication}}),
    do: %{result: if(publication == :ok, do: :ok, else: :cache_error)}

  defp summary(:pressure, {:ok, stats}) do
    result =
      cond do
        stats.usage_publication != :ok -> :cache_error
        stats.scan == :complete and stats.result == :complete and stats.unavailable == 0 -> :ok
        true -> :partial
      end

    %{
      result: result,
      logical_bytes: stats.bytes,
      target_bytes: stats.target,
      unavailable: stats.unavailable
    }
  end

  defp summary(operation, :ok) when operation in [:inventory, :usage], do: %{result: :ok}
  defp summary(_operation, {:error, _reason}), do: %{result: :cache_error}
end
