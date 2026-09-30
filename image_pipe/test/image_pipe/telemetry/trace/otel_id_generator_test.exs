defmodule ImagePipe.Telemetry.Trace.OtelIdGeneratorTest do
  use ExUnit.Case, async: true

  alias ImagePipe.Telemetry.Trace.{OtelIdGenerator, OtelReplay}

  test "generates random ids unless a trace id is handed over" do
    assert OtelIdGenerator.generate_trace_id() != OtelIdGenerator.generate_trace_id()
    assert OtelIdGenerator.generate_span_id() in 1..(2 ** 64 - 1)

    trace_id =
      OtelIdGenerator.with_trace_id("0123456789abcdef0123456789abcdef", fn ->
        OtelIdGenerator.generate_trace_id()
      end)

    assert trace_id == 0x0123456789ABCDEF0123456789ABCDEF
    assert OtelIdGenerator.generate_trace_id() != trace_id
  end

  test "recognizes the SDK tracer configured with it" do
    # Pins the SDK's internal tracer layout: a changed layout would silently
    # disable true roots.
    assert OtelIdGenerator.configured?(:opentelemetry.get_application_tracer(OtelReplay))
    refute OtelIdGenerator.configured?({:otel_tracer_noop, []})
  end
end
