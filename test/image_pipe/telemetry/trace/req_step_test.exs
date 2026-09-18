defmodule ImagePipe.Telemetry.Trace.RaisingExporter do
  @moduledoc false
  @behaviour ImagePipe.Telemetry.Trace.Exporter

  @impl true
  def export(_span), do: raise("boom")
end

defmodule ImagePipe.Telemetry.Trace.ReqStepTest do
  use ExUnit.Case, async: false
  alias ImagePipe.Telemetry
  alias ImagePipe.Telemetry.Trace
  alias ImagePipe.Telemetry.Trace.{Context, RaisingExporter, ReqStep, Span, Stack, TestExporter}
  alias ImagePipe.Telemetry.Trace.TestReqAdapter

  defp stub_request(respond) do
    Req.new(adapter: TestReqAdapter)
    |> Req.Request.put_private(:test_response, respond)
  end

  setup do
    TestExporter.set_receiver(self())
    :ok = TestExporter.attach(self())

    on_exit(fn ->
      Telemetry.detach_tracer()
      TestExporter.clear_receiver()
    end)

    :ok
  end

  test "injects traceparent and emits a logical client span with status" do
    # Open a parent span so the client span has a trace to attach to.
    Telemetry.span([], [:request], %{}, fn ->
      req =
        stub_request(fn req ->
          assert [tp] = Req.Request.get_header(req, "traceparent")
          # Sampled (default mint) parent → outbound flags -01.
          assert tp =~ ~r/\A00-[0-9a-f]{32}-[0-9a-f]{16}-01\z/
          {req, Req.Response.new(status: 200, body: "ok")}
        end)
        |> ReqStep.attach()

      {:ok, _} = Req.request(req)
      {:ok, %{result: :ok}}
    end)

    assert_receive {:span, %Span{name: "image_pipe.http.client", kind: :client} = s}
    assert s.attributes[:"http.status_code"] == 200
  end

  test "inbound unsampled flags=0 reaches the outbound traceparent and exported span" do
    # Simulate a producer that adopted an unsampled remote request context.
    Stack.adopt(%Context{
      trace_id: "0af7651916cd43dd8448eb211c80319c",
      span_id: "b7ad6b7169203331",
      trace_flags: 0
    })

    on_exit(fn -> Stack.clear() end)

    req =
      stub_request(fn req ->
        assert [tp] = Req.Request.get_header(req, "traceparent")
        # Unsampled parent → outbound flags -00.
        assert tp =~ ~r/\A00-[0-9a-f]{32}-[0-9a-f]{16}-00\z/
        {req, Req.Response.new(status: 200, body: "ok")}
      end)
      |> ReqStep.attach()

    {:ok, _} = Req.request(req)

    assert_receive {:span, %Span{name: "image_pipe.http.client", kind: :client} = s}
    assert s.trace_flags == 0
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

  test "is a harmless no-op when no tracer is attached" do
    Telemetry.detach_tracer()

    Telemetry.span([], [:request], %{}, fn ->
      req =
        stub_request(fn req ->
          # traceparent is still injected (cheap, header only); span just is not emitted.
          assert [_tp] = Req.Request.get_header(req, "traceparent")
          {req, Req.Response.new(status: 200, body: "ok")}
        end)
        |> ReqStep.attach()

      {:ok, %Req.Response{status: 200}} = Req.request(req)
      {:ok, %{result: :ok}}
    end)

    refute_receive {:span, %Span{name: "image_pipe.http.client"}}
  end

  test "a raising exporter does not break the request" do
    Telemetry.detach_tracer()
    Trace.set_exporter(RaisingExporter)

    on_exit(fn ->
      Trace.set_exporter(nil)
    end)

    req =
      stub_request(fn req ->
        {req, Req.Response.new(status: 200, body: "ok")}
      end)
      |> ReqStep.attach()

    assert {:ok, %Req.Response{status: 200}} = Req.request(req)
  end
end
