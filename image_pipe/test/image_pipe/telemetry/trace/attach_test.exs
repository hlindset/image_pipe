defmodule ImagePipe.Telemetry.Trace.AttachTest do
  use ExUnit.Case, async: false
  alias ImagePipe.Telemetry
  alias ImagePipe.Test.Trace.TestExporter

  setup do
    on_exit(fn -> Telemetry.detach_tracer() end)
    :ok
  end

  test "attach_tracer succeeds without options" do
    assert Telemetry.attach_tracer() == :ok
  end

  test "reattaching applies disabled and reenabled Finch spans" do
    prefix = [:attach_test, :finch_toggle]
    TestExporter.attach(self(), prefix: prefix)
    parent = TestExporter.open_span()

    metadata = %{
      request: %{private: %{image_pipe_trace: :otel_tracer.current_span_ctx()}},
      result: {:ok, %{status: 200}}
    }

    measurements = %{duration: 10}
    trace_id = parent.trace_id

    :telemetry.execute([:finch, :request, :stop], measurements, metadata)
    assert_receive {:span, %{name: "finch.request", trace_id: ^trace_id}}

    TestExporter.attach(self(), prefix: prefix, finch_spans: false)
    :telemetry.execute([:finch, :request, :stop], measurements, metadata)
    refute_receive {:span, %{name: "finch.request", trace_id: ^trace_id}}, 100

    TestExporter.attach(self(), prefix: prefix, finch_spans: true)
    :telemetry.execute([:finch, :request, :stop], measurements, metadata)
    assert_receive {:span, %{name: "finch.request", trace_id: ^trace_id}}
  end

  test "attach_tracer raises on unknown option" do
    assert_raise ArgumentError, fn -> Telemetry.attach_tracer(bogus: 1) end
  end

  test "attach_tracer raises on the removed exporter option" do
    assert_raise ArgumentError, fn -> Telemetry.attach_tracer(exporter: SomeExporter) end
  end

  test "attach_tracer raises ArgumentError on a non-list argument" do
    assert_raise ArgumentError, fn -> Telemetry.attach_tracer(:not_a_list) end
  end
end
