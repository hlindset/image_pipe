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
      %{
        objective: :ssimulacra2,
        min_quality: 50,
        max_quality: 90,
        target: 90.0,
        max_bytes: 200_000
      },
      fn -> {:ok, %{result: :ok}} end
    )

    assert_receive {:span, %Span{name: "image_pipe.encode.search"} = span}
    assert span.status == :ok
    assert span.attributes[:objective] == :ssimulacra2
    assert span.attributes[:max_bytes] == 200_000
    assert span.attributes[:target] == 90.0
  end

  test "captures the content-class classify span with its allowlisted attributes" do
    Telemetry.span(
      [],
      [:encode, :classify],
      %{},
      fn ->
        {:ok,
         %{
           result: :ok,
           content_class: :graphic,
           applied_offset: 6.0,
           palette_ent: 0.34,
           nat_var: 0.11
         }}
      end
    )

    assert_receive {:span, %Span{name: "image_pipe.encode.classify"} = span}
    assert span.status == :ok
    assert span.attributes[:content_class] == :graphic
    assert span.attributes[:applied_offset] == 6.0
    assert span.attributes[:palette_ent] == 0.34
    assert span.attributes[:nat_var] == 0.11
  end

  test "captures the encode-search probe as a span nested under the search, with its phase/numbers" do
    Telemetry.span([], [:encode, :search], %{objective: :ssimulacra2}, fn ->
      Telemetry.span(
        [],
        [:encode, :search, :probe],
        %{quality: 62, phase: :confirm},
        fn ->
          {:ok, %{bytes: 12_345, index: 1, score: 90.42, full_frame_score: 90.42, passed?: true}}
        end
      )

      {:ok, %{result: :ok}}
    end)

    assert_receive {:span, %Span{name: "image_pipe.encode.search.probe"} = probe}
    assert_receive {:span, %Span{name: "image_pipe.encode.search"} = search}

    # the probe is a real child span of the search span, not a folded annotation
    assert probe.parent_span_id == search.span_id
    assert probe.trace_id == search.trace_id
    assert is_integer(probe.duration_native)

    assert probe.attributes[:phase] == :confirm
    assert probe.attributes[:quality] == 62
    assert probe.attributes[:bytes] == 12_345
    assert probe.attributes[:index] == 1
    assert probe.attributes[:score] == 90.42
    assert probe.attributes[:full_frame_score] == 90.42
    assert probe.attributes[:passed?] == true
  end

  test "folds the delivered-probe chosen marker onto the enclosing search span" do
    Telemetry.span([], [:encode, :search], %{objective: :ssimulacra2}, fn ->
      Telemetry.execute(
        [],
        [:encode, :search, :probe, :chosen],
        %{},
        %{quality: 64, bytes: 12_345, phase: :objective, index: 3, score: 90.42, scorer: :full}
      )

      {:ok, %{result: :ok}}
    end)

    assert_receive {:span, %Span{name: "image_pipe.encode.search"} = search}

    # the marker is a one-shot annotation on the search span, not a child span.
    refute_received {:span, %Span{name: "image_pipe.encode.search.probe.chosen"}}

    chosen = Enum.find(search.events, &(&1.name == "image_pipe.encode.search.probe.chosen"))
    assert chosen
    assert chosen.attributes[:quality] == 64
    assert chosen.attributes[:bytes] == 12_345
    assert chosen.attributes[:phase] == :objective
    assert chosen.attributes[:index] == 3
    assert chosen.attributes[:score] == 90.42
    assert chosen.attributes[:scorer] == :full
  end

  test "folds the debug collect error marker onto the enclosing span" do
    Telemetry.span([], [:cache, :lookup], %{}, fn ->
      Telemetry.execute([], [:debug, :collect, :error], %{}, %{error: :decode_failed})
      {:ok, %{result: :ok}}
    end)

    assert_receive {:span, %Span{name: "image_pipe.cache.lookup"} = span}

    refute_received {:span, %Span{name: "image_pipe.debug.collect.error"}}

    event = Enum.find(span.events, &(&1.name == "image_pipe.debug.collect.error"))
    assert event
    assert event.attributes[:error] == :decode_failed
  end

  test "nests the ssimulacra2 probe cost legs (encode/decode/metric) under the probe span" do
    Telemetry.span([], [:encode, :search, :probe], %{quality: 62, phase: :objective}, fn ->
      Telemetry.span([], [:encode, :search, :probe, :encode], %{quality: 62}, fn ->
        {:ok, %{result: :ok, bytes: 12_345}}
      end)

      Telemetry.span(
        [],
        [:encode, :search, :probe, :ssimulacra2, :decode],
        %{bytes: 12_345},
        fn ->
          {:ok, %{result: :ok}}
        end
      )

      Telemetry.span(
        [],
        [:encode, :search, :probe, :ssimulacra2, :metric],
        %{tiles_scored: 12},
        fn ->
          {90.42, %{result: :ok, score: 90.42}}
        end
      )

      {:ok, %{bytes: 12_345}}
    end)

    assert_receive {:span, %Span{name: "image_pipe.encode.search.probe.encode"} = enc}
    assert_receive {:span, %Span{name: "image_pipe.encode.search.probe.ssimulacra2.decode"} = dec}
    assert_receive {:span, %Span{name: "image_pipe.encode.search.probe.ssimulacra2.metric"} = met}
    assert_receive {:span, %Span{name: "image_pipe.encode.search.probe"} = probe}

    for leg <- [enc, dec, met] do
      assert leg.parent_span_id == probe.span_id
      assert leg.trace_id == probe.trace_id
    end

    assert met.attributes[:tiles_scored] == 12
  end

  test "captures the butteraugli probe cost legs (per-metric segment)" do
    Telemetry.span([], [:encode, :search, :probe], %{quality: 62, phase: :objective}, fn ->
      Telemetry.span([], [:encode, :search, :probe, :butteraugli, :decode], %{bytes: 9_001}, fn ->
        {:ok, %{result: :ok}}
      end)

      Telemetry.span(
        [],
        [:encode, :search, :probe, :butteraugli, :metric],
        %{tiles_scored: nil},
        fn ->
          {1.2, %{result: :ok, score: 1.2}}
        end
      )

      {:ok, %{bytes: 9_001}}
    end)

    assert_receive {:span, %Span{name: "image_pipe.encode.search.probe.butteraugli.decode"} = dec}
    assert_receive {:span, %Span{name: "image_pipe.encode.search.probe.butteraugli.metric"} = met}
    assert_receive {:span, %Span{name: "image_pipe.encode.search.probe"} = probe}

    for leg <- [dec, met] do
      assert leg.parent_span_id == probe.span_id
      assert leg.trace_id == probe.trace_id
    end

    assert met.attributes[:score] == 1.2
  end

  test "captures the render span with its renderer attribute" do
    Telemetry.span([], [:render], %{renderer: ImagePipe.Telemetry.Trace.CaptureTest}, fn ->
      {:ok, %{result: :ok, content_type: "application/json"}}
    end)

    assert_receive {:span, %Span{name: "image_pipe.render"} = span}
    assert span.status == :ok
    assert span.attributes[:renderer] == ImagePipe.Telemetry.Trace.CaptureTest
    assert span.attributes[:content_type] == "application/json"
  end

  test "merges allowlisted stop-metadata attributes onto the span, preserving start attrs" do
    Telemetry.span(
      [],
      [:encode, :search],
      %{objective: :ssimulacra2, max_bytes: 200_000},
      fn ->
        {:ok,
         %{
           result: :ok,
           chosen_quality: 62,
           chosen_bytes: 12_345,
           final_score: 90.42,
           scorer: :crop,
           outcome: :hit
         }}
      end
    )

    assert_receive {:span, %Span{name: "image_pipe.encode.search"} = span}
    # start attributes preserved
    assert span.attributes[:objective] == :ssimulacra2
    assert span.attributes[:max_bytes] == 200_000
    # stop attributes (the per-result verdict) now captured
    assert span.attributes[:chosen_quality] == 62
    assert span.attributes[:chosen_bytes] == 12_345
    assert span.attributes[:final_score] == 90.42
    assert span.attributes[:scorer] == :crop
    assert span.attributes[:outcome] == :hit
  end

  test "captures HTTP status and the classified error tag from stop metadata" do
    Telemetry.span([], [:request], %{}, fn ->
      {:ok, %{result: :source_error, status: 422, error: :body_too_large}}
    end)

    assert_receive {:span, %Span{name: "image_pipe.request"} = span}
    assert span.status == :error
    assert span.attributes[:status] == 422
    assert span.attributes[:error] == :body_too_large
  end

  test "drops non-allowlisted stop-metadata keys" do
    Telemetry.span([], [:request], %{}, fn ->
      {:ok, %{result: :ok, source_url: "https://secret.example/signed?sig=abc"}}
    end)

    assert_receive {:span, %Span{name: "image_pipe.request"} = span}
    refute Map.has_key?(span.attributes, :source_url)
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
