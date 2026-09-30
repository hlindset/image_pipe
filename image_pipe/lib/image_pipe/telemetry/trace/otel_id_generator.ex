defmodule ImagePipe.Telemetry.Trace.OtelIdGenerator do
  @moduledoc """
  OpenTelemetry SDK id generator that lets `OpenTelemetryExporter` export
  untraced requests as true root spans carrying ImagePipe's own trace id.

  Configure it on the SDK:

      config :opentelemetry, id_generator: ImagePipe.Telemetry.Trace.OtelIdGenerator

  It implements the callbacks of the SDK's `otel_id_generator` behaviour. Ids
  are random, like the SDK default, except while the exporter replays
  an ImagePipe root span: it then hands over the trace id ImagePipe minted, so
  logs and traces keep correlating on one trace id.

  Without it, the exporter still forces ImagePipe's trace id, through a
  synthetic remote parent that tracing backends report as missing.
  """

  @trace_id_key {__MODULE__, :trace_id}

  @doc false
  @spec generate_trace_id() :: pos_integer()
  def generate_trace_id do
    case Process.get(@trace_id_key) do
      nil -> :rand.uniform(2 ** 128 - 1)
      trace_id -> trace_id
    end
  end

  @doc false
  @spec generate_span_id() :: pos_integer()
  def generate_span_id, do: :rand.uniform(2 ** 64 - 1)

  @doc false
  # Runs `fun` with `hex_trace_id` as the trace id handed to the SDK.
  @spec with_trace_id(String.t(), (-> result)) :: result when result: term()
  def with_trace_id(hex_trace_id, fun) do
    Process.put(@trace_id_key, String.to_integer(hex_trace_id, 16))

    try do
      fun.()
    after
      Process.delete(@trace_id_key)
    end
  end

  @doc false
  # Whether `tracer` (from `:opentelemetry.get_application_tracer/1`) mints ids
  # with this module. Matches the SDK's internal `#tracer{}` record; any other
  # shape (noop tracer, changed SDK layout) reads as not configured.
  @spec configured?(term()) :: boolean()
  def configured?({_module, {:tracer, _mod, _on_start, _on_end, _sampler, __MODULE__, _scope}}),
    do: true

  def configured?(_tracer), do: false
end
