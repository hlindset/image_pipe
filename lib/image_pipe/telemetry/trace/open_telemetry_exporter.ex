defmodule ImagePipe.Telemetry.Trace.OpenTelemetryExporter do
  @moduledoc """
  Opt-in `ImagePipe.Telemetry.Trace.Exporter` that replays finished `%Trace.Span{}`
  structs into a host-running OpenTelemetry SDK using the **public** OTel API.

  Spans are buffered per trace and replayed top-down when the trace's root span
  finishes, so children are parented onto their parent's real OTel-minted span
  context and the full hierarchy survives into Jaeger/Tempo. Correlation with
  logs (`LogExporter`) is trace-level: both share the `trace_id` (forced onto
  the OTel trace via a synthetic W3C remote parent on the root span); OTel
  mints its own span ids, so `span=` ids in log lines do not match OTel span ids.

  Optional dependency `:opentelemetry_api` (compile); the host brings the SDK
  (`:opentelemetry`) and starts it. When the API is absent, `ready?/0` is `false`
  and `attach_tracer/1` raises. When the API is present but the SDK isn't started,
  the API degrades to a noop tracer and this produces nothing — no crash.
  """
  @behaviour ImagePipe.Telemetry.Trace.Exporter

  alias ImagePipe.Telemetry.Trace.{OtelReplay, Span}

  @otel_api_loaded Code.ensure_loaded?(:otel_tracer)

  @doc "Whether the OpenTelemetry API is compiled in."
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
