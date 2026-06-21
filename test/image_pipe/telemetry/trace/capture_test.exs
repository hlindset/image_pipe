defmodule ImagePipe.Telemetry.Trace.CaptureTest do
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

  defp emit_nested do
    Telemetry.span([], [:request], %{}, fn ->
      Telemetry.span([], [:transform, :execute], %{operation_count: 1}, fn ->
        {:ok, %{result: :ok}}
      end)

      {:ok, %{result: :ok, status: 200}}
    end)
  end

  test "captures a nested tree with one trace_id and correct parentage" do
    emit_nested()

    assert_receive {:span, %Span{name: "image_pipe.transform.execute"} = child}
    assert_receive {:span, %Span{name: "image_pipe.request"} = root}

    assert root.parent_span_id == nil
    assert child.parent_span_id == root.span_id
    assert child.trace_id == root.trace_id
    assert root.status == :ok
    assert is_integer(child.duration_native)
    assert is_integer(root.start_time)
    assert is_integer(root.end_time)
    assert root.end_time >= root.start_time
  end

  test "maps an error result to :error status" do
    Telemetry.span([], [:request], %{}, fn -> {:ok, %{result: :processing_error}} end)
    assert_receive {:span, %Span{name: "image_pipe.request", status: :error}}
  end

  test "captures an exception as :error with a folded exception event" do
    assert_raise RuntimeError, fn ->
      Telemetry.span([], [:request], %{}, fn -> raise "boom" end)
    end

    assert_receive {:span, %Span{name: "image_pipe.request", status: :error} = s}
    assert Enum.any?(s.events, &(&1.name == "exception"))
  end

  test "marks the trace root with root: true and children with root: false" do
    emit_nested()

    assert_receive {:span, %Span{name: "image_pipe.transform.execute"} = child}
    assert_receive {:span, %Span{name: "image_pipe.request"} = root}

    assert root.root
    refute child.root
  end

  test "captures the encode-search span with its product-neutral start attributes" do
    Telemetry.span(
      [],
      [:encode, :search],
      %{objective: :ssim2, min_quality: 50, max_quality: 90, target: 90.0, max_bytes: 200_000},
      fn -> {:ok, %{result: :ok}} end
    )

    assert_receive {:span, %Span{name: "image_pipe.encode.search"} = span}
    assert span.status == :ok
    assert span.attributes[:objective] == :ssim2
    assert span.attributes[:max_bytes] == 200_000
    assert span.attributes[:target] == 90.0
  end

  test "folds the encode-search probe one-shot onto the current span with its numbers" do
    Telemetry.span([], [:encode, :search], %{objective: :ssim2}, fn ->
      Telemetry.execute(
        [],
        [:encode, :search, :probe],
        %{},
        %{quality: 62, bytes: 12_345, index: 1, score: 90.42}
      )

      {:ok, %{result: :ok}}
    end)

    assert_receive {:span, %Span{name: "image_pipe.encode.search"} = span}
    probe = Enum.find(span.events, &(&1.name == "image_pipe.encode.search.probe"))
    assert probe
    assert probe.attributes[:quality] == 62
    assert probe.attributes[:bytes] == 12_345
    assert probe.attributes[:index] == 1
    assert probe.attributes[:score] == 90.42
  end

  test "captures the render span with its renderer attribute" do
    Telemetry.span([], [:render], %{renderer: ImagePipe.Telemetry.Trace.CaptureTest}, fn ->
      {:ok, %{result: :ok, content_type: "application/json"}}
    end)

    assert_receive {:span, %Span{name: "image_pipe.render"} = span}
    assert span.status == :ok
    assert span.attributes[:renderer] == ImagePipe.Telemetry.Trace.CaptureTest
  end

  test "captures the input color management span" do
    Telemetry.span([], [:transform, :input_color_management], %{}, fn ->
      {:ok, %{result: :ok, working_space: :VIPS_INTERPRETATION_sRGB}}
    end)

    assert_receive {:span, %Span{name: "image_pipe.transform.input_color_management"} = span}
    assert span.status == :ok
  end

  test "an inbound-continued root keeps root: true despite a non-nil parent" do
    Inbound.put(%Context{
      trace_id: "0123456789abcdef0123456789abcdef",
      span_id: "fedcba9876543210",
      trace_flags: 1
    })

    Telemetry.span([], [:request], %{}, fn -> {:ok, %{result: :ok}} end)

    assert_receive {:span, %Span{name: "image_pipe.request"} = root}
    assert root.root
    assert root.parent_span_id == "fedcba9876543210"
  end
end
