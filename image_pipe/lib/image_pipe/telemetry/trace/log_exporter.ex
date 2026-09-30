defmodule ImagePipe.Telemetry.Trace.LogExporter do
  @moduledoc """
  Stdlib `Logger` exporter: one flat structured line per completed span.

  Stateless by design — it does NOT buffer spans into a tree or wait for a root
  to close. Each span is logged on its own as `:stop`/`:exception` fires, in the
  process that emitted it. Parentage is carried in the `parent=` field so a
  downstream log pipeline can reconstruct nesting; this exporter never holds
  state between spans.
  """
  @behaviour ImagePipe.Telemetry.Trace.Exporter
  require Logger
  alias ImagePipe.Telemetry.Trace.Span

  @impl true
  @spec export(Span.t()) :: :ok
  def export(%Span{} = span) do
    Logger.info(fn ->
      status =
        case span.status do
          nil -> "unset"
          other -> to_string(other)
        end

      "image_pipe.trace " <>
        "trace=#{span.trace_id} span=#{span.span_id} parent=#{span.parent_span_id || "-"} " <>
        "#{span.name} dur=#{span.duration_native || "-"} status=#{status}"
    end)

    :ok
  end
end
