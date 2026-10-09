defmodule ImagePipe.Telemetry.Trace.ReqStep do
  # A Req step that traces a source's outbound HTTP request as an
  # `image_pipe.http.client` span under the current context, and sends the
  # span's W3C `traceparent` header to the origin. Only `traceparent`, not
  # the host's configured propagators: origins are often outside the host's
  # systems, and the default propagators would also send `baggage`.
  #
  # The span goes in the request's `finch_private`, where
  # `ImagePipe.Telemetry.Trace.FinchHandler` finds it to parent the Finch
  # phase spans.
  #
  # With no tracer attached, the step passes the request through untouched:
  # no header and no span. Attaching the step at the build site is safe.
  #
  # The source streams the body with `into: :self`, so the step returns when
  # the status and headers arrive. The span covers connecting and the time to
  # the first byte, not the body download.
  @moduledoc false

  @compile {:no_warn_undefined,
            [
              :otel_ctx,
              :otel_span,
              :otel_tracer,
              :otel_propagator_text_map,
              :otel_propagator_trace_context
            ]}

  alias ImagePipe.Telemetry.Trace
  alias ImagePipe.Telemetry.Trace.Handler

  # Shared with FinchHandler, which reads the client span from here.
  @priv :image_pipe_trace

  @spec attach(Req.Request.t()) :: Req.Request.t()
  def attach(%Req.Request{} = req) do
    Req.Request.append_request_steps(req, image_pipe_trace: &trace/5)
  end

  defp trace(req, acc, fun, state, next) do
    if Trace.attached?(),
      do: traced(req, acc, fun, state, next),
      else: next.(req, acc, fun, state)
  end

  defp traced(req, acc, fun, state, next) do
    {req, span_ctx} = start(req)
    result = next.(req, acc, fun, state)
    finish(span_ctx, result)
    result
  end

  defp start(req) do
    ctx = :otel_ctx.get_current()

    span_ctx =
      :otel_tracer.start_span(ctx, Handler.tracer(), "image_pipe.http.client", %{kind: :client})

    # The trace-context propagator also writes `tracestate` when the parent
    # has one, so keep `traceparent` alone.
    [traceparent] =
      for {"traceparent", value} <-
            ctx
            |> :otel_tracer.set_current_span(span_ctx)
            |> :otel_propagator_text_map.inject_from(:otel_propagator_trace_context, []),
          do: value

    req =
      req
      |> Req.Request.put_header("traceparent", traceparent)
      |> Req.merge(finch_private: %{@priv => span_ctx})

    {req, span_ctx}
  rescue
    # A tracer must never crash the request path; send the request untraced.
    _ -> {req, nil}
  end

  defp finish(nil, _result), do: :ok

  defp finish(span_ctx, result) do
    case result do
      {outcome, %Req.Response{status: status}, _acc, _state} when outcome in [:ok, :halt] ->
        :otel_span.set_attribute(span_ctx, :"http.status_code", status)

      {{:error, exception}, _response, _acc, _state} ->
        :otel_span.set_attribute(span_ctx, :"error.type", error_type(exception))
        :otel_span.set_status(span_ctx, :error, "")

      _other ->
        :ok
    end

    :otel_span.end_span(span_ctx)
  rescue
    _ -> :ok
  end

  defp error_type(%{__struct__: mod}) when is_atom(mod), do: inspect(mod)
  defp error_type(_), do: "unknown"
end
