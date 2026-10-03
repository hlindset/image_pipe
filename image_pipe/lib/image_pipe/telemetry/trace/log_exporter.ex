defmodule ImagePipe.Telemetry.Trace.LogExporter do
  @moduledoc """
  An `ImagePipe.Telemetry.Trace.Exporter` that logs one `Logger.info` line
  per finished span.

      ImagePipe.Telemetry.attach_tracer(exporter: ImagePipe.Telemetry.Trace.LogExporter)

  A line looks like this:

  ```text
  image_pipe.trace trace=4bf92f3577b34da6a3ce929d0e0e4736 span=00f067aa0ba902b7 parent=- image_pipe.request dur=48211000 status=ok
  ```

    * `trace`, `span`, and `parent`: hexadecimal IDs. `parent` is `-` for a
      span with no parent.
    * `dur`: the duration in native time units, or `-` when unknown.
    * `status`: `ok`, `error`, or `unset`.

  Spans are logged as they finish, so a child is logged before its parent.
  Rebuild the tree from the `parent` field.
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
