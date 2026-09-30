defmodule ImagePipe.Telemetry.Trace.OpenTelemetryExporterTest do
  use ExUnit.Case, async: false

  require Record
  # Read the #span{} the SDK delivers (test-only — reading, not constructing).
  Record.defrecordp(
    :otel_span,
    :span,
    Record.extract(:span, from_lib: "opentelemetry/include/otel_span.hrl")
  )

  # #event{} is defined in otel_span.hrl (field order: system_time_native, name, attributes).
  Record.defrecordp(
    :otel_event,
    :event,
    Record.extract(:event, from_lib: "opentelemetry/include/otel_span.hrl")
  )

  # #events{} is the SDK wrapper type (otel_events:t/0). Use the public :otel_events.list/1
  # to unwrap it — avoids depending on the internal .erl record layout.
  defp events_list(events_wrapper), do: :otel_events.list(events_wrapper)
  defp event_name(event), do: otel_event(event, :name)
  defp event_system_time_native(event), do: otel_event(event, :system_time_native)
  defp event_attributes(event), do: otel_event(event, :attributes)

  alias ImagePipe.Telemetry.Trace.{OpenTelemetryExporter, OtelReplay, Span}

  setup do
    :otel_simple_processor.set_exporter(:otel_exporter_pid, self())
    OtelReplay.reset()
    :ok
  end

  test "replays a span carrying OUR trace_id, with an OTel-minted (different) span_id" do
    span = %Span{
      trace_id: "0123456789abcdef0123456789abcdef",
      span_id: "89abcdef01234567",
      parent_span_id: "fedcba9876543210",
      name: "image_pipe.request",
      kind: :server,
      start_time: System.system_time(),
      duration_native: 1_000,
      status: :ok,
      trace_flags: 1,
      root: true
    }

    assert :ok = OpenTelemetryExporter.export(span)

    assert_receive {:span, rec}, 1_000
    assert otel_span(rec, :trace_id) == 0x0123456789ABCDEF0123456789ABCDEF
    minted = otel_span(rec, :span_id)
    assert is_integer(minted) and minted != 0
    assert minted != 0x89ABCDEF01234567
    assert otel_span(rec, :parent_span_id) == 0xFEDCBA9876543210
    assert otel_span(rec, :name) == "image_pipe.request"
    assert otel_span(rec, :kind) == :server
  end

  test "duration survives: exported end - start == duration_native" do
    span =
      base_span(%{name: "image_pipe.transform.execute", kind: :internal, duration_native: 5_000})

    assert :ok = OpenTelemetryExporter.export(span)
    assert_receive {:span, rec}, 1_000
    assert otel_span(rec, :end_time) - otel_span(rec, :start_time) == 5_000
  end

  test "maps error status with its message" do
    span =
      base_span(%{
        name: "image_pipe.source.fetch",
        kind: :client,
        status: :error,
        status_message: "boom"
      })

    assert :ok = OpenTelemetryExporter.export(span)
    assert_receive {:span, rec}, 1_000
    assert otel_span(rec, :status) == {:status, :error, "boom"}
  end

  test "coerces non-primitive attributes, maps primitive lists to string arrays, adds pid/node, drops nils" do
    span =
      base_span(%{
        name: "image_pipe.transform.operation",
        kind: :internal,
        pid: self(),
        node: node(),
        attributes: %{
          width: 100,
          result: :ok,
          params: 1..3,
          dims: {100, 80},
          operations: ["scale", "crop"],
          classes: [:cat, :dog],
          dropme: nil
        }
      })

    assert :ok = OpenTelemetryExporter.export(span)
    assert_receive {:span, rec}, 1_000

    attrs = elem(otel_span(rec, :attributes), 4)
    assert attrs[:width] == 100
    assert attrs[:result] == "ok"
    assert attrs[:params] == inspect(1..3)
    # :dims is a tuple (non-primitive), coerced through the same generic
    # fallback as :params.
    assert attrs[:dims] == inspect({100, 80})
    assert attrs[:operations] == ["scale", "crop"]
    assert attrs[:classes] == ["cat", "dog"]
    refute Map.has_key?(attrs, :dropme)
    assert attrs["image_pipe.pid"] == inspect(self())
    assert attrs["image_pipe.node"] == Atom.to_string(node())
  end

  test "span exports with the mandatory -01 sampled flag (regression guard)" do
    span = base_span(%{name: "image_pipe.request", kind: :server})
    assert :ok = OpenTelemetryExporter.export(span)
    assert_receive {:span, _rec}, 1_000
  end

  test "a oneshot event lands inside its span's window (frame guard)" do
    # Build a span whose start/end window is known in monotonic units, then place
    # the event at native_start + 1 (guaranteed inside). The exporter converts
    # start_time (system_time) to native_start via time_offset, so we derive the
    # same offset here to produce a coherent event timestamp.
    offset = :erlang.time_offset()
    start_sys = System.system_time()
    native_start = start_sys - offset
    duration = 1_000_000
    event_mono = native_start + div(duration, 2)

    span =
      base_span(%{
        name: "image_pipe.cache.lookup",
        kind: :internal,
        start_time: start_sys,
        duration_native: duration,
        events: [%{name: "image_pipe.cache.stage", time: event_mono, attributes: %{cache: :hit}}]
      })

    assert :ok = OpenTelemetryExporter.export(span)
    assert_receive {:span, rec}, 1_000

    [event] = otel_span(rec, :events) |> events_list()
    # Anti-tautology self-check: prove we read the right #event{} fields.
    assert event_name(event) == "image_pipe.cache.stage"
    ev_ts = event_system_time_native(event)
    assert ev_ts >= otel_span(rec, :start_time)
    assert ev_ts <= otel_span(rec, :end_time)
  end

  test "exception event maps to OTel exception semantics and uses native_end (no :time)" do
    span =
      base_span(%{
        name: "image_pipe.request",
        kind: :server,
        duration_native: 2_000,
        status: :error,
        status_message: "boom",
        events: [
          %{
            name: "exception",
            attributes: %{kind: :error, reason: inspect(%RuntimeError{message: "boom"})}
          }
        ]
      })

    assert :ok = OpenTelemetryExporter.export(span)
    assert_receive {:span, rec}, 1_000

    [event] = otel_span(rec, :events) |> events_list()
    assert event_name(event) == "exception"
    attrs = elem(event_attributes(event), 4)
    assert attrs["exception.type"] == "error"
    assert attrs["exception.message"] =~ "boom"
    assert event_system_time_native(event) == otel_span(rec, :end_time)
  end

  test "a success span leaves OTel status UNSET (no explicit OK)" do
    span = base_span(%{name: "image_pipe.request", status: :ok})
    assert :ok = OpenTelemetryExporter.export(span)
    assert_receive {:span, rec}, 1_000
    # set_status is not called for success → OTel default unset. The SDK
    # record default for the :status field is :undefined (not {:status, :unset, _}).
    refute match?({:status, :error, _}, otel_span(rec, :status))
    assert otel_span(rec, :status) == :undefined
  end

  test "export/1 is crash-safe and emits nothing when OTel can't deliver" do
    :otel_simple_processor.set_exporter(:none, [])
    span = base_span(%{name: "image_pipe.request"})
    assert :ok = OpenTelemetryExporter.export(span)
    refute_receive {:span, _}, 100
  end

  defp base_span(overrides) do
    Map.merge(
      %Span{
        trace_id: "0123456789abcdef0123456789abcdef",
        span_id: "89abcdef01234567",
        name: "image_pipe.request",
        start_time: System.system_time(),
        duration_native: 1,
        status: :ok,
        trace_flags: 1,
        root: true
      },
      overrides
    )
  end
end
