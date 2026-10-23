defmodule ImagePipe.Telemetry.LoggerTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias ImagePipe.Telemetry
  alias ImagePipe.Test.FakeDetector
  alias ImagePipe.Transform.Detector.Composite
  alias ImagePipe.Transform.Executor.Step
  alias ImagePipe.Transform.Materializer
  alias ImagePipe.Transform.Operation.Resize
  alias ImagePipe.Transform.PendingOrientation
  alias ImagePipe.Transform.State

  setup do
    on_exit(fn -> Telemetry.detach_default_logger() end)
    :ok
  end

  test "attach is idempotent and detach removes the handler" do
    assert :ok = Telemetry.attach_default_logger(stages: true)
    assert :ok = Telemetry.attach_default_logger(stages: true)
    assert :ok = Telemetry.detach_default_logger()
    assert {:error, :not_found} = Telemetry.detach_default_logger()
  end

  test "lines from the processing worker carry the request's Logger metadata" do
    prefix = [__MODULE__, :request_id]
    Telemetry.attach_default_logger(prefix: prefix, events: [:transform], stages: true)
    pool = start_supervised!({ImagePipe.ProcessingPool, max_concurrency: 1})

    config =
      ImagePipe.config(
        allow_unsigned: true,
        processing_pool: pool,
        telemetry_prefix: prefix,
        sources: [
          path: [
            adapter: ImagePipe.Source.File,
            match: :path,
            options: [root: "priv/static", root_id: "static"]
          ]
        ]
      )

    mount = ImagePipe.Plug.init(config: config)

    log =
      capture_log([format: "$metadata| $message\n", metadata: [:request_id]], fn ->
        conn =
          Plug.Test.conn(:get, "/w=32/format=png/src/images/beach.jpg")
          |> Plug.RequestId.call(Plug.RequestId.init([]))
          |> ImagePipe.Plug.call(mount)

        send(self(), {:request_id, Plug.Conn.get_resp_header(conn, "x-request-id")})
      end)

    assert_received {:request_id, [id]}
    assert log =~ "request_id=#{id} | image_pipe transform execute: ok"
  end

  test "logs processing admission and deadline outcomes at warning level" do
    prefix = [__MODULE__, :processing]

    Telemetry.attach_default_logger(
      prefix: prefix,
      events: [:request],
      level: :debug,
      stages: true
    )

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

  test "logs a low-priority request's admission rejection below warning level" do
    prefix = [__MODULE__, :low_priority]

    Telemetry.attach_default_logger(
      prefix: prefix,
      events: [:request],
      level: :info,
      stages: true
    )

    reject = fn ->
      for result <- [:overloaded, :queue_timeout] do
        Telemetry.span(
          [telemetry_prefix: prefix],
          [:processing, :admission],
          %{priority: :low},
          fn -> {:ok, %{result: result}} end
        )
      end
    end

    refute capture_log([level: :warning], reject) =~ "processing admission"
    assert capture_log([level: :info], reject) =~ "processing admission: queue_timeout"
  end

  test "renders successful source revalidation and truncated-source failures" do
    prefix = [__MODULE__, :origin_revalidation]
    Telemetry.attach_default_logger(prefix: prefix, stages: true)

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

  test "renders watermark acquisition phases with their outcome" do
    prefix = [__MODULE__, :watermark]
    Telemetry.attach_default_logger(prefix: prefix, stages: true)

    log =
      capture_log(fn ->
        :telemetry.execute(prefix ++ [:source, :watermark, :stop], %{duration: 1000}, %{
          phase: :prepare,
          result: :ok
        })

        :telemetry.execute(prefix ++ [:source, :watermark, :stop], %{duration: 1000}, %{
          phase: :open,
          result: :source_error
        })
      end)

    assert log =~ "source watermark prepare: ok"
    assert log =~ "source watermark open: source_error"
    assert log =~ "[warning]"
  end

  test "names the source on resolve and fetch lines" do
    prefix = [__MODULE__, :source_name]
    Telemetry.attach_default_logger(prefix: prefix, stages: true)

    log =
      capture_log(fn ->
        for stage <- [:resolve, :fetch] do
          :telemetry.execute(prefix ++ [:source, stage, :stop], %{duration: 1000}, %{
            result: :ok,
            source_name: :media
          })
        end

        :telemetry.execute(prefix ++ [:source, :resolve, :stop], %{duration: 1000}, %{
          result: :source_error,
          source_name: nil
        })
      end)

    assert log =~ "source resolve: ok (source media)"
    assert log =~ "source fetch: ok (source media)"
    assert log =~ "source resolve: source_error\n"
  end

  test "logs a cache lookup hit at the configured level" do
    Telemetry.attach_default_logger(level: :info, stages: true)

    log =
      capture_log(fn ->
        :telemetry.execute(
          [:image_pipe, :cache, :lookup, :stop],
          %{duration: System.convert_time_unit(2, :millisecond, :native)},
          %{result: :ok, cache: :hit, bytes: 12_345}
        )
      end)

    assert log =~ "cache lookup: hit 12345b"
  end

  test "names the memory pool on a source record lookup" do
    Telemetry.attach_default_logger(level: :info, stages: true)

    log =
      capture_log(fn ->
        :telemetry.execute(
          [:image_pipe, :cache, :lookup, :stop],
          %{duration: System.convert_time_unit(1, :millisecond, :native)},
          %{result: :ok, cache: :hit, entry: :source_record, pool: :memory}
        )
      end)

    assert log =~ "cache lookup: hit"
    assert log =~ "(memory pool)"
  end

  test "drops events below Logger's level and still logs warnings" do
    Telemetry.attach_default_logger(level: :info, stages: true)
    level = Logger.level()
    Logger.configure(level: :warning)
    on_exit(fn -> Logger.configure(level: level) end)

    log =
      capture_log(fn ->
        :telemetry.execute(
          [:image_pipe, :cache, :lookup, :stop],
          %{duration: System.convert_time_unit(2, :millisecond, :native)},
          %{result: :ok, cache: :hit}
        )

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

    refute log =~ "cache lookup"
    assert log =~ "[warning]"
    assert log =~ "output clamp: 18000x9000 -> 8192x4096"
  end

  test "logs coordinated cache stages and escalates refresh failure" do
    prefix = [__MODULE__, :coordinated]
    Telemetry.attach_default_logger(prefix: prefix, stages: true)

    log =
      capture_log(fn ->
        :telemetry.execute(prefix ++ [:cache, :refresh, :stop], %{duration: 1_000}, %{
          result: :source_error,
          pool: :input
        })

        :telemetry.execute(prefix ++ [:cache, :coordination], %{}, %{
          result: :coalesced,
          pool: :input,
          operation: :refresh
        })
      end)

    assert log =~ "cache refresh: source_error"
    assert log =~ "(input pool)"
    assert log =~ "cache coordination: coalesced"
    assert log =~ "[warning]"
  end

  test "warns about cache writes dropped to keep up with storage" do
    prefix = [__MODULE__, :dropped_write]
    Telemetry.attach_default_logger(prefix: prefix, level: :info, stages: true)

    log =
      capture_log(fn ->
        Telemetry.execute([telemetry_prefix: prefix], [:cache, :stage], %{}, %{
          result: :ok,
          cache: :stage_dropped,
          reason: :pending_limit,
          output_format: :webp,
          cache_key: "abc"
        })
      end)

    assert log =~ "[warning] image_pipe cache stage: stage_dropped (pending_limit)"
  end

  test "output coalescing retains outcomes and warns on bypass" do
    prefix = [__MODULE__, :output_coordination]
    Telemetry.attach_default_logger(prefix: prefix, level: :info, stages: true)

    log =
      capture_log(fn ->
        for result <- [:waiting, :ready, :bypass] do
          Telemetry.execute([telemetry_prefix: prefix], [:cache, :coordination], %{}, %{
            pool: :output,
            operation: :output,
            result: result
          })
        end

        Telemetry.execute([telemetry_prefix: prefix], [:cache, :coordination], %{}, %{
          pool: :output,
          operation: :output,
          result: :bypass,
          reason: :deadline
        })
      end)

    assert log =~ "cache coordination: waiting (output pool)"
    assert log =~ "cache coordination: ready (output pool)"
    assert log =~ "[warning] image_pipe cache coordination: bypass (output pool)"
    assert log =~ "[warning] image_pipe cache coordination: bypass (deadline) (output pool)"
  end

  test "logs the cache sweep span" do
    prefix = [__MODULE__, :cache_sweep]
    Telemetry.attach_default_logger(prefix: prefix, level: :info, stages: true)

    log =
      capture_log(fn ->
        Telemetry.span([telemetry_prefix: prefix], [:cache, :sweep], %{pool: :input}, fn ->
          {:ok, %{result: :ok, pins: 1, temps: 0, bodies: 0, bytes: 5}}
        end)
      end)

    assert log =~ "cache sweep: ok"
  end

  test "logs cache sweeps that changed nothing at debug level" do
    prefix = [__MODULE__, :cache_quiet_passes]
    Telemetry.attach_default_logger(prefix: prefix, level: :info, stages: true)
    opts = [telemetry_prefix: prefix]

    log =
      capture_log([level: :debug], fn ->
        Telemetry.span(opts, [:cache, :sweep], %{pool: :output}, fn ->
          {:ok, %{result: :ok, pins: 0, temps: 0, bodies: 0, bytes: 0}}
        end)

        Telemetry.span(opts, [:cache, :sweep], %{pool: :input}, fn ->
          {:ok, %{result: :ok, pins: 0, temps: 0, bodies: 1, unreadable: 1, bytes: 9}}
        end)
      end)

    assert log =~ "[info] image_pipe cache sweep: ok (input pool)"
    assert log =~ "[debug] image_pipe cache sweep: ok (output pool)"
  end

  test "warns when a request stops waiting for another's source download" do
    prefix = [__MODULE__, :source_wait_timeout]
    Telemetry.attach_default_logger(prefix: prefix, level: :info, stages: true)

    log =
      capture_log(fn ->
        Telemetry.execute([telemetry_prefix: prefix], [:cache, :coordination], %{}, %{
          pool: :input,
          operation: :source,
          result: :timeout
        })
      end)

    assert log =~ "[warning] image_pipe cache coordination: timeout (input pool)"
  end

  test "logs waits ended by an original that may not be stored at the base level" do
    prefix = [__MODULE__, :source_not_stored]
    Telemetry.attach_default_logger(prefix: prefix, level: :info, stages: true)

    log =
      capture_log(fn ->
        Telemetry.execute([telemetry_prefix: prefix], [:cache, :coordination], %{}, %{
          pool: :input,
          operation: :source,
          result: :bypass,
          reason: :not_stored
        })
      end)

    assert log =~ "[info] image_pipe cache coordination: bypass (not_stored) (input pool)"
    refute log =~ "[warning]"
  end

  test "renders the encode span with its output format" do
    Telemetry.attach_default_logger(level: :info, stages: true)

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
    Telemetry.attach_default_logger(level: :info, prefix: prefix, stages: true)

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

    log =
      capture_log(fn ->
        :telemetry.execute(
          prefix ++ [:output, :terminal, :stop],
          %{duration: System.convert_time_unit(2, :millisecond, :native)},
          %{terminal: :info, placeholders: [:blurhash, :lqip_css], result: :ok}
        )
      end)

    assert log =~ "output terminal: ok (info with blurhash, lqip_css)"
  end

  test "escalates an output terminal computation failure" do
    Telemetry.attach_default_logger(level: :info, stages: true)

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
    Telemetry.attach_default_logger(level: :info, stages: true)

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
    Telemetry.attach_default_logger(level: :info, stages: true)

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
    Telemetry.attach_default_logger(level: :info, stages: true)

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
    Telemetry.attach_default_logger(level: :info, stages: true)

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
    Telemetry.attach_default_logger(level: :info, stages: true)

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
    Telemetry.attach_default_logger(level: :info, stages: true)

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
            tiles_scored: 16
          }
        )
      end)

    refute log =~ "[warning]"
    assert log =~ "encode search: ok (crop hit q72 12345b score 90.42)"
  end

  test "escalates a best-effort encode-search to warning" do
    Telemetry.attach_default_logger(level: :info, stages: true)

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

  test "escalates an encode-search the pixel limit cut short to warning" do
    Telemetry.attach_default_logger(level: :info, stages: true)

    log =
      capture_log(fn ->
        :telemetry.execute(
          [:image_pipe, :encode, :search, :stop],
          %{duration: 1000},
          %{
            result: :ok,
            objective: :ssimulacra2,
            chosen_quality: 70,
            chosen_bytes: 12_345,
            iterations: 3,
            outcome: :hit,
            scorer: :full,
            pixel_limited: true
          }
        )
      end)

    assert log =~ "[warning]"
    assert log =~ "encode search: ok (full hit q70 12345b pixel-limited)"
  end

  test "renders an encode-search probe span stop with its phase, quality, bytes, score" do
    Telemetry.attach_default_logger(level: :info, stages: true)

    log =
      capture_log(fn ->
        :telemetry.execute(
          [:image_pipe, :encode, :search, :probe, :stop],
          %{duration: System.convert_time_unit(1, :millisecond, :native)},
          %{result: :ok, phase: :cap, quality: 65, bytes: 6500, score: 90.42}
        )
      end)

    refute log =~ "[warning]"
    assert log =~ "encode search probe: ok (cap q65 6500b score 90.42)"
  end

  test "renders the delivered-probe chosen marker with quality, bytes, phase, score" do
    Telemetry.attach_default_logger(level: :info, stages: true)

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

  test "renders the ignored options of a request at the base level" do
    Telemetry.attach_default_logger(level: :info, stages: true)

    log =
      capture_log(fn ->
        :telemetry.execute(
          [:image_pipe, :request, :ignored_options],
          %{},
          %{options: ["fit", "enlarge"], locations: [{:group, 0, :fit}, {:group, 0, :enlarge}]}
        )
      end)

    assert log =~ "[info]"
    assert log =~ "request ignored options: ok (fit, enlarge)"
  end

  test "escalates an encode-search probe exception to warning" do
    Telemetry.attach_default_logger(level: :info, stages: true)

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
    Telemetry.attach_default_logger(level: :info, stages: true)

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
    Telemetry.attach_default_logger(level: :info, stages: true)

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

  test "renders the stored body size on cache writes" do
    Telemetry.attach_default_logger(level: :info, stages: true)

    log =
      capture_log(fn ->
        :telemetry.execute(
          [:image_pipe, :cache, :write, :stop],
          %{duration: 1000},
          %{result: :ok, cache: :write, pool: :output, bytes: 12_345}
        )
      end)

    assert log =~ "cache write: stored 12345b"
  end

  test "without stages, logs failed and dropped cache writes but not other cache stages" do
    prefix = [__MODULE__, :cache_failures]
    Telemetry.attach_default_logger(prefix: prefix, level: :info)
    opts = [telemetry_prefix: prefix]

    log =
      capture_log(fn ->
        Telemetry.span(opts, [:cache, :write], %{pool: :input, cache_key: "a"}, fn ->
          {:ok, %{result: :ok, cache: :write, cache_key: "a", bytes: 5}}
        end)

        Telemetry.span(opts, [:cache, :write], %{pool: :input, cache_key: "b"}, fn ->
          {:ok,
           %{result: :cache_error, cache: :write_error, error: :enospc, cache_key: "b", bytes: 7}}
        end)

        assert_raise RuntimeError, fn ->
          Telemetry.span(opts, [:cache, :write], %{pool: :output, cache_key: "c"}, fn ->
            raise "disk gone"
          end)
        end

        for {result, cache, extra} <- [
              {:ok, :stage_abandoned, %{reason: :client_closed}},
              {:ok, :stage_dropped, %{reason: :deadline}},
              {:cache_error, :stage_error, %{error: :eacces}}
            ] do
          Telemetry.execute(
            opts,
            [:cache, :stage],
            %{},
            Map.merge(extra, %{
              result: result,
              cache: cache,
              pool: :input,
              output_format: nil,
              cache_key: "d"
            })
          )
        end
      end)

    assert log =~ "[warning] image_pipe cache write: error (enospc) 7b (input pool)"
    assert log =~ "[warning] image_pipe cache write: exception"
    assert log =~ "[warning] image_pipe cache stage: stage_dropped (deadline) (input pool)"
    assert log =~ "[warning] image_pipe cache stage: stage_error (eacces) (input pool)"
    refute log =~ "stored"
    refute log =~ "stage_abandoned"
  end

  test "a summary line warns about a cache read error and records memory staging at info" do
    prefix = [__MODULE__, :summary_cache_health]
    Telemetry.attach_default_logger(prefix: prefix, level: :info)
    base = %{method: "GET", path: "/w=40/src/a.jpg", status: 200, result: :ok, duration_ms: 3}

    log =
      capture_log(fn ->
        for fields <- [
              %{cache: :read_error},
              %{staging: :memory, staging_reason: :dir}
            ] do
          :telemetry.execute(
            prefix ++ [:request, :summary],
            %{duration: 0},
            Map.merge(base, fields)
          )
        end
      end)

    assert log =~ "[warning] GET /w=40/src/a.jpg 200 3ms cache=read_error"
    assert log =~ "[info] GET /w=40/src/a.jpg 200 3ms staging=memory staging_reason=dir"
  end

  test "a summary line shows the source first, and one field per watermark source" do
    prefix = [__MODULE__, :summary_sources]
    Telemetry.attach_default_logger(prefix: prefix, level: :info)

    log =
      capture_log(fn ->
        :telemetry.execute(prefix ++ [:request, :summary], %{duration: 0}, %{
          method: "GET",
          path: "/wm-src64=REDACTED/-/wm-src64=REDACTED/src/REDACTED",
          status: 200,
          result: :ok,
          duration_ms: 3,
          cache: :miss,
          source_url: "https://o.test/a.jpg?sig=REDACTED",
          watermark_source_urls: ["mark.png", "logo,v2.png"]
        })
      end)

    assert log =~
             "[info] GET /wm-src64=REDACTED/-/wm-src64=REDACTED/src/REDACTED 200 3ms " <>
               ~s(source_url="https://o.test/a.jpg?sig=REDACTED" ) <>
               "watermark_source_url=mark.png watermark_source_url=logo,v2.png cache=miss"
  end

  test "a summary line logs a 4xx at warning and a 5xx or failed stream at error" do
    prefix = [__MODULE__, :summary_levels]
    Telemetry.attach_default_logger(prefix: prefix, level: :info)
    base = %{method: "GET", path: "/w=40/src/a.jpg", result: :processing_error, duration_ms: 3}

    log =
      capture_log(fn ->
        for {status, error} <- [{415, :decode}, {422, :transform}, {500, :encode}, {200, :encode}] do
          :telemetry.execute(
            prefix ++ [:request, :summary],
            %{duration: 0},
            Map.merge(base, %{status: status, error: error})
          )
        end
      end)

    assert log =~ "[warning] GET /w=40/src/a.jpg 415 3ms error=decode"
    assert log =~ "[warning] GET /w=40/src/a.jpg 422 3ms error=transform"
    assert log =~ "[error] GET /w=40/src/a.jpg 500 3ms error=encode"
    assert log =~ "[error] GET /w=40/src/a.jpg 200 3ms error=encode"
  end

  test "renders exception events as exceptions at warning level" do
    Telemetry.attach_default_logger(level: :info, stages: true)

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

  test "bounds the size of an exception reason" do
    Telemetry.attach_default_logger(level: :info, stages: true)
    reason = {:origin, List.duplicate(String.duplicate("x", 10_000), 100)}

    log =
      capture_log(fn ->
        :telemetry.execute(
          [:image_pipe, :source, :fetch, :exception],
          %{duration: 1000},
          %{kind: :error, reason: reason, stacktrace: []}
        )
      end)

    assert log =~ "exception (error {:origin"
    assert byte_size(log) < 7_000
  end

  test "escalates a configured-detector fallback (:unavailable) to warning" do
    Telemetry.attach_default_logger(level: :info, stages: true)

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
    Telemetry.attach_default_logger(level: :info, stages: true)

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
    Telemetry.attach_default_logger(level: :info, stages: true)

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

  test "logs a smart-face fallback's skipped one-shot at warning" do
    Telemetry.attach_default_logger(level: :info, stages: true)

    for {result, message} <- [
          not_ready: "face model not loaded yet",
          unavailable: "face detection unavailable"
        ] do
      log =
        capture_log(fn ->
          :telemetry.execute(
            [:image_pipe, :transform, :detect, :skipped],
            %{},
            %{classes: ["face"], result: result}
          )
        end)

      assert log =~ "[warning]"
      assert log =~ "transform detect: skipped (#{message})"
    end
  end

  test "logs the output clamp one-shot at warning with source -> clamped dims" do
    Telemetry.attach_default_logger(level: :info, stages: true)

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
    Telemetry.attach_default_logger(level: :info, stages: true)

    log =
      capture_log(fn ->
        :telemetry.execute(
          [:image_pipe, :debug, :collect, :error],
          %{},
          %{error: RuntimeError}
        )
      end)

    assert log =~ "[warning]"
    assert log =~ "debug collect: error (RuntimeError)"
  end

  test "logs a normal no-face detect fallback at the base level, not warning" do
    Telemetry.attach_default_logger(level: :info, stages: true)

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
    Telemetry.attach_default_logger(level: :debug, prefix: prefix, stages: true)
    state = %State{image: Image.new!(20, 10, color: :white)}
    resize = %Resize{width: 10, height: 5}

    # capture at :debug explicitly so the test does not depend on the ambient
    # Logger level.
    log =
      capture_log([level: :debug], fn ->
        assert {:ok, %State{}} =
                 Step.run(state, resize, telemetry_prefix: prefix)

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
    Telemetry.attach_default_logger(level: :debug, stages: true)

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
    Telemetry.attach_default_logger(level: :debug, stages: true)

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
    Telemetry.attach_default_logger(level: :info, stages: true)

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
    Telemetry.attach_default_logger(level: :info, stages: true)

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
    Telemetry.attach_default_logger(level: :info, stages: true)

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
    Telemetry.attach_default_logger(level: :info, stages: true)

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
    Telemetry.attach_default_logger(level: :info, stages: true)

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

  test "renders an SVG render's sizes, and a rejected render's limit" do
    Telemetry.attach_default_logger(level: :info, stages: true)

    log =
      capture_log(fn ->
        :telemetry.execute(
          [:image_pipe, :source, :svg_render, :stop],
          %{duration: System.convert_time_unit(2, :millisecond, :native)},
          %{
            result: :ok,
            asset: :original,
            intrinsic_dims: {40, 20},
            rendered_dims: {400, 200},
            images: 2
          }
        )

        :telemetry.execute(
          [:image_pipe, :source, :svg_render, :stop],
          %{duration: System.convert_time_unit(1, :millisecond, :native)},
          %{
            result: :processing_error,
            asset: :watermark,
            error: :input_limit,
            limit: :svg_render_work
          }
        )
      end)

    assert log =~ "source svg_render: ok (original 40x20 rendered at 400x200, 2 images)"

    assert log =~
             "source svg_render: processing_error (watermark, input_limit, svg_render_work limit)"
  end

  test "renders an SVG parse's size, and a rejected parse's limit" do
    Telemetry.attach_default_logger(level: :info, stages: true)

    log =
      capture_log(fn ->
        :telemetry.execute(
          [:image_pipe, :source, :svg_parse, :stop],
          %{duration: System.convert_time_unit(1, :millisecond, :native)},
          %{result: :ok, asset: :watermark, intrinsic_dims: {4, 4}}
        )

        :telemetry.execute(
          [:image_pipe, :source, :svg_parse, :stop],
          %{duration: System.convert_time_unit(1, :millisecond, :native)},
          %{result: :processing_error, asset: :watermark, error: :input_limit, limit: :svg_bytes}
        )
      end)

    assert log =~ "source svg_parse: ok (watermark 4x4)"
    assert log =~ "source svg_parse: processing_error (watermark, input_limit, svg_bytes limit)"
  end

  test "renders a skipped source on the fetch_decode span" do
    Telemetry.attach_default_logger(level: :info, stages: true)

    log =
      capture_log(fn ->
        :telemetry.execute(
          [:image_pipe, :source, :fetch_decode, :stop],
          %{duration: System.convert_time_unit(1, :millisecond, :native)},
          %{result: :ok, skipped: true, detected_source_format: :gif}
        )
      end)

    assert log =~ "source fetch_decode: ok (detected gif, skipped processing)"
  end

  test "renders the detected format on an unsupported-format reject" do
    Telemetry.attach_default_logger(level: :info, stages: true)

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

    assert log =~
             "source fetch_decode: processing_error (unsupported_source_format, detected svg)"
  end

  test "renders the rejected loader on a loader-family mismatch" do
    Telemetry.attach_default_logger(level: :info, stages: true)

    log =
      capture_log(fn ->
        :telemetry.execute(
          [:image_pipe, :source, :fetch_decode, :stop],
          %{duration: System.convert_time_unit(1, :millisecond, :native)},
          %{
            result: :processing_error,
            error: :unsupported_source_format,
            detected_source_format: :tiff,
            source_loader: "dcrawload"
          }
        )
      end)

    assert log =~
             "source fetch_decode: processing_error (unsupported_source_format, detected tiff, loader dcrawload)"
  end

  test "renders the selected page and the page count" do
    Telemetry.attach_default_logger(level: :info, stages: true)

    log =
      capture_log(fn ->
        :telemetry.execute(
          [:image_pipe, :source, :fetch_decode, :stop],
          %{duration: System.convert_time_unit(1, :millisecond, :native)},
          %{result: :processing_error, error: :page_out_of_range, page: 3, source_frames: 3}
        )
      end)

    assert log =~ "source fetch_decode: processing_error (page_out_of_range, page 3, 3 frames)"
  end

  test "renders the frame count and the rejecting input limit on the fetch_decode span" do
    Telemetry.attach_default_logger(level: :info, stages: true)

    log =
      capture_log(fn ->
        :telemetry.execute(
          [:image_pipe, :source, :fetch_decode, :stop],
          %{duration: System.convert_time_unit(2, :millisecond, :native)},
          %{result: :ok, detected_source_format: :webp, source_frames: 3}
        )

        :telemetry.execute(
          [:image_pipe, :source, :fetch_decode, :stop],
          %{duration: System.convert_time_unit(1, :millisecond, :native)},
          %{result: :processing_error, error: :input_limit, limit: :frames}
        )
      end)

    assert log =~ "source fetch_decode: ok (detected webp, 3 frames)"
    assert log =~ "source fetch_decode: processing_error (input_limit, frames limit)"
  end

  test "renders the output negotiate span with its outcome and format" do
    Telemetry.attach_default_logger(level: :info, stages: true)

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

  test "renders a remote source staging failure with its error category" do
    Telemetry.attach_default_logger(level: :info, stages: true)

    log =
      capture_log(fn ->
        :telemetry.execute([:image_pipe, :source, :stage, :stop], %{duration: 1_000}, %{
          result: :source_error,
          error: :receive_timeout
        })
      end)

    assert log =~ "[warning]"
    assert log =~ "source stage: source_error (receive_timeout)"
  end

  test "escalates an output negotiate failure to warning" do
    Telemetry.attach_default_logger(level: :info, stages: true)

    log =
      capture_log(fn ->
        :telemetry.execute(
          [:image_pipe, :output, :negotiate, :stop],
          %{duration: 1000},
          %{result: :output_error, output_mode: :explicit, error: :unsupported}
        )
      end)

    assert log =~ "[warning]"
    assert log =~ "output negotiate: output_error (unsupported)"
  end

  test "renders the preset lookup span and escalates its failures" do
    Telemetry.attach_default_logger(level: :info, stages: true)

    log =
      capture_log(fn ->
        :telemetry.execute(
          [:image_pipe, :preset, :lookup, :stop],
          %{duration: 1000},
          %{result: :ok, fetched: 2, batches: 1}
        )
      end)

    refute log =~ "[warning]"
    assert log =~ "preset lookup: ok (2 fetched, 1 batches)"

    log =
      capture_log(fn ->
        :telemetry.execute(
          [:image_pipe, :preset, :lookup, :stop],
          %{duration: 1000},
          %{result: :error, reason: :lookup_unavailable, fetched: 0, batches: 1}
        )
      end)

    assert log =~ "[warning]"
    assert log =~ "preset lookup: error (lookup_unavailable)"
  end

  test "renders the signing key that verified a request on the parse span" do
    prefix = [__MODULE__, :parse]
    Telemetry.attach_default_logger(prefix: prefix, events: [:parse], level: :info, stages: true)

    log =
      capture_log(fn ->
        for meta <- [%{result: :ok, sig_key_index: 1}, %{result: :ok}] do
          :telemetry.execute(prefix ++ [:parse, :stop], %{duration: 1000}, meta)
        end
      end)

    assert log =~ "image_pipe parse: ok (signing key 1)"
    assert log =~ ~r/image_pipe parse: ok$/m
  end

  test "renders the per-model detect span with its region count and outcome" do
    prefix = [__MODULE__, :model_success]
    Telemetry.attach_default_logger(level: :info, prefix: prefix, stages: true)

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
    Telemetry.attach_default_logger(level: :info, prefix: prefix, stages: true)
    detector = FakeDetector.returning({:error, "private detector reason"})
    composite = [detector]

    log =
      capture_log([level: :warning], fn ->
        Composite.detect(composite, :image, telemetry_opts: [telemetry_prefix: prefix])
      end)

    assert log =~ "transform detect model: error (0 regions"
    refute log =~ "private detector reason"
  end

  test "logs an unavailable composite child as unavailable, not error" do
    prefix = [__MODULE__, :model_unavailable]
    Telemetry.attach_default_logger(level: :info, prefix: prefix, stages: true)
    detector = FakeDetector.returning({:error, {:detector, :unavailable}})

    log =
      capture_log([level: :warning], fn ->
        Composite.detect([detector], :image, telemetry_opts: [telemetry_prefix: prefix])
      end)

    assert log =~ "transform detect model: unavailable (0 regions"
    refute log =~ "detect model: error"
  end

  test "logs the http_cache prepare one-shot at base level with its mode" do
    Telemetry.attach_default_logger(level: :info, stages: true)

    log =
      capture_log(fn ->
        :telemetry.execute(
          [:image_pipe, :http_cache, :prepare],
          %{},
          %{effective_mode: :auto, byte_identity: :strong, etag: true}
        )
      end)

    refute log =~ "[warning]"
    assert log =~ "http_cache prepare: auto"
    assert log =~ "byte_identity strong"
  end

  test "logs the http_cache conditional match one-shot with the method" do
    Telemetry.attach_default_logger(level: :info, stages: true)

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
    Telemetry.attach_default_logger(level: :info, stages: true)

    log =
      capture_log(fn ->
        :telemetry.execute(
          [:image_pipe, :http_cache, :fallback, :no_store],
          %{},
          %{source_name: :web, reason: :detection_failed}
        )
      end)

    refute log =~ "[warning]"
    assert log =~ "http_cache fallback no_store: detection_failed (source web)"
  end

  test "logs the http_cache cache-hit headers one-shot" do
    Telemetry.attach_default_logger(level: :info, stages: true)

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
    Telemetry.attach_default_logger(level: :info, events: [:cache], stages: true)

    log =
      capture_log(fn ->
        :telemetry.execute(
          [:image_pipe, :http_cache, :prepare],
          %{},
          %{effective_mode: :auto, byte_identity: :strong, etag: true}
        )
      end)

    refute log =~ "http_cache"
  end

  test "rejects an invalid log level" do
    assert_raise ArgumentError, fn ->
      Telemetry.attach_default_logger(level: :nope, stages: true)
    end
  end

  test ":events filter excludes other groups" do
    Telemetry.attach_default_logger(level: :info, events: [:cache], stages: true)

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
    Telemetry.attach_default_logger(level: :debug, debug: true, prefix: prefix, stages: true)
    state = %State{image: Image.new!(20, 10, color: :white)}
    resize = %Resize{width: 12, height: 5}

    log =
      capture_log([level: :debug], fn ->
        assert {:ok, %State{}} =
                 Step.run(state, resize, telemetry_prefix: prefix)
      end)

    assert log =~ "raw:"
    assert log =~ "ImagePipe.Transform.Operation.Resize"
    assert log =~ "width: 12"
    assert log =~ "height: 5"
  end

  test ":prefix attaches under a custom event prefix" do
    Telemetry.attach_default_logger(
      level: :info,
      events: [:cache],
      prefix: [:my_app, :images],
      stages: true
    )

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

    assert_raise ArgumentError, fn ->
      Telemetry.attach_default_logger(events: [:nope], stages: true)
    end

    assert_raise ArgumentError, fn ->
      Telemetry.attach_default_logger(prefix: "nope", stages: true)
    end

    assert_raise ArgumentError, fn -> Telemetry.attach_default_logger(debug: :yes) end
  end

  test "invalid configuration leaves the existing logger attached" do
    prefix = [__MODULE__, :invalid_configuration]
    Telemetry.attach_default_logger(prefix: prefix, events: [:cache], stages: true)

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
    Telemetry.attach_default_logger(prefix: prefix, level: :info, debug: true, stages: true)

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
    Telemetry.attach_default_logger(level: :info, stages: true)

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
    Telemetry.attach_default_logger(level: :info, stages: true)

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
