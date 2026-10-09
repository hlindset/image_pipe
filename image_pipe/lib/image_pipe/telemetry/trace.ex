defmodule ImagePipe.Telemetry.Trace do
  @moduledoc false
  # State shared by the tracer's handlers and the request path: whether
  # `ImagePipe.Telemetry.attach_tracer/1` attached the tracer, and whether an
  # inbound `traceparent` may start the request's trace.

  @compile {:no_warn_undefined,
            [:otel_ctx, :otel_tracer, :otel_propagator_text_map, :otel_propagator_trace_context]}

  @otel_api_loaded Code.ensure_loaded?(:otel_tracer)

  @attached_key {__MODULE__, :attached}
  @extract_key {__MODULE__, :extract_inbound}

  # Raises unless the OpenTelemetry API was available when ImagePipe was compiled.
  @spec ensure_available!() :: :ok
  if @otel_api_loaded do
    def ensure_available!, do: :ok
  else
    def ensure_available! do
      raise ArgumentError,
            "attach_tracer/1 needs the OpenTelemetry API: add :opentelemetry_api " <>
              "(or the :opentelemetry SDK) to your dependencies and recompile :image_pipe"
    end
  end

  @spec set_attached(boolean()) :: :ok
  def set_attached(flag), do: :persistent_term.put(@attached_key, flag)

  @spec attached?() :: boolean()
  def attached?, do: :persistent_term.get(@attached_key, false)

  @spec set_extract_inbound(boolean()) :: :ok
  def set_extract_inbound(flag), do: :persistent_term.put(@extract_key, flag)

  # Runs `fun` under the context of the request's W3C `traceparent` header,
  # when extraction is on and no span is current. A span the host already
  # opened, from its own extraction or not, wins over the header.
  @spec with_inbound(Plug.Conn.t(), (-> result)) :: result when result: term()
  def with_inbound(conn, fun) do
    if :persistent_term.get(@extract_key, false) do
      extract_within(conn.req_headers, fun)
    else
      fun.()
    end
  end

  if @otel_api_loaded do
    defp extract_within(headers, fun) do
      own = :otel_ctx.get_current()

      if :otel_tracer.current_span_ctx(own) == :undefined do
        traceparent = for {"traceparent", _value} = header <- headers, do: header

        own
        |> :otel_propagator_text_map.extract_to(:otel_propagator_trace_context, traceparent)
        |> :otel_ctx.attach()

        try do
          fun.()
        after
          :otel_ctx.attach(own)
        end
      else
        fun.()
      end
    end
  else
    defp extract_within(_headers, fun), do: fun.()
  end
end
