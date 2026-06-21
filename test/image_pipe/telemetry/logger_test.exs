defmodule ImagePipe.Telemetry.LoggerTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias ImagePipe.Telemetry

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
            objective: :ssim2,
            chosen_quality: 62,
            chosen_bytes: 12_345,
            iterations: 4,
            outcome: :hit,
            final_score: 90.42
          }
        )
      end)

    refute log =~ "[warning]"
    assert log =~ "encode search: ok (hit q62 12345b score 90.42)"
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
            objective: :ssim2,
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

  test "renders a transform operation with name and index" do
    Telemetry.attach_default_logger(level: :debug)

    # capture at :debug explicitly so the test does not depend on the ambient
    # Logger level.
    log =
      capture_log([level: :debug], fn ->
        :telemetry.execute(
          [:image_pipe, :transform, :operation, :stop],
          %{duration: 500},
          %{operation: :resize, index: 0, params: %{}, result: :ok}
        )
      end)

    assert log =~ "transform: resize (#1)"
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

  test "renders the render span with its content type on success" do
    Telemetry.attach_default_logger(level: :info)

    log =
      capture_log(fn ->
        :telemetry.execute(
          [:image_pipe, :render, :stop],
          %{duration: System.convert_time_unit(2, :millisecond, :native)},
          %{result: :ok, content_type: "application/json"}
        )
      end)

    assert log =~ "render"
    assert log =~ "ok"
    assert log =~ "application/json"
    refute log =~ "[warning]"
  end

  test "escalates a render_error to warning" do
    Telemetry.attach_default_logger(level: :info)

    log =
      capture_log(fn ->
        :telemetry.execute(
          [:image_pipe, :render, :stop],
          %{duration: 1000},
          %{result: :render_error, error: :boom}
        )
      end)

    assert log =~ "[warning]"
    assert log =~ "render"
    assert log =~ "render_error"
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
    Telemetry.attach_default_logger(level: :debug, debug: true)

    log =
      capture_log([level: :debug], fn ->
        :telemetry.execute(
          [:image_pipe, :transform, :operation, :stop],
          %{duration: 1},
          %{operation: :resize, index: 0, params: %{magic: 12_345}, result: :ok}
        )
      end)

    assert log =~ "raw:"
    assert log =~ "12345"
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

  test "successful materialize flush logs at base level, no warning" do
    Telemetry.attach_default_logger(level: :info)

    log =
      capture_log(fn ->
        :telemetry.execute(
          [:image_pipe, :transform, :materialize, :stop],
          %{duration: 10},
          %{result: :ok}
        )
      end)

    assert log =~ "transform materialize"
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
