defmodule ImagePipe.Telemetry.Trace.OpenTelemetryExporter do
  @moduledoc """
  An `ImagePipe.Telemetry.Trace.Exporter` that replays spans into the
  OpenTelemetry SDK your application runs, through the public OpenTelemetry
  API.

      ImagePipe.Telemetry.attach_tracer(exporter: ImagePipe.Telemetry.Trace.OpenTelemetryExporter)

  Spans are buffered per trace and replayed when the trace's root span
  finishes, so each one is created under its real parent. The trace ID stays
  ImagePipe's, so it matches `ImagePipe.Telemetry.Trace.LogExporter` lines,
  but the SDK creates new span IDs. Set
  `ImagePipe.Telemetry.Trace.OtelIdGenerator` as the SDK's `id_generator` so
  new traces export as true root spans. The steps are in
  [Exporting traces to Jaeger](opentelemetry-jaeger.md), and the replay is
  explained in [Request tracing](tracing.md#trace-and-span-ids).

  ## Replay limits

  Replay is best effort:

    * Buffered traces are lost if the buffer process crashes or the node
      shuts down. No flush runs at shutdown.
    * While 10,000 traces are buffered, spans of new traces are dropped.
    * A trace whose root hasn't finished after about 10 seconds is exported
      as it is. Spans whose parent is in the exported set keep it, and the
      others have a parent that is missing from the trace.
    * A span from another process that finishes up to about 10 seconds
      after its trace was exported still gets its parent, if the parent was
      already exported. Otherwise its parent is missing.

  ImagePipe depends on `:opentelemetry_api` as an optional dependency, and
  your application adds the SDK (`:opentelemetry`) and starts it. Without the
  API at compile time, `ready?/0` returns `false` and `attach_tracer/1`
  raises. With the API but no running SDK, spans are dropped.
  """
  @behaviour ImagePipe.Telemetry.Trace.Exporter

  alias ImagePipe.Telemetry.Trace.{OtelReplay, Span}

  @otel_api_loaded Code.ensure_loaded?(:otel_tracer)

  @doc """
  Returns whether the OpenTelemetry API was available when ImagePipe was
  compiled. Recompile ImagePipe after adding the SDK if this returns `false`.
  """
  @spec available?() :: boolean()
  def available?, do: @otel_api_loaded

  @impl true
  @spec ready?() :: boolean()
  def ready?, do: @otel_api_loaded

  @impl true
  @spec export(Span.t()) :: :ok
  # `@otel_api_loaded` is a compile-time `Code.ensure_loaded?/1` boolean, so when
  # the optional OTel API is absent Dialyzer sees the `if` branch as dead.
  @dialyzer {:no_match, export: 1}
  def export(%Span{} = span) do
    if @otel_api_loaded do
      OtelReplay.add(span)
    end

    :ok
  end
end
