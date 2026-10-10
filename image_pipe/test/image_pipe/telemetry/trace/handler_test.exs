defmodule ImagePipe.Telemetry.Trace.HandlerTest do
  use ExUnit.Case, async: false
  alias ImagePipe.Cache.OutputWork
  alias ImagePipe.Telemetry
  alias ImagePipe.Test.FakeDetector
  alias ImagePipe.Test.Trace.{Span, TestExporter}
  alias ImagePipe.Transform.Detector.Composite
  alias ImagePipe.Transform.Executor.Step
  alias ImagePipe.Transform.Operation.Resize
  alias ImagePipe.Transform.State

  setup do
    :ok = TestExporter.attach(self())

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

  test "one-shot events retain occurrence times with and without a timestamp measurement" do
    prefix = [__MODULE__, :event_time]
    TestExporter.attach(self(), prefix: prefix)
    opts = [telemetry_prefix: prefix]
    before = System.monotonic_time()

    Telemetry.span(opts, [:request], %{}, fn ->
      Telemetry.execute(opts, [:cache, :coordination], %{monotonic_time: before}, %{
        result: :acquired
      })

      Telemetry.execute(opts, [:cache, :coordination], %{}, %{result: :coalesced})
      {:ok, %{result: :ok}}
    end)

    after_capture = System.monotonic_time()
    assert_received {:span, %Span{events: [captured, measured]}}
    assert measured.time == before
    assert is_integer(captured.time)
    assert captured.time >= before
    assert captured.time <= after_capture
  end

  test "origin not-modified outcome is a successful source span" do
    prefix = [__MODULE__, :origin_revalidation]
    :ok = TestExporter.attach(self(), prefix: prefix)

    Telemetry.span([telemetry_prefix: prefix], [:source, :fetch], %{}, fn ->
      {:unchanged, %{result: :not_modified}}
    end)

    assert_receive {:span,
                    %Span{
                      name: "image_pipe.source.fetch",
                      status: :unset,
                      attributes: %{result: "not_modified"}
                    }}
  end

  test "fetch/decode spans carry the frame count, rejecting limit, and rejected loader" do
    prefix = [__MODULE__, :fetch_decode_frames]
    :ok = TestExporter.attach(self(), prefix: prefix)

    for {metadata, expected} <- [
          {%{result: :ok, source_frames: 3}, %{result: "ok", source_frames: 3}},
          {%{result: :ok, skipped: true, detected_source_format: :gif},
           %{result: "ok", skipped: true, detected_source_format: "gif"}},
          {%{result: :processing_error, error: :input_limit, limit: :frames},
           %{result: "processing_error", error: "input_limit", limit: "frames"}},
          {%{
             result: :processing_error,
             error: :unsupported_source_format,
             detected_source_format: :tiff,
             source_loader: "dcrawload"
           },
           %{
             result: "processing_error",
             error: "unsupported_source_format",
             detected_source_format: "tiff",
             source_loader: "dcrawload"
           }},
          {%{result: :processing_error, error: :page_out_of_range, page: 3, source_frames: 3},
           %{result: "processing_error", error: "page_out_of_range", page: 3, source_frames: 3}}
        ] do
      Telemetry.span([telemetry_prefix: prefix], [:source, :fetch_decode], %{}, fn ->
        {:ok, metadata}
      end)

      assert_receive {:span,
                      %Span{name: "image_pipe.source.fetch_decode", attributes: attributes}}

      assert attributes == expected
    end
  end

  test "composite model failures are error spans without leaking detector reasons" do
    prefix = [__MODULE__, :model_result]
    TestExporter.attach(self(), prefix: prefix)
    composite = [FakeDetector]

    for {response, result, status} <- [
          {{:ok, []}, "ok", :unset},
          {{:error, "private detector reason"}, "error", :error}
        ] do
      FakeDetector.returning(response)

      assert ^response =
               Composite.detect(composite, :image, telemetry_opts: [telemetry_prefix: prefix])

      assert_received {:span,
                       %Span{
                         name: "image_pipe.transform.detect.model",
                         status: ^status,
                         attributes: %{result: ^result, regions: 0} = attributes
                       }}

      refute inspect(attributes) =~ "private detector reason"
    end
  end

  test "processing pool spans retain request parentage and close after timed-out work finishes" do
    prefix = [__MODULE__, :processing]
    :ok = TestExporter.attach(self(), prefix: prefix)

    pool =
      start_supervised!({ImagePipe.ProcessingPool, max_concurrency: 1, processing_timeout: 40})

    config = [telemetry_prefix: prefix]
    owner = self()

    Telemetry.span(config, [:request], %{}, fn ->
      result =
        ImagePipe.ProcessingPool.run(
          pool,
          fn ->
            send(owner, {:processing_worker, self()})

            Telemetry.span(config, [:output, :terminal], %{terminal: :info}, fn ->
              {:ok, %{result: :ok}}
            end)

            receive do
              :finish -> :ok
            end
          end,
          config
        )

      assert result == {:error, {:processing, :timeout}}
      {result, %{result: :processing_error}}
    end)

    assert_receive {:span,
                    %Span{name: "image_pipe.processing.admission", status: :unset} = admission}

    assert_receive {:processing_worker, worker}
    assert %{active: 1} = ImagePipe.ProcessingPool.stats(pool)
    refute_received {:span, %Span{name: "image_pipe.processing.execute"}}
    assert_receive {:span, %Span{name: "image_pipe.request"} = request}
    send(worker, :finish)

    assert_receive {:span,
                    %Span{name: "image_pipe.processing.execute", status: :error} = execution}

    assert_receive {:span, %Span{name: "image_pipe.output.terminal"} = terminal}
    assert execution.end_time >= request.end_time
    assert admission.parent_span_id == request.span_id
    assert execution.parent_span_id == request.span_id
    assert terminal.parent_span_id == execution.span_id
    assert execution.attributes.result == "timeout"
    assert admission.attributes.active == 0
    assert admission.attributes.queued == 0
    assert execution.trace_id == request.trace_id
  end

  test "captures coordinated cache stages and pool identity" do
    prefix = [__MODULE__, :coordinated]
    :ok = TestExporter.attach(self(), prefix: prefix)

    for stage <- [:input, :refresh] do
      Telemetry.span([telemetry_prefix: prefix], [:cache, stage], %{pool: :input}, fn ->
        Telemetry.execute([telemetry_prefix: prefix], [:cache, :coordination], %{}, %{
          result: :coalesced,
          pool: :input,
          operation: :source
        })

        {:ok, %{result: :ok}}
      end)

      name = "image_pipe.cache.#{stage}"

      assert_receive {:span,
                      %Span{
                        name: ^name,
                        status: :unset,
                        attributes: %{pool: "input"},
                        events: [event]
                      }}

      assert event.name == "image_pipe.cache.coordination"
      assert event.attributes.result == "coalesced"
    end
  end

  test "captures a remote source staging failure with its error category" do
    prefix = [__MODULE__, :stage]
    :ok = TestExporter.attach(self(), prefix: prefix)

    Telemetry.span([telemetry_prefix: prefix], [:source, :stage], %{}, fn ->
      {{:error, {:source, :receive_timeout}}, %{result: :source_error, error: :receive_timeout}}
    end)

    assert_receive {:span,
                    %Span{
                      name: "image_pipe.source.stage",
                      attributes: %{result: "source_error", error: "receive_timeout"}
                    }}
  end

  test "watermark acquisition spans join the request trace across the process hop" do
    prefix = [__MODULE__, :watermark]
    :ok = TestExporter.attach(self(), prefix: prefix)

    dir =
      Path.join(System.tmp_dir!(), "image-pipe-trace-wm-#{System.unique_integer([:positive])}")

    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)

    for name <- ["image.png", "mark.png"],
        do:
          File.write!(
            Path.join(dir, name),
            Image.new!(8, 8) |> Image.write!(:memory, suffix: ".png")
          )

    config =
      ImagePipe.Plug.init(
        sources: [
          # Immutable, so the asset is opened after preparation rather than
          # staged during it, and both phases run.
          files: [
            adapter: ImagePipe.Source.File,
            match: :path,
            options: [root: dir, root_id: "t", stable: :immutable]
          ]
        ],
        watermarks: %{logo: [source: "mark.png"]},
        telemetry_prefix: prefix
      )

    conn =
      Plug.Test.conn(:get, "/wm=logo/format=png/src/image.png") |> ImagePipe.Plug.call(config)

    assert conn.status == 200

    assert_receive {:span, %Span{name: "image_pipe.request", trace_id: trace_id}}

    for phase <- ["prepare", "open"] do
      assert_receive {:span,
                      %Span{
                        name: "image_pipe.source.watermark",
                        trace_id: ^trace_id,
                        attributes: %{phase: ^phase, result: "ok"}
                      }}
    end
  end

  test "output coordination carries its request trace across the process hop" do
    prefix = [__MODULE__, :output_coordination]
    :ok = TestExporter.attach(self(), prefix: prefix)
    opts = [telemetry_prefix: prefix]

    Telemetry.span(opts, [:request], %{}, fn ->
      {:leader, lease} =
        OutputWork.join({__MODULE__, secret: "private"}, "key", opts)

      OutputWork.complete(lease, :ready)
      {:ok, %{result: :ok}}
    end)

    assert_receive {:span, %Span{name: "image_pipe.request", events: [event]}}
    assert event.name == "image_pipe.cache.coordination"
    assert event.attributes == %{pool: "output", operation: "output", result: "acquired"}
  end

  test "captures a nested tree with one trace_id and correct parentage" do
    emit_nested()

    assert_receive {:span, %Span{name: "image_pipe.transform.execute"} = child}
    assert_receive {:span, %Span{name: "image_pipe.request"} = root}

    assert root.parent_span_id == nil
    assert child.parent_span_id == root.span_id
    assert child.trace_id == root.trace_id
    assert root.status == :unset
    assert is_integer(child.duration_native)
    assert is_integer(root.start_time)
    assert is_integer(root.end_time)
    assert root.end_time >= root.start_time
  end

  test "captures the cache sweep span with its removal counts" do
    Telemetry.span([], [:cache, :sweep], %{pool: :input}, fn ->
      {:ok, %{result: :ok, pins: 1, temps: 2, bodies: 0, expired: 3, bytes: 10}}
    end)

    assert_receive {:span,
                    %Span{
                      name: "image_pipe.cache.sweep",
                      status: :unset,
                      attributes: %{
                        pool: "input",
                        pins: 1,
                        temps: 2,
                        bodies: 0,
                        expired: 3,
                        bytes: 10
                      }
                    }}
  end

  test "captures the cache re-scan span with its entry counts" do
    Telemetry.span([], [:cache, :rescan], %{pool: :output}, fn ->
      {:ok, %{result: :ok, adopted: 3, dropped: 1, resynced: 0}}
    end)

    assert_receive {:span,
                    %Span{
                      name: "image_pipe.cache.rescan",
                      status: :unset,
                      attributes: %{pool: "output", adopted: 3, dropped: 1, resynced: 0}
                    }}
  end

  test "maps an error result to :error status" do
    Telemetry.span([], [:request], %{}, fn -> {:ok, %{result: :processing_error}} end)
    assert_receive {:span, %Span{name: "image_pipe.request", status: :error}}
  end

  test "leaves the :options (OPTIONS) result's status unset, not :error" do
    Telemetry.span([], [:request], %{}, fn -> {:ok, %{result: :options, status: 204}} end)
    assert_receive {:span, %Span{name: "image_pipe.request", status: :unset}}
  end

  test "leaves normal stage outcomes' status unset" do
    for {stage, result} <- [
          {[:transform, :detect], :detected},
          {[:transform, :detect], :no_regions},
          {[:cache, :admission], :rejected},
          {[:deliver], :client_closed},
          {[:processing, :admission], :cancelled}
        ] do
      Telemetry.span([], stage, %{}, fn -> {:ok, %{result: result}} end)
      name = "image_pipe." <> Enum.map_join(stage, ".", &Atom.to_string/1)
      assert_receive {:span, %Span{name: ^name, status: status}}
      assert {result, status} == {result, :unset}
    end
  end

  test "maps failure outcomes to :error status" do
    for {stage, result} <- [
          {[:transform, :detect], :unavailable},
          {[:transform, :detect], :error},
          {[:processing, :admission], :overloaded},
          {[:processing, :execute], :timeout},
          {[:cache, :lookup], :cache_error},
          {[:request], :parser_error}
        ] do
      Telemetry.span([], stage, %{}, fn -> {:ok, %{result: result}} end)
      name = "image_pipe." <> Enum.map_join(stage, ".", &Atom.to_string/1)
      assert_receive {:span, %Span{name: ^name, status: status}}
      assert {result, status} == {result, :error}
    end
  end

  test "records an exception as :error with an exception event" do
    assert_raise RuntimeError, fn ->
      Telemetry.span([], [:request], %{}, fn -> raise "boom" end)
    end

    assert_receive {:span, %Span{name: "image_pipe.request", status: :error} = s}
    assert Enum.any?(s.events, &(&1.name == "exception"))
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
    assert span.status == :unset
    assert span.attributes[:objective] == "ssimulacra2"
    assert span.attributes[:max_bytes] == 200_000
    assert span.attributes[:target] == 90.0
  end

  test "captures an output terminal span with its terminal attribute" do
    prefix = [:capture_terminal_test]
    Telemetry.detach_tracer()
    :ok = TestExporter.attach(self(), prefix: prefix)

    for terminal <- [:info, :blurhash, :lqip_css] do
      expected = Atom.to_string(terminal)

      Telemetry.span(
        [telemetry_prefix: prefix],
        [:output, :terminal],
        %{terminal: terminal},
        fn ->
          {:ok, %{result: :ok}}
        end
      )

      assert_receive {:span, %Span{name: "image_pipe.output.terminal"} = span}
      assert span.status == :unset
      assert span.attributes[:terminal] == expected
    end

    Telemetry.span(
      [telemetry_prefix: prefix],
      [:output, :terminal],
      %{terminal: :info, placeholders: [:blurhash]},
      fn -> {:ok, %{result: :ok}} end
    )

    assert_receive {:span, %Span{name: "image_pipe.output.terminal"} = span}
    assert span.attributes[:placeholders] == ["blurhash"]
  end

  test "captures :sig_key_index on the API URL dialect's [:parse] stop metadata" do
    Telemetry.span([], [:parse], %{}, fn -> {:ok, %{result: :ok, sig_key_index: 1}} end)

    assert_receive {:span, %Span{name: "image_pipe.parse"} = span}
    assert span.status == :unset
    assert span.attributes[:sig_key_index] == 1
  end

  test "captures the preset lookup span with its names and counts" do
    Telemetry.span([], [:preset, :lookup], %{names: ["default", "card"]}, fn ->
      {:ok, %{result: :ok, fetched: 2, batches: 2}}
    end)

    assert_receive {:span, %Span{name: "image_pipe.preset.lookup"} = span}
    assert span.status == :unset
    assert span.attributes[:names] == ["default", "card"]
    assert span.attributes[:fetched] == 2
    assert span.attributes[:batches] == 2
  end

  test "an unsigned request's nil :sig_key_index does not appear as a [:parse] span attribute" do
    Telemetry.span([], [:parse], %{}, fn -> {:ok, %{result: :ok, sig_key_index: nil}} end)

    assert_receive {:span, %Span{name: "image_pipe.parse"} = span}
    refute Map.has_key?(span.attributes, :sig_key_index)
  end

  test "captures the encode-search probe as a span nested under the search, with its phase/numbers" do
    Telemetry.span([], [:encode, :search], %{objective: :ssimulacra2}, fn ->
      Telemetry.span(
        [],
        [:encode, :search, :probe],
        %{quality: 62, phase: :objective},
        fn ->
          {:ok, %{bytes: 12_345, index: 1, score: 90.42}}
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

    assert probe.attributes[:phase] == "objective"
    assert probe.attributes[:quality] == 62
    assert probe.attributes[:bytes] == 12_345
    assert probe.attributes[:index] == 1
    assert probe.attributes[:score] == 90.42
  end

  test "adds the delivered-probe chosen marker as an event on the enclosing search span" do
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
    assert chosen.attributes[:phase] == "objective"
    assert chosen.attributes[:index] == 3
    assert chosen.attributes[:score] == 90.42
    assert chosen.attributes[:scorer] == "full"
  end

  test "adds the debug collect error marker as an event on the enclosing span" do
    Telemetry.span([], [:cache, :lookup], %{}, fn ->
      Telemetry.execute([], [:debug, :collect, :error], %{}, %{error: :decode_failed})
      {:ok, %{result: :ok}}
    end)

    assert_receive {:span, %Span{name: "image_pipe.cache.lookup"} = span}

    refute_received {:span, %Span{name: "image_pipe.debug.collect.error"}}

    event = Enum.find(span.events, &(&1.name == "image_pipe.debug.collect.error"))
    assert event
    assert event.attributes[:error] == "decode_failed"
  end

  test "one-shot events keep the metadata the event reference documents" do
    events = [
      {[:http_cache, :prepare], %{effective_mode: :auto, byte_identity: :strong, etag: true},
       %{effective_mode: "auto", byte_identity: "strong", etag: true}},
      {[:http_cache, :conditional, :match], %{method: :get}, %{method: "get"}},
      {[:http_cache, :cache_hit, :headers],
       %{etag: true, generated_cache_headers: true, representation_headers: false},
       %{etag: true, generated_cache_headers: true, representation_headers: false}},
      {[:transform, :detect, :blend],
       %{attention: {0.5, 0.5}, face: {0.2, 0.3}, blended: {0.3, 0.4}, weight: 0.6},
       %{attention: "{0.5, 0.5}", face: "{0.2, 0.3}", blended: "{0.3, 0.4}", weight: 0.6}},
      {[:cache, :coordination], %{operation: :source, pool: :input, result: :acquired},
       %{operation: "source", pool: "input", result: "acquired"}},
      {[:cache, :eviction, :stop], %{trigger: :reconcile, pool: :output},
       %{trigger: "reconcile", pool: "output"}}
    ]

    Telemetry.span([], [:send], %{}, fn ->
      for {event, meta, _expected} <- events, do: Telemetry.execute([], event, %{}, meta)
      {:ok, %{result: :ok}}
    end)

    assert_receive {:span, %Span{name: "image_pipe.send"} = span}

    for {event, _meta, expected} <- events do
      name = "image_pipe." <> Enum.map_join(event, ".", &Atom.to_string/1)
      captured = Enum.find(span.events, &(&1.name == name))
      assert {name, captured.attributes} == {name, expected}
    end
  end

  test "detect spans keep the requested class weights" do
    Telemetry.span(
      [],
      [:transform, :detect],
      %{classes: ["face"], weights: %{"face" => 2.0}},
      fn ->
        {:ok, %{result: :detected, regions: 1}}
      end
    )

    assert_receive {:span, %Span{name: "image_pipe.transform.detect"} = span}
    assert span.attributes[:weights] == inspect(%{"face" => 2.0})
  end

  test "nests each libvips open under the fetch_decode span with its access mode" do
    Telemetry.span([], [:source, :fetch_decode], %{}, fn ->
      Telemetry.span([], [:source, :decode_open], %{access: :sequential}, fn ->
        {:ok, %{result: :ok}}
      end)

      {:ok, %{result: :ok}}
    end)

    assert_receive {:span, %Span{name: "image_pipe.source.decode_open"} = open}
    assert_receive {:span, %Span{name: "image_pipe.source.fetch_decode"} = decode}
    assert open.parent_span_id == decode.span_id
    assert open.attributes[:access] == "sequential"
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
    assert span.attributes[:objective] == "ssimulacra2"
    assert span.attributes[:max_bytes] == 200_000
    # stop attributes (the per-result verdict) now captured
    assert span.attributes[:chosen_quality] == 62
    assert span.attributes[:chosen_bytes] == 12_345
    assert span.attributes[:final_score] == 90.42
    assert span.attributes[:scorer] == "crop"
    assert span.attributes[:outcome] == "hit"
  end

  test "captures HTTP status and the classified error tag from stop metadata" do
    Telemetry.span([], [:request], %{}, fn ->
      {:ok, %{result: :source_error, status: 422, error: :body_too_large}}
    end)

    assert_receive {:span, %Span{name: "image_pipe.request"} = span}
    assert span.status == :error
    assert span.attributes[:status] == 422
    assert span.attributes[:error] == "body_too_large"
  end

  test "captures the realized :dims tuple from an operation span's stop metadata" do
    prefix = [__MODULE__, :operation_dims]
    :ok = Telemetry.detach_tracer()
    :ok = TestExporter.attach(self(), prefix: prefix)

    state = %State{image: Image.new!(200, 160, color: :white)}
    resize = %Resize{width: 100, height: 80}

    assert {:ok, %State{}} =
             Step.run(state, resize, telemetry_prefix: prefix)

    assert_receive {:span, %Span{name: "image_pipe.transform.operation"} = span}
    assert span.attributes[:operation] == "resize"
    assert span.attributes[:dims] == "{100, 80}"
    refute Map.has_key?(span.attributes, :index)
  end

  test "drops non-allowlisted stop-metadata keys" do
    Telemetry.span([], [:request], %{}, fn ->
      {:ok, %{result: :ok, source_url: "https://secret.example/signed?sig=abc"}}
    end)

    assert_receive {:span, %Span{name: "image_pipe.request"} = span}
    refute Map.has_key?(span.attributes, :source_url)
  end

  test "captures the input color management span with its working_space/imported? attributes" do
    Telemetry.span([], [:transform, :input_color_management], %{}, fn ->
      {:ok, %{result: :ok, working_space: :VIPS_INTERPRETATION_sRGB, imported?: true}}
    end)

    assert_receive {:span, %Span{name: "image_pipe.transform.input_color_management"} = span}
    assert span.status == :unset
    assert span.attributes[:working_space] == "VIPS_INTERPRETATION_sRGB"
    assert span.attributes[:imported?] == true
  end

  test "adds the ignored-options one-shot as an event on the request span" do
    Telemetry.span([], [:request], %{}, fn ->
      Telemetry.ignored_options([], ["fit"], [%{locations: [{:group, 0, :fit}]}])
      {:ok, %{result: :ok}}
    end)

    assert_receive {:span, %Span{name: "image_pipe.request"} = span}
    event = Enum.find(span.events, &(&1.name == "image_pipe.request.ignored_options"))
    assert event.attributes[:options] == ["fit"]
    refute Map.has_key?(event.attributes, :locations)
  end

  test "adds the clamp one-shot as an event on the enclosing span" do
    Telemetry.span([], [:encode], %{}, fn ->
      Telemetry.execute(
        [],
        [:output, :clamp],
        %{scale: 0.5},
        %{
          format: :webp,
          source_dimensions: {2000, 1500},
          dimensions: {1000, 750},
          limits: %{max_width: 1000, max_height: :infinity, max_pixels: 1_000_000}
        }
      )

      {:ok, %{result: :ok}}
    end)

    assert_receive {:span, %Span{name: "image_pipe.encode"} = span}

    refute_received {:span, %Span{name: "image_pipe.output.clamp"}}

    clamp = Enum.find(span.events, &(&1.name == "image_pipe.output.clamp"))
    assert clamp
    assert clamp.attributes[:format] == "webp"
    assert clamp.attributes[:source_dimensions] == "{2000, 1500}"
    assert clamp.attributes[:dimensions] == "{1000, 750}"

    assert clamp.attributes[:limits] ==
             inspect(%{max_width: 1000, max_height: :infinity, max_pixels: 1_000_000})
  end

  test "a request span nests under the caller's current span" do
    caller = TestExporter.open_span()

    Telemetry.span([], [:request], %{}, fn -> {:ok, %{result: :ok}} end)

    assert_receive {:span, %Span{name: "image_pipe.request"} = request}
    assert request.trace_id == caller.trace_id
    assert request.parent_span_id == caller.span_id
  end

  test "a request span carries the host's request ID from Logger metadata" do
    metadata = [request_id: "req-123"]
    Logger.metadata(metadata)

    Telemetry.span([], [:request], %{}, fn ->
      Telemetry.span([], [:parse], %{}, fn -> {:ok, %{result: :ok}} end)
      {:ok, %{result: :ok}}
    end)

    assert_receive {:span, %Span{name: "image_pipe.request"} = request}
    assert request.attributes[:request_id] == "req-123"
    assert_receive {:span, %Span{name: "image_pipe.parse"} = parse}
    refute Map.has_key?(parse.attributes, :request_id)
  end

  test "a span stops by its own identity, not the most recently opened span" do
    opts = []
    outer = Telemetry.start_span(opts, [:processing, :admission], %{})
    inner = Telemetry.start_span(opts, [:processing, :execute], %{})
    Telemetry.stop_span(outer, %{result: :admitted})
    Telemetry.stop_span(inner, %{result: :ok})

    assert_receive {:span, %Span{name: "image_pipe.processing.admission"} = admission}
    assert_receive {:span, %Span{name: "image_pipe.processing.execute"} = execute}
    assert admission.attributes.result == "admitted"
    assert execute.attributes.result == "ok"
    assert execute.parent_span_id == admission.span_id
  end
end
