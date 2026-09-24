defmodule ImagePipe.Telemetry.LoggerTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias ImagePipe.Telemetry
  alias ImagePipe.Test.FakeDetector
  alias ImagePipe.Transform
  alias ImagePipe.Transform.Detector.Composite
  alias ImagePipe.Transform.Materializer
  alias ImagePipe.Transform.Operation.Resize
  alias ImagePipe.Transform.PendingOrientation
  alias ImagePipe.Transform.State

  setup do
    on_exit(fn -> Telemetry.detach_default_logger() end)
    :ok
  end

  test "attach is idempotent and detach removes the handler" do
    assert :ok = Telemetry.attach_default_logger()
    assert :ok = Telemetry.attach_default_logger()
    assert :ok = Telemetry.detach_default_logger()
    assert {:error, :not_found} = Telemetry.detach_default_logger()
  end

  test "logs processing admission and deadline outcomes at warning level" do
    prefix = [__MODULE__, :processing]
    Telemetry.attach_default_logger(prefix: prefix, events: [:request], level: :debug)

    log =
      capture_log([level: :warning], fn ->
        for {stage, result} <- [
              {:admission, :overloaded},
              {:admission, :queue_timeout},
              {:execute, :timeout}
            ] do
          Telemetry.span([telemetry_prefix: prefix], [:processing, stage], %{}, fn ->
            {:ok, %{result: result}}
          end)
        end
      end)

    assert log =~ "processing admission: overloaded"
    assert log =~ "processing admission: queue_timeout"
    assert log =~ "processing execute: timeout"
  end

  test "renders successful source revalidation and truncated-source failures" do
    prefix = [__MODULE__, :origin_revalidation]
    Telemetry.attach_default_logger(prefix: prefix)

    log =
      capture_log(fn ->
        :telemetry.execute(prefix ++ [:source, :fetch, :stop], %{duration: 1000}, %{
          result: :not_modified
        })

        :telemetry.execute(prefix ++ [:source, :fetch_decode, :stop], %{duration: 1000}, %{
          result: :source_error,
          error: :truncated_body
        })
      end)

    assert log =~ "source fetch: not_modified"
    assert log =~ "source fetch_decode: source_error"
    assert log =~ "[warning]"
  end

  test "logs a cache lookup hit at the configured level" do
    Telemetry.attach_default_logger(level: :info)

    log =
      capture_log(fn ->
        :telemetry.execute(
          [:image_pipe, :cache, :lookup, :stop],
          %{duration: System.convert_time_unit(2, :millisecond, :native)},
          %{result: :ok, cache: :hit}
        )
      end)

    assert log =~ "cache lookup: hit"
  end

  test "logs coordinated cache stages and escalates refresh failure" do
    prefix = [__MODULE__, :coordinated]
    Telemetry.attach_default_logger(prefix: prefix)

    log =
      capture_log(fn ->
        for stage <- [:source, :input, :refresh] do
          :telemetry.execute(prefix ++ [:cache, stage, :stop], %{duration: 1_000}, %{
            result: :source_error,
            pool: :input
          })
        end

        :telemetry.execute(prefix ++ [:cache, :coordination], %{}, %{
          result: :coalesced,
          pool: :input,
          operation: :refresh
        })
      end)

    for stage <- [:source, :input, :refresh], do: assert(log =~ "cache #{stage}: source_error")
    assert log =~ "(input pool)"
    assert log =~ "cache coordination: coalesced"
    assert log =~ "[warning]"
  end

  test "output coalescing retains outcomes and warns on bypass" do
    prefix = [__MODULE__, :output_coordination]
    Telemetry.attach_default_logger(prefix: prefix, level: :info)

    log =
      capture_log(fn ->
        for result <- [:waiting, :ready, :bypass] do
          Telemetry.execute([telemetry_prefix: prefix], [:cache, :coordination], %{}, %{
            pool: :output,
            operation: :output,
            result: result
          })
        end
      end)

    assert log =~ "cache coordination: waiting (output pool)"
    assert log =~ "cache coordination: ready (output pool)"
    assert log =~ "[warning] image_pipe cache coordination: bypass (output pool)"
  end

  test "renders the encode span with its output format" do
    Telemetry.attach_default_logger(level: :info)

    log =
      capture_log(fn ->
        :telemetry.execute(
          [:image_pipe, :encode, :stop],
          %{duration: System.convert_time_unit(3, :millisecond, :native)},
          %{result: :ok, output_format: :jpeg}
        )
      end)

    assert log =~ "encode: ok (jpeg)"
  end

  test "renders an output terminal span with its terminal and outcome" do
    prefix = [:logger_terminal_test]
    Telemetry.attach_default_logger(level: :info, prefix: prefix)

    log =
      capture_log(fn ->
        for terminal <- [:info, :blurhash, :lqip_css] do
          :telemetry.execute(
            prefix ++ [:output, :terminal, :stop],
            %{duration: System.convert_time_unit(2, :millisecond, :native)},
            %{terminal: terminal, result: :ok}
          )
        end
      end)

    assert log =~ "output terminal: ok (info)"
    assert log =~ "output terminal: ok (blurhash)"
    assert log =~ "output terminal: ok (lqip_css)"
  end

  test "escalates an output terminal computation failure" do
    Telemetry.attach_default_logger(level: :info)

    log =
      capture_log(fn ->
        :telemetry.execute(
          [:image_pipe, :output, :terminal, :stop],
          %{duration: 1_000},
          %{terminal: :blurhash, result: :processing_error}
        )
      end)

    assert log =~ "[warning]"
    assert log =~ "output terminal: processing_error (blurhash)"
  end

  test "renders the request span with the :options (OPTIONS) outcome" do
    Telemetry.attach_default_logger(level: :info)

    log =
      capture_log(fn ->
        :telemetry.execute(
          [:image_pipe, :request, :stop],
          %{duration: System.convert_time_unit(1, :millisecond, :native)},
          %{result: :options, status: 204}
        )
      end)

    assert log =~ "request: options"
  end

  test "escalates a request-stage source/plan/parser error to warning" do
    Telemetry.attach_default_logger(level: :info)

    for result <- [:source_error, :plan_error, :parser_error] do
      log =
        capture_log(fn ->
          :telemetry.execute(
            [:image_pipe, :request, :stop],
            %{duration: 1000},
            %{result: result, status: 500, error: :boom}
          )
        end)

      assert log =~ "[warning]", "expected #{inspect(result)} to escalate to warning"
    end
  end

  # Deliberate exclusion, documented on `encode_failure?/2`: `:processing_error`
  # at `[:request]` (and `[:send]`/`[:deliver]`) also carries ordinary
  # streaming/connection outcomes such as a client disconnect, so it stays at
  # the base level there — unlike the same result at `[:encode]`, which is
  # always a genuine server-side compute failure (see the test above).
  test "does not escalate a request-stage processing error to warning" do
    Telemetry.attach_default_logger(level: :info)

    log =
      capture_log(fn ->
        :telemetry.execute(
          [:image_pipe, :request, :stop],
          %{duration: 1000},
          %{result: :processing_error, status: 500, error: :boom}
        )
      end)

    refute log =~ "[warning]"
  end

  test "escalates an encode processing error to warning" do
    Telemetry.attach_default_logger(level: :info)

    log =
      capture_log(fn ->
        :telemetry.execute(
          [:image_pipe, :encode, :stop],
          %{duration: 1000},
          %{result: :processing_error, output_format: :jpeg, error: :empty_stream}
        )
      end)

    assert log =~ "[warning]"
    assert log =~ "encode: processing_error"
  end

  test "renders the encode-search stop with outcome, chosen quality/bytes, and score" do
    Telemetry.attach_default_logger(level: :info)

    log =
      capture_log(fn ->
        :telemetry.execute(
          [:image_pipe, :encode, :search, :stop],
          %{duration: System.convert_time_unit(4, :millisecond, :native)},
          %{
            result: :ok,
            objective: :ssimulacra2,
            chosen_quality: 62,
            chosen_bytes: 12_345,
            iterations: 4,
            outcome: :hit,
            final_score: 90.42,
            scorer: :full
          }
        )
      end)

    refute log =~ "[warning]"
    assert log =~ "encode search: ok (full hit q62 12345b score 90.42)"
  end

  test "renders the crop scorer in the encode-search stop line" do
    Telemetry.attach_default_logger(level: :info)

    log =
      capture_log(fn ->
        :telemetry.execute(
          [:image_pipe, :encode, :search, :stop],
          %{duration: System.convert_time_unit(4, :millisecond, :native)},
          %{
            result: :ok,
            objective: :ssimulacra2,
            chosen_quality: 72,
            chosen_bytes: 12_345,
            iterations: 4,
            outcome: :hit,
            final_score: 90.42,
            scorer: :crop,
            tiles_scored: 16,
            confirm_passes: 1
          }
        )
      end)

    refute log =~ "[warning]"
    assert log =~ "encode search: ok (crop hit q72 12345b score 90.42)"
  end

  test "renders the content-class classify span at base level" do
    Telemetry.attach_default_logger(level: :info)

    log =
      capture_log(fn ->
        :telemetry.execute(
          [:image_pipe, :encode, :classify, :stop],
          %{duration: System.convert_time_unit(12, :millisecond, :native)},
          %{
            result: :ok,
            content_class: :graphic,
            applied_offset: 6.0,
            palette_ent: 0.34,
            nat_var: 0.11
          }
        )
      end)

    refute log =~ "[warning]"
    assert log =~ "encode classify: ok (graphic offset 6.0)"
  end

  test "escalates a best-effort encode-search to warning" do
    Telemetry.attach_default_logger(level: :info)

    log =
      capture_log(fn ->
        :telemetry.execute(
          [:image_pipe, :encode, :search, :stop],
          %{duration: 1000},
          %{
            result: :ok,
            objective: :size,
            chosen_quality: 10,
            chosen_bytes: 99_999,
            iterations: 6,
            outcome: :best_effort
          }
        )
      end)

    assert log =~ "[warning]"
    assert log =~ "encode search: ok (best_effort q10 99999b)"
  end

  test "renders an encode-search probe span stop with its phase, quality, bytes, score" do
    Telemetry.attach_default_logger(level: :info)

    log =
      capture_log(fn ->
        :telemetry.execute(
          [:image_pipe, :encode, :search, :probe, :stop],
          %{duration: System.convert_time_unit(1, :millisecond, :native)},
          %{result: :ok, phase: :confirm, quality: 65, bytes: 6500, score: 90.42}
        )
      end)

    refute log =~ "[warning]"
    assert log =~ "encode search probe: ok (confirm q65 6500b score 90.42)"
  end

  test "renders the delivered-probe chosen marker with quality, bytes, phase, score" do
    Telemetry.attach_default_logger(level: :info)

    log =
      capture_log(fn ->
        :telemetry.execute(
          [:image_pipe, :encode, :search, :probe, :chosen],
          %{},
          %{quality: 64, bytes: 12_345, phase: :objective, index: 3, score: 90.42}
        )
      end)

    refute log =~ "[warning]"
    assert log =~ "encode search chosen: q64 12345b (objective score 90.42)"
  end

  test "escalates an encode-search probe exception to warning" do
    Telemetry.attach_default_logger(level: :info)

    log =
      capture_log(fn ->
        :telemetry.execute(
          [:image_pipe, :encode, :search, :probe, :exception],
          %{duration: 1000},
          %{kind: :error, reason: :badimage, phase: :objective, quality: 50}
        )
      end)

    assert log =~ "[warning]"
    assert log =~ "encode search probe: exception"
  end

  test "renders the deliver span and does not escalate a client disconnect" do
    Telemetry.attach_default_logger(level: :info)

    log =
      capture_log(fn ->
        :telemetry.execute(
          [:image_pipe, :deliver, :stop],
          %{duration: 1000},
          %{result: :client_closed, output_format: :jpeg, status: 200}
        )
      end)

    refute log =~ "[warning]"
    assert log =~ "deliver: client_closed"
  end

  test "escalates error outcomes to warning" do
    Telemetry.attach_default_logger(level: :info)

    log =
      capture_log(fn ->
        :telemetry.execute(
          [:image_pipe, :cache, :write, :stop],
          %{duration: 1000},
          %{result: :cache_error, cache: :write_error, error: :boom}
        )
      end)

    assert log =~ "[warning]"
    assert log =~ "cache write"
  end

  test "renders exception events as exceptions at warning level" do
    Telemetry.attach_default_logger(level: :info)

    log =
      capture_log(fn ->
        :telemetry.execute(
          [:image_pipe, :source, :fetch, :exception],
          %{duration: 1000},
          %{kind: :error, reason: :boom, stacktrace: []}
        )
      end)

    assert log =~ "[warning]"
    assert log =~ "exception"
  end

  test "escalates a configured-detector fallback (:unavailable) to warning" do
    Telemetry.attach_default_logger(level: :info)

    log =
      capture_log(fn ->
        :telemetry.execute(
          [:image_pipe, :transform, :detect, :stop],
          %{duration: 1000},
          %{classes: ["face"], regions: 0, result: :unavailable}
        )
      end)

    assert log =~ "[warning]"
    assert log =~ "transform detect: unavailable"
  end

  test "logs the face-assist blend one-shot at base level, showing the saliency skew" do
    Telemetry.attach_default_logger(level: :info)

    log =
      capture_log(fn ->
        :telemetry.execute(
          [:image_pipe, :transform, :detect, :blend],
          %{},
          %{attention: {0.5, 0.5}, face: {0.2, 0.8}, blended: {0.29, 0.71}, weight: 0.7}
        )
      end)

    refute log =~ "[warning]"
    assert log =~ "transform detect blend: attention (0.5,0.5) -> (0.29,0.71)"
    assert log =~ "weight 0.7"
  end

  test "logs the no-detector skipped one-shot at warning" do
    Telemetry.attach_default_logger(level: :info)

    log =
      capture_log(fn ->
        :telemetry.execute(
          [:image_pipe, :transform, :detect, :skipped],
          %{},
          %{classes: ["face"], result: :no_detector}
        )
      end)

    assert log =~ "[warning]"
    assert log =~ "transform detect: skipped (no detector configured)"
  end

  test "logs the output clamp one-shot at warning with source -> clamped dims" do
    Telemetry.attach_default_logger(level: :info)

    log =
      capture_log(fn ->
        :telemetry.execute(
          [:image_pipe, :output, :clamp],
          %{scale: 0.91},
          %{
            format: :webp,
            source_dimensions: {18_000, 9_000},
            dimensions: {8_192, 4_096},
            limits: %{max_width: 8_192, max_height: 8_192, max_pixels: 40_000_000}
          }
        )
      end)

    assert log =~ "[warning]"

    assert log =~
             "output clamp: 18000x9000 -> 8192x4096 for webp (caps w:8192 h:8192 px:40000000)"
  end

  test "logs the debug collect error one-shot at warning with the error tag" do
    Telemetry.attach_default_logger(level: :info)

    log =
      capture_log(fn ->
        :telemetry.execute(
          [:image_pipe, :debug, :collect, :error],
          %{},
          %{error: :decode_failed}
        )
      end)

    assert log =~ "[warning]"
    assert log =~ "debug collect: error (decode_failed)"
  end

  test "logs a normal no-face detect fallback at the base level, not warning" do
    Telemetry.attach_default_logger(level: :info)

    log =
      capture_log(fn ->
        :telemetry.execute(
          [:image_pipe, :transform, :detect, :stop],
          %{duration: 1000},
          %{classes: ["face"], regions: 0, result: :no_regions}
        )
      end)

    refute log =~ "[warning]"
    assert log =~ "transform detect: no_regions"
  end

  test "renders transform operation success and error outcomes" do
    prefix = [__MODULE__, :operation_outcome]
    Telemetry.attach_default_logger(level: :debug, prefix: prefix)
    state = %State{image: Image.new!(20, 10, color: :white)}
    resize = %Resize{width: 10, height: 5}

    # capture at :debug explicitly so the test does not depend on the ambient
    # Logger level.
    log =
      capture_log([level: :debug], fn ->
        assert {:ok, %State{}} =
                 Transform.run(state, resize, telemetry_prefix: prefix)

        :telemetry.execute(
          prefix ++ [:transform, :operation, :stop],
          %{duration: 500},
          %{operation: :resize, params: resize, result: :error}
        )
      end)

    assert log =~ "transform: resize ok"
    assert log =~ "transform: resize error"
  end

  test "renders the transform execute aggregate with outcome and operation count" do
    Telemetry.attach_default_logger(level: :debug)

    log =
      capture_log([level: :debug], fn ->
        :telemetry.execute(
          [:image_pipe, :transform, :execute, :stop],
          %{duration: 500},
          %{result: :ok, operations: [:resize, :flip], operation_count: 2}
        )
      end)

    assert log =~ "transform execute: ok (2 ops)"
  end

  test "renders the transform execute aggregate with a failure outcome" do
    Telemetry.attach_default_logger(level: :debug)

    log =
      capture_log([level: :debug], fn ->
        :telemetry.execute(
          [:image_pipe, :transform, :execute, :stop],
          %{duration: 500},
          %{result: :processing_error, operation_count: 2}
        )
      end)

    assert log =~ "transform execute: processing_error (2 ops)"
  end

  test "logs input_color_management success at base level with working space" do
    Telemetry.attach_default_logger(level: :info)

    log =
      capture_log(fn ->
        :telemetry.execute(
          [:image_pipe, :transform, :input_color_management, :stop],
          %{duration: 500},
          %{result: :ok, working_space: :VIPS_INTERPRETATION_sRGB, imported?: false}
        )
      end)

    refute log =~ "[warning]"
    assert log =~ "transform input_color_management: ok"
    assert log =~ "VIPS_INTERPRETATION_sRGB"
  end

  test "logs input_color_management with imported profile marker" do
    Telemetry.attach_default_logger(level: :info)

    log =
      capture_log(fn ->
        :telemetry.execute(
          [:image_pipe, :transform, :input_color_management, :stop],
          %{duration: 500},
          %{result: :ok, working_space: :VIPS_INTERPRETATION_sRGB, imported?: true}
        )
      end)

    refute log =~ "[warning]"
    assert log =~ "transform input_color_management: ok imported"
    assert log =~ "VIPS_INTERPRETATION_sRGB"
  end

  test "logs input_color_management preserved HDR working space" do
    Telemetry.attach_default_logger(level: :info)

    log =
      capture_log(fn ->
        :telemetry.execute(
          [:image_pipe, :transform, :input_color_management, :stop],
          %{duration: 500},
          %{result: :ok, working_space: :VIPS_INTERPRETATION_RGB16, imported?: false}
        )
      end)

    assert log =~ "transform input_color_management: ok"
    assert log =~ "VIPS_INTERPRETATION_RGB16"
  end

  test "escalates input_color_management processing error to warning" do
    Telemetry.attach_default_logger(level: :info)

    log =
      capture_log(fn ->
        :telemetry.execute(
          [:image_pipe, :transform, :input_color_management, :stop],
          %{duration: 500},
          %{result: :processing_error, working_space: :VIPS_INTERPRETATION_sRGB, imported?: false}
        )
      end)

    assert log =~ "[warning]"
    assert log =~ "transform input_color_management: processing_error"
  end

  test "renders the detected source format and resolution on the fetch_decode span" do
    Telemetry.attach_default_logger(level: :info)

    log =
      capture_log(fn ->
        :telemetry.execute(
          [:image_pipe, :source, :fetch_decode, :stop],
          %{duration: System.convert_time_unit(3, :millisecond, :native)},
          %{result: :ok, detected_source_format: :jpeg, source_format_resolution: :detected}
        )
      end)

    assert log =~ "source fetch_decode: ok (detected jpeg via detected)"
  end

  test "renders the detected format on an unsupported-format reject" do
    Telemetry.attach_default_logger(level: :info)

    log =
      capture_log(fn ->
        :telemetry.execute(
          [:image_pipe, :source, :fetch_decode, :stop],
          %{duration: System.convert_time_unit(1, :millisecond, :native)},
          %{
            result: :processing_error,
            error: :unsupported_source_format,
            detected_source_format: :svg
          }
        )
      end)

    assert log =~ "source fetch_decode: processing_error (detected svg)"
  end

  test "renders the output negotiate span with its outcome and format" do
    Telemetry.attach_default_logger(level: :info)

    log =
      capture_log(fn ->
        :telemetry.execute(
          [:image_pipe, :output, :negotiate, :stop],
          %{duration: System.convert_time_unit(1, :millisecond, :native)},
          %{result: :ok, output_mode: :automatic, output_format: :jpeg}
        )
      end)

    refute log =~ "[warning]"
    assert log =~ "output negotiate: ok (jpeg)"
  end

  test "escalates an output negotiate failure to warning" do
    Telemetry.attach_default_logger(level: :info)

    log =
      capture_log(fn ->
        :telemetry.execute(
          [:image_pipe, :output, :negotiate, :stop],
          %{duration: 1000},
          %{result: :output_error, output_mode: :explicit, error: :unsupported}
        )
      end)

    assert log =~ "[warning]"
    assert log =~ "output negotiate: output_error"
  end

  test "renders the per-model detect span with its region count and outcome" do
    prefix = [__MODULE__, :model_success]
    Telemetry.attach_default_logger(level: :info, prefix: prefix)

    log =
      capture_log(fn ->
        :telemetry.execute(
          prefix ++ [:transform, :detect, :model, :stop],
          %{duration: System.convert_time_unit(5, :millisecond, :native)},
          %{
            detector: ImagePipe.Transform.Detector.ImageVision.Face,
            classes: ["face"],
            regions: 2,
            result: :ok
          }
        )
      end)

    refute log =~ "[warning]"
    assert log =~ "transform detect model: ok (2 regions"
  end

  test "logs composite child failures at warning level" do
    prefix = [__MODULE__, :model_failure]
    Telemetry.attach_default_logger(level: :info, prefix: prefix)
    detector = FakeDetector.returning({:error, "private detector reason"})
    composite = Composite.new([detector])

    log =
      capture_log([level: :warning], fn ->
        Composite.detect(composite, :image, telemetry_opts: [telemetry_prefix: prefix])
      end)

    assert log =~ "transform detect model: error (0 regions"
    refute log =~ "private detector reason"
  end

  test "logs the http_cache prepare one-shot at base level with its mode" do
    Telemetry.attach_default_logger(level: :info)

    log =
      capture_log(fn ->
        :telemetry.execute(
          [:image_pipe, :http_cache, :prepare],
          %{},
          %{effective_mode: :generate, byte_identity: :strong, etag: true}
        )
      end)

    refute log =~ "[warning]"
    assert log =~ "http_cache prepare: generate"
    assert log =~ "byte_identity strong"
  end

  test "logs the http_cache conditional match one-shot with the method" do
    Telemetry.attach_default_logger(level: :info)

    log =
      capture_log(fn ->
        :telemetry.execute(
          [:image_pipe, :http_cache, :conditional, :match],
          %{},
          %{method: :get}
        )
      end)

    refute log =~ "[warning]"
    assert log =~ "http_cache conditional match: get"
  end

  test "logs the http_cache no-store fallback one-shot with its reason" do
    Telemetry.attach_default_logger(level: :info)

    log =
      capture_log(fn ->
        :telemetry.execute(
          [:image_pipe, :http_cache, :fallback, :no_store],
          %{},
          %{adapter: SomeAdapter, source_kind: :url, reason: :missing_byte_identity}
        )
      end)

    refute log =~ "[warning]"
    assert log =~ "http_cache fallback no_store: missing_byte_identity"
  end

  test "logs the http_cache cache-hit headers one-shot" do
    Telemetry.attach_default_logger(level: :info)

    log =
      capture_log(fn ->
        :telemetry.execute(
          [:image_pipe, :http_cache, :cache_hit, :headers],
          %{},
          %{etag: true, generated_cache_headers: true, representation_headers: false}
        )
      end)

    refute log =~ "[warning]"
    assert log =~ "http_cache cache_hit headers: etag true"
  end

  test "http_cache events can be filtered as their own group" do
    Telemetry.attach_default_logger(level: :info, events: [:cache])

    log =
      capture_log(fn ->
        :telemetry.execute(
          [:image_pipe, :http_cache, :prepare],
          %{},
          %{effective_mode: :generate, byte_identity: :strong, etag: true}
        )
      end)

    refute log =~ "http_cache"
  end

  test "rejects an invalid log level" do
    assert_raise ArgumentError, fn -> Telemetry.attach_default_logger(level: :nope) end
  end

  test ":events filter excludes other groups" do
    Telemetry.attach_default_logger(level: :info, events: [:cache])

    log =
      capture_log(fn ->
        # transform group not attached -> nothing logged
        :telemetry.execute([:image_pipe, :transform, :execute, :stop], %{duration: 1}, %{
          result: :ok
        })
      end)

    refute log =~ "transform"
  end

  test ":debug true logs the raw payload including high-cardinality fields" do
    prefix = [__MODULE__, :operation_debug]
    Telemetry.attach_default_logger(level: :debug, debug: true, prefix: prefix)
    state = %State{image: Image.new!(20, 10, color: :white)}
    resize = %Resize{width: 12, height: 5}

    log =
      capture_log([level: :debug], fn ->
        assert {:ok, %State{}} =
                 Transform.run(state, resize, telemetry_prefix: prefix)
      end)

    assert log =~ "raw:"
    assert log =~ "ImagePipe.Transform.Operation.Resize"
    assert log =~ "width: 12"
    assert log =~ "height: 5"
  end

  test ":prefix attaches under a custom event prefix" do
    Telemetry.attach_default_logger(level: :info, events: [:cache], prefix: [:my_app, :images])

    log =
      capture_log(fn ->
        :telemetry.execute(
          [:my_app, :images, :cache, :lookup, :stop],
          %{duration: 1},
          %{result: :ok, cache: :hit}
        )
      end)

    assert log =~ "cache lookup: hit"
  end

  test "rejects unknown options, bad event groups, a non-list prefix, and a non-boolean debug" do
    assert_raise ArgumentError, fn -> Telemetry.attach_default_logger(bogus: true) end
    assert_raise ArgumentError, fn -> Telemetry.attach_default_logger(events: [:nope]) end
    assert_raise ArgumentError, fn -> Telemetry.attach_default_logger(prefix: "nope") end
    assert_raise ArgumentError, fn -> Telemetry.attach_default_logger(debug: :yes) end
  end

  test "invalid configuration leaves the existing logger attached" do
    prefix = [__MODULE__, :invalid_configuration]
    Telemetry.attach_default_logger(prefix: prefix, events: [:cache])

    for opts <- [[prefix: []], [prefix: [:app, "images"]], [events: "cache"], [events: [nil]]] do
      assert_raise ArgumentError, fn -> Telemetry.attach_default_logger(opts) end
    end

    log =
      capture_log(fn ->
        :telemetry.execute(prefix ++ [:cache, :lookup, :stop], %{duration: 1}, %{
          result: :ok,
          cache: :hit
        })
      end)

    assert log =~ "cache lookup: hit"
  end

  test "orientation logs materialization of each display frame" do
    prefix = [__MODULE__, :orientation]
    opts = [telemetry_prefix: prefix]
    Telemetry.attach_default_logger(prefix: prefix, level: :info, debug: true)

    state = %State{
      image: Image.new!(40, 20),
      pending_orientation:
        PendingOrientation.from_exif(6, false) |> PendingOrientation.fold_rotate(90),
      telemetry_opts: opts
    }

    log =
      capture_log([level: :debug], fn ->
        assert {:ok, %State{} = state} = Materializer.flush(state)

        pending =
          PendingOrientation.from_exif(1, false) |> PendingOrientation.fold_flip(:horizontal)

        assert {:ok, _state} =
                 Materializer.flush(%State{state | pending_orientation: pending})
      end)

    assert length(Regex.scan(~r/transform materialize: ok/, log)) == 2
    assert log =~ "dims: {20, 40}"
    refute log =~ "[warning]"
  end

  test "materialize stop carrying materialize_error escalates to warning" do
    Telemetry.attach_default_logger(level: :info)

    log =
      capture_log(fn ->
        :telemetry.execute(
          [:image_pipe, :transform, :materialize, :stop],
          %{duration: 10},
          %{result: :materialize_error}
        )
      end)

    assert log =~ "[warning]"
    assert log =~ "transform materialize"
  end

  test "materialize exception escalates to warning" do
    Telemetry.attach_default_logger(level: :info)

    log =
      capture_log(fn ->
        :telemetry.execute(
          [:image_pipe, :transform, :materialize, :exception],
          %{duration: 5},
          %{kind: :error, reason: %RuntimeError{message: "x"}, stacktrace: []}
        )
      end)

    assert log =~ "[warning]"
    assert log =~ "transform materialize"
  end
end
