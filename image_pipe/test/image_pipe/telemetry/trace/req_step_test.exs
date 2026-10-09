defmodule ImagePipe.Telemetry.Trace.ReqStepTest do
  use ExUnit.Case, async: false
  alias ImagePipe.Telemetry
  alias ImagePipe.Telemetry.Trace.{ReqStep, TestReqAdapter}
  alias ImagePipe.Test.Trace.{Span, TestExporter}

  defp stub_request(respond) do
    Req.new(adapter: TestReqAdapter)
    |> Req.Request.put_private(:test_response, respond)
  end

  setup do
    TestExporter.attach(self())
  end

  test "sends the client span's traceparent and records the span under the current one" do
    test_pid = self()

    Telemetry.span([], [:request], %{}, fn ->
      req =
        stub_request(fn req ->
          send(test_pid, {:traceparent, Req.Request.get_header(req, "traceparent")})
          {req, Req.Response.new(status: 200, body: "ok")}
        end)
        |> ReqStep.attach()

      {:ok, _} = Req.request(req)
      {:ok, %{result: :ok}}
    end)

    assert_receive {:span, %Span{name: "image_pipe.http.client", kind: :client} = s}
    assert_receive {:span, %Span{name: "image_pipe.request"} = request}
    assert_received {:traceparent, [traceparent]}
    assert traceparent == "00-#{s.trace_id}-#{s.span_id}-01"
    assert s.parent_span_id == request.span_id
    assert s.attributes[:"http.status_code"] == 200
    assert s.duration_native > 0
  end

  test "sends traceparent only, not the parent's tracestate or the context's baggage" do
    :otel_propagator_text_map.extract_to(
      :otel_ctx.get_current(),
      :otel_propagator_trace_context,
      [
        {"traceparent", "00-0af7651916cd43dd8448eb211c80319c-b7ad6b7169203331-01"},
        {"tracestate", "vendor=private"}
      ]
    )
    |> :otel_ctx.attach()

    :otel_baggage.set("tenant", "private-tenant")

    req =
      stub_request(fn req ->
        assert [_traceparent] = Req.Request.get_header(req, "traceparent")
        assert Req.Request.get_header(req, "baggage") == []
        assert Req.Request.get_header(req, "tracestate") == []
        {req, Req.Response.new(status: 200, body: "ok")}
      end)
      |> ReqStep.attach()

    assert {:ok, %Req.Response{status: 200}} = Req.request(req)
  end

  test "an unsampled parent sends flags=00 and records no client span" do
    :otel_propagator_text_map.extract_to(
      :otel_ctx.get_current(),
      :otel_propagator_trace_context,
      [{"traceparent", "00-0af7651916cd43dd8448eb211c80319c-b7ad6b7169203331-00"}]
    )
    |> :otel_ctx.attach()

    req =
      stub_request(fn req ->
        assert [tp] = Req.Request.get_header(req, "traceparent")
        assert tp =~ ~r/\A00-0af7651916cd43dd8448eb211c80319c-[0-9a-f]{16}-00\z/
        {req, Req.Response.new(status: 200, body: "ok")}
      end)
      |> ReqStep.attach()

    {:ok, _} = Req.request(req)

    refute_receive {:span, %Span{name: "image_pipe.http.client"}}, 100
  end

  test "emits a client span with status :error on transport error" do
    Telemetry.span([], [:request], %{}, fn ->
      req =
        stub_request(fn req ->
          {req, %Mint.TransportError{reason: :timeout}}
        end)
        |> ReqStep.attach()

      {:error, _exception} = Req.request(req)
      {:ok, %{result: :ok}}
    end)

    assert_receive {:span, %Span{name: "image_pipe.http.client", kind: :client} = s}
    assert s.status == :error
    assert is_binary(s.attributes[:"error.type"])
  end

  test "error span carries the exception type, never the inspected message" do
    Telemetry.span([], [:request], %{}, fn ->
      req =
        stub_request(fn req ->
          # An exception whose message embeds a fake signed source URL.
          {req, %RuntimeError{message: "boom https://secret.example/x?sig=LEAK"}}
        end)
        |> ReqStep.attach()

      {:error, _exception} = Req.request(req)
      {:ok, %{result: :ok}}
    end)

    assert_receive {:span, %Span{name: "image_pipe.http.client", kind: :client} = s}
    assert s.attributes[:"error.type"] == "RuntimeError"
    refute Map.has_key?(s.attributes, :"http.error")
    refute inspect(s.attributes) =~ "LEAK"
  end

  test "sends no traceparent and emits no span when no tracer is attached" do
    Telemetry.detach_tracer()

    Telemetry.span([], [:request], %{}, fn ->
      req =
        stub_request(fn req ->
          assert Req.Request.get_header(req, "traceparent") == []
          {req, Req.Response.new(status: 200, body: "ok")}
        end)
        |> ReqStep.attach()

      {:ok, %Req.Response{status: 200}} = Req.request(req)
      {:ok, %{result: :ok}}
    end)

    refute_receive {:span, %Span{name: "image_pipe.http.client"}}, 100
  end

  test "streaming preserves the consumer accumulator and traces an early halt" do
    req =
      stub_request(fn req ->
        {req, Req.Response.new(status: 200, body: "chunk")}
      end)
      |> ReqStep.attach()

    assert {:ok, %Req.Response{status: 200}, ["chunk"]} =
             Req.stream(req, [], fn chunk, _response, chunks ->
               {:halt, [chunk | chunks]}
             end)

    assert_receive {:span, %Span{name: "image_pipe.http.client", status: :unset} = span}
    assert span.attributes[:"http.status_code"] == 200
    refute_received {:span, %Span{name: "image_pipe.http.client"}}
  end
end
