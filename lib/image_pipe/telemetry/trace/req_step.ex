defmodule ImagePipe.Telemetry.Trace.ReqStep do
  @moduledoc """
  A Req step wrapper that traces an outbound HTTP call as a logical client span, injects a W3C
  `traceparent` header, and stamps `finch_private` so `ImagePipe.Telemetry.Trace.FinchCapture`
  can attach physical wire spans under the same parent. Apply where the source builds
  its Req client (`req |> ReqStep.attach() |> Req.request(...)`).

  ## Active-exporter coupling (not the stack)

  The wrapper reads `ImagePipe.Telemetry.Trace.Stack.context/0` for its parent and carries
  that identity in the request's private state. On completion, it emits through the
  *active exporter* (`ImagePipe.Telemetry.Trace.exporter/0`) directly, preserving the
  captured parent regardless of the active span when the HTTP call returns.

  ## No-op when no tracer is attached

  When `ImagePipe.Telemetry.Trace.exporter/0` is `nil` (no tracer attached), the wrapper emits
  nothing. The header injection and `finch_private` stamp are cheap and harmless, so attaching
  `ReqStep` is safe to do unconditionally at the build site — a source fetch behaves identically
  whether or not a tracer is attached.

  ## `into: :self` timing caveat

  The source streams the body with `into: :self`, so the wrapper returns (and stops this span)
  at **status + headers received**, not when the body finishes downloading. The
  logical client span's duration therefore covers connect + TTFB, not the full transfer. The
  captured status is correct.
  """
  alias ImagePipe.Telemetry.Trace
  alias ImagePipe.Telemetry.Trace.{Context, Id, Span, Stack, W3C}

  # Finch-private key: shared contract with FinchCapture, which reads this atom from
  # request.private to parent wire spans under the logical client span we stamp here.
  @priv :image_pipe_trace

  @spec attach(Req.Request.t()) :: Req.Request.t()
  def attach(%Req.Request{} = req) do
    Req.Request.append_request_steps(req, image_pipe_trace: &trace/5)
  end

  defp trace(req, acc, fun, state, next) do
    req = start(req)
    result = next.(req, acc, fun, state)
    finish(req, result)
    result
  end

  defp start(%Req.Request{} = req) do
    span_id = Id.span_id()
    parent = Stack.context()

    {trace_id, flags} =
      case parent do
        %Context{trace_id: trace_id, trace_flags: flags} -> {trace_id, flags}
        # No parent: mint a fresh trace, default sampled (flags=1).
        nil -> {Id.trace_id(), 1}
      end

    req
    |> Req.Request.put_header("traceparent", W3C.encode(trace_id, span_id, flags))
    |> Req.Request.put_private(@priv, {trace_id, span_id, System.system_time(), parent, flags})
    |> Req.merge(finch_private: %{@priv => {trace_id, span_id, flags}})
  end

  defp finish(req, {outcome, %Req.Response{status: status}, _acc, _state})
       when outcome in [:ok, :halt] do
    emit(req, %{"http.status_code": status}, :ok)
  end

  defp finish(req, {{:error, exception}, _resp, _acc, _state}) do
    emit(req, %{"error.type": error_type(exception)}, :error)
  end

  defp error_type(%{__struct__: mod}) when is_atom(mod), do: inspect(mod)
  defp error_type(_), do: "unknown"

  defp emit(%Req.Request{} = req, attributes, status) do
    case {Trace.exporter(), Req.Request.get_private(req, @priv)} do
      {nil, _private} ->
        :ok

      {_exporter, nil} ->
        :ok

      {exporter, {trace_id, span_id, start_time, parent, flags}} ->
        exporter.export(%Span{
          trace_id: trace_id,
          span_id: span_id,
          parent_span_id: parent && parent.span_id,
          name: "image_pipe.http.client",
          kind: :client,
          start_time: start_time,
          end_time: System.system_time(),
          trace_flags: flags,
          status: status,
          attributes: attributes,
          pid: self(),
          node: node()
        })

        :ok
    end
  rescue
    # A tracer must never crash the request path; drop the span on any exporter error.
    _ -> :ok
  end
end
