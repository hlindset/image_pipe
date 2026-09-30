defmodule ImagePipe.Telemetry.Trace.InboundTest do
  use ExUnit.Case, async: false
  alias ImagePipe.Telemetry
  alias ImagePipe.Telemetry.Trace.{Context, Inbound, Span, TestExporter}

  setup do
    TestExporter.set_receiver(self())
    :ok = TestExporter.attach(self())

    on_exit(fn ->
      Telemetry.detach_tracer()
      TestExporter.clear_receiver()
    end)

    :ok
  end

  test "root span adopts an inbound context when present" do
    Inbound.put(%Context{
      trace_id: "0af7651916cd43dd8448eb211c80319c",
      span_id: "b7ad6b7169203331",
      trace_flags: 1
    })

    Telemetry.span([], [:request], %{}, fn -> {:ok, %{result: :ok}} end)

    assert_receive {:span, %Span{name: "image_pipe.request"} = root}
    assert root.trace_id == "0af7651916cd43dd8448eb211c80319c"
    assert root.parent_span_id == "b7ad6b7169203331"
  end

  test "root mints fresh when no inbound context" do
    Telemetry.span([], [:request], %{}, fn -> {:ok, %{result: :ok}} end)
    assert_receive {:span, %Span{name: "image_pipe.request"} = root}
    assert root.trace_id =~ ~r/\A[0-9a-f]{32}\z/
    assert root.parent_span_id == nil
  end
end
