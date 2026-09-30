defmodule ImagePipe.Telemetry.Trace.LogExporterTest do
  use ExUnit.Case, async: false
  import ExUnit.CaptureLog
  alias ImagePipe.Telemetry.Trace.{LogExporter, Span}

  test "logs one flat line with ids, name, duration, status" do
    span = %Span{
      trace_id: "t",
      span_id: "s",
      parent_span_id: "p",
      name: "image_pipe.request",
      start_time: 0,
      duration_native: 1234,
      status: :ok
    }

    log = capture_log(fn -> assert LogExporter.export(span) == :ok end)
    assert log =~ "image_pipe.request"
    assert log =~ "trace=t"
    assert log =~ "span=s"
    assert log =~ "parent=p"
    assert log =~ "dur=1234"
    assert log =~ "status=ok"
    # one flat line per span (no tree buffering)
    assert log |> String.split("\n", trim: true) |> length() == 1
  end

  test "renders missing parent/duration/status as dashes/unset" do
    span = %Span{trace_id: "t", span_id: "s", name: "image_pipe.request", start_time: 0}

    log = capture_log(fn -> assert LogExporter.export(span) == :ok end)
    assert log =~ "parent=-"
    assert log =~ "dur=-"
    assert log =~ "status=unset"
  end
end
