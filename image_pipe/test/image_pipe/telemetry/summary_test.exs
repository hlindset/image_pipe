defmodule ImagePipe.Telemetry.SummaryTest do
  # Attaches the default Logger, whose handler ID is global.
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog
  import Plug.Conn
  import Plug.Test

  alias ImagePipe.SourceTest.RootHTTPAdapter
  alias ImagePipe.Telemetry
  alias ImagePipe.Telemetry.RequestContext
  alias ImagePipe.Telemetry.Summary
  alias ImagePipe.Test.Caches
  alias ImagePipe.Test.DetectorFixtures.FlakyDetector

  setup %{test: test} do
    prefix = [__MODULE__, test]
    root = Path.join(System.tmp_dir!(), "summary-#{System.unique_integer([:positive])}")

    on_exit(fn ->
      Telemetry.detach_default_logger()
      FlakyDetector.reset()
      File.rm_rf!(root)
    end)

    test_pid = self()
    handler = {__MODULE__, make_ref()}

    :ok =
      :telemetry.attach(
        handler,
        prefix ++ [:request, :summary],
        fn _event, measurements, metadata, _ ->
          send(test_pid, {:summary, measurements, metadata})
        end,
        nil
      )

    on_exit(fn -> :telemetry.detach(handler) end)
    %{prefix: prefix, root: root}
  end

  test "a cache miss, a hit, and a 304 each give one summary with their fields", ctx do
    options = start(ctx, cache: [root: Path.join(ctx.root, "output")])
    config = Caches.plug(options)

    miss = request("/w=40/format=png/src/beach.jpg", config, options)
    assert miss.status == 200
    assert_received {:summary, %{duration: _}, summary}

    assert %{
             method: "GET",
             path: "/w=40/format=png/src/beach.jpg",
             status: 200,
             result: :ok,
             cache: :miss,
             source: :path,
             input: :jpeg,
             input_size: {4000, 2667},
             ops: [:resize],
             output: :png,
             output_size: {40, 27}
           } = summary

    assert summary.bytes == byte_size(miss.resp_body)
    assert is_integer(summary.duration_ms) and is_integer(summary.decode_ms)
    refute Map.has_key?(summary, :staging)

    hit = request("/w=40/format=png/src/beach.jpg", config, options)
    assert_received {:summary, _measurements, %{cache: :hit, status: 200} = hit_summary}
    assert hit_summary.bytes == byte_size(hit.resp_body)

    [etag] = get_resp_header(hit, "etag")

    conn(:get, "/w=40/format=png/src/beach.jpg")
    |> put_req_header("if-none-match", etag)
    |> ImagePipe.Plug.call(config)

    assert_received {:summary, _measurements, %{status: 304, cache: :not_modified}}
    refute_received {:summary, _measurements, _metadata}
  end

  test "failures carry the error and the reason the response gives", ctx do
    options = start(ctx)
    config = Caches.plug(options)

    assert request("/w=abc/src/beach.jpg", config, options).status == 400
    assert_received {:summary, _m, %{status: 400, error: :invalid_request, reason: reason}}
    assert reason =~ "invalid value"

    assert request("/w=40/src/missing.jpg", config, options).status == 404

    assert_received {:summary, _m,
                     %{status: 404, result: :source_error, reason: "source not found"}}
  end

  test "an overloaded pool's 503 is summarized as an error line", ctx do
    options = start(ctx, pool: [max_concurrency: 1, max_queue: 0])
    config = Caches.plug(options)
    holder = hold_slot(ImagePipe.Config.fetch_instance!(Caches.instance(options), nil))
    Telemetry.attach_default_logger(prefix: ctx.prefix)

    log =
      capture_log(fn ->
        assert request("/w=40/src/beach.jpg", config, options).status == 503
      end)

    send(holder, :release)
    assert_received {:summary, _m, %{status: 503, admission: :overloaded} = summary}
    refute Map.has_key?(summary, :priority)
    assert log =~ "[error] GET /w=40/src/beach.jpg 503"
    assert log =~ "admission=overloaded"
  end

  test "a low-priority request turned away by a full pool is summarized below warning", ctx do
    options = start(ctx, pool: [max_concurrency: 1, max_queue: 0])
    config = Caches.plug(options)
    holder = hold_slot(ImagePipe.Config.fetch_instance!(Caches.instance(options), nil))
    Telemetry.attach_default_logger(prefix: ctx.prefix)

    log =
      capture_log([level: :warning], fn ->
        assert request("/w=40/priority=low/src/beach.jpg", config, options).status == 503
      end)

    send(holder, :release)

    assert_received {:summary, _m, %{status: 503, admission: :overloaded, priority: :low}}

    refute log =~ "/w=40/priority=low/src/beach.jpg 503"
  end

  test "a degraded crop logs at warning", ctx do
    FlakyDetector.set(:fail?, true)
    options = start(ctx, detector: FlakyDetector)
    config = Caches.plug(options)
    Telemetry.attach_default_logger(prefix: ctx.prefix)

    log =
      capture_log(fn ->
        assert request("/w=50/h=50/fit=cover/detect=car/src/beach.jpg", config, options).status ==
                 200
      end)

    assert_received {:summary, _m, %{status: 200, degraded: true, detect: :error}}
    assert log =~ "[warning] GET /w=50/h=50/fit=cover/detect=car/src/beach.jpg 200"
  end

  test "detection that falls back to attention logs at warning", ctx do
    options = start(ctx, detector: ImagePipe.Test.DetectorFixtures.UnavailableDetector)
    config = Caches.plug(options)
    Telemetry.attach_default_logger(prefix: ctx.prefix)

    log =
      capture_log(fn ->
        assert request("/w=50/h=50/fit=cover/detect=face/src/beach.jpg", config, options).status ==
                 200
      end)

    assert_received {:summary, _m, %{status: 200, detect: :unavailable} = summary}
    refute Map.has_key?(summary, :degraded)
    assert log =~ "[warning] GET /w=50/h=50/fit=cover/detect=face/src/beach.jpg 200"
  end

  test "the default Logger writes one line per request with the fields as metadata", ctx do
    options = start(ctx)
    config = Caches.plug(options)
    Telemetry.attach_default_logger(prefix: ctx.prefix)
    handler = :"summary_test_#{System.unique_integer([:positive])}"
    :ok = :logger.add_handler(handler, __MODULE__, %{config: %{pid: self()}})
    on_exit(fn -> :logger.remove_handler(handler) end)

    log =
      capture_log(fn ->
        assert request("/w=40/format=png/src/beach.jpg", config, options).status == 200
      end)

    # Other tests' lines can land in the capture, so pick out this request's.
    assert [line] =
             log |> String.split("\n") |> Enum.filter(&(&1 =~ "/w=40/format=png/src/beach.jpg"))

    assert line =~ ~r/\[info\] GET \/w=40\/format=png\/src\/beach\.jpg 200 \d+ms [\d.]+kB /
    assert line =~ "source=path"
    assert line =~ "ops=resize"
    assert_received {:log, %{meta: %{image_pipe: %{status: 200, source: :path}}}}
  end

  test "a watermark's source and decode don't replace the main image's", ctx do
    mark = Image.new!(24, 16, color: :red) |> Image.write!(:memory, suffix: ".png")
    marks = fn conn -> conn |> put_resp_content_type("image/png") |> send_resp(200, mark) end

    marks_source = [
      adapter: ImagePipe.Source.HTTP,
      match: [scheme: ["https"]],
      options: [
        allowed_hosts: ["marks.test"],
        address_resolver: fn _ -> {:ok, [{93, 184, 216, 34}]} end,
        req_options: [plug: marks]
      ]
    ]

    options =
      start(ctx,
        watermarks: %{logo: [source: "https://marks.test/mark.png"]},
        extra_sources: [marks: marks_source]
      )

    config = Caches.plug(options)

    assert request("/w=40/wm=logo/format=png/src/beach.jpg", config, options).status == 200
    assert_received {:summary, _m, summary}
    assert %{source: :path, source_fetch: :ok, input: :jpeg, input_size: {4000, 2667}} = summary
  end

  test "a request inside a summarized request keeps the outer summary", ctx do
    builder = ImagePipe.URL.new() |> ImagePipe.URL.group(resize: [width: 10])
    inner_config = ImagePipe.config(telemetry_prefix: [__MODULE__, :inner])
    body = File.read!("priv/static/images/beach.jpg")

    Telemetry.span([telemetry_prefix: ctx.prefix], [:request], %{method: "GET"}, fn ->
      {:ok, _result} = ImagePipe.run(inner_config, builder, {:binary, body})
      Summary.put(%{reason: "outer"})
      {:ok, %{result: :ok}}
    end)

    assert_received {:summary, _m, %{method: "GET", reason: "outer"}}
    assert Summary.current() == nil
  end

  test "a request that raises logs an exception line instead of a summary", ctx do
    Telemetry.attach_default_logger(prefix: ctx.prefix)

    log =
      capture_log(fn ->
        assert_raise RuntimeError, fn ->
          Telemetry.span([telemetry_prefix: ctx.prefix], [:request], %{method: "GET"}, fn ->
            raise "boom"
          end)
        end
      end)

    refute_received {:summary, _m, _metadata}
    assert log =~ "[warning]"
    assert log =~ "boom"
    assert Summary.current() == nil
  end

  test "a signed request records which key verified it", ctx do
    new_key = String.duplicate("b2", 32)
    old_key = String.duplicate("a1", 32)
    options = start(ctx, keys: [new_key, old_key])
    config = Caches.plug(options)
    signed = ImagePipe.URL.sign_path("/w=40/src/beach.jpg", ImagePipe.URL.config(keys: [old_key]))

    assert request(signed, config, options).status == 200
    assert_received {:summary, _m, %{sig_key: 1}}
  end

  test "a response that fails after its headers went out logs at error", ctx do
    body = File.read!("priv/static/images/beach.jpg")
    origin = fn conn -> conn |> put_resp_content_type("image/jpeg") |> send_resp(200, body) end

    # An inline mount takes the encoder seam that fails after the first chunk.
    config =
      [
        telemetry_prefix: ctx.prefix,
        sources: [
          path: [
            adapter: RootHTTPAdapter,
            match: :path,
            options: [root_url: "http://origin.test", req_options: [plug: origin]]
          ]
        ]
      ]
      |> ImagePipe.Plug.init()
      |> Keyword.merge(image_module: ImagePipe.RunTest.LateFailureEncoder)

    Telemetry.attach_default_logger(prefix: ctx.prefix)

    log =
      capture_log(fn ->
        assert_raise ImagePipe.Plug.StreamAbortedError, fn ->
          conn(:get, "/w=40/format=png/src/beach.jpg") |> ImagePipe.Plug.call(config)
        end
      end)

    assert_received {:summary, _m, %{status: 200, result: :processing_error}}
    assert log =~ "[error] GET /w=40/format=png/src/beach.jpg 200"
  end

  test "the input cache's answer is recorded", ctx do
    options =
      start(ctx,
        input_cache: [root: Path.join(ctx.root, "input")],
        extra_sources: [http: http_source()]
      )

    config = Caches.plug(options)

    # The first request finds no stored original, so it doesn't look one up.
    assert request("/w=40/format=png/src/https://origin.test/beach.jpg", config, options).status ==
             200

    assert_received {:summary, _m, first}
    refute Map.has_key?(first, :input_cache)

    assert request("/w=30/format=png/src/https://origin.test/beach.jpg", config, options).status ==
             200

    assert_received {:summary, _m, %{input_cache: :hit}}
  end

  # The test module isn't async, so no other test reads TMPDIR meanwhile.
  test "an original buffered in memory is recorded, and the unusable staging directory warned about once",
       ctx do
    tmp = Path.join(ctx.root, "tmp")
    File.mkdir_p!(tmp)
    File.write!(Path.join(tmp, "image_pipe"), "")
    previous = System.get_env("TMPDIR")
    System.put_env("TMPDIR", tmp)

    on_exit(fn ->
      if previous, do: System.put_env("TMPDIR", previous), else: System.delete_env("TMPDIR")
    end)

    options = start(ctx, extra_sources: [http: http_source()])
    config = Caches.plug(options)
    Telemetry.attach_default_logger(prefix: ctx.prefix)

    log =
      capture_log(fn ->
        for width <- [40, 30] do
          path = "/w=#{width}/src/https://origin.test/beach.jpg"
          assert request(path, config, options).status == 200
        end
      end)

    assert_received {:summary, _m, %{status: 200, staging: :memory, staging_reason: :dir}}
    assert_received {:summary, _m, %{status: 200, staging: :memory, staging_reason: :dir}}
    assert log =~ "[info] GET /w=40/src/https://origin.test/beach.jpg 200"
    assert log =~ "staging=memory staging_reason=dir"

    assert [_once] =
             Regex.scan(
               ~r/\[warning\] image_pipe cache: can't stage originals in .*image_pipe/,
               log
             )
  end

  test "a clamped result, a best-effort quality search, and a missing detector log at warning",
       ctx do
    options = start(ctx, max_result_width: 100, detector: nil)
    config = Caches.plug(options)
    Telemetry.attach_default_logger(prefix: ctx.prefix)

    for {path, fields} <- [
          {"/format=png/src/beach.jpg", %{clamped: {100, 67}}},
          {"/w=40/max-bytes=10/format=jpeg/src/beach.jpg", %{quality_search: :best_effort}},
          {"/crop=20,20/detect=face/format=png/src/beach.jpg", %{detect: :no_detector}}
        ] do
      log = capture_log(fn -> assert request(path, config, options).status == 200 end)
      assert_received {:summary, _m, summary}
      assert Map.take(summary, Map.keys(fields)) == fields, path
      assert log =~ "[warning] GET #{path} 200", path
    end
  end

  test "a quality search records the quality it chose", ctx do
    options = start(ctx)
    config = Caches.plug(options)

    assert request("/w=40/max-bytes=100000/format=jpeg/src/beach.jpg", config, options).status ==
             200

    assert_received {:summary, _m, %{quality_search: :hit, quality: quality}}
    assert is_integer(quality)
  end

  test "ignored options and an unprocessed original are recorded", ctx do
    options = start(ctx, skip_processing_formats: [:jpeg])
    config = Caches.plug(options)

    assert request("/enlarge/src/beach.jpg", config, options).status == 200
    assert_received {:summary, _m, %{ignored: ["enlarge"], skipped: true}}
  end

  test "a client that went away mid-response is recorded", ctx do
    opts = [telemetry_prefix: ctx.prefix]

    Telemetry.span(opts, [:request], %{method: "GET"}, fn ->
      Telemetry.span(opts, [:deliver], %{output_format: :png}, fn ->
        {:ok, %{result: :client_closed}}
      end)

      {:ok, %{result: :ok, status: 200}}
    end)

    assert_received {:summary, _m, %{client_closed: true}}
  end

  test "ImagePipe.run/4 is summarized without a method, path, or status", ctx do
    builder = ImagePipe.URL.new() |> ImagePipe.URL.group(resize: [width: 10])
    config = ImagePipe.config(telemetry_prefix: ctx.prefix)

    assert {:ok, _result} =
             ImagePipe.run(config, builder, {:binary, File.read!("priv/static/images/beach.jpg")})

    assert_received {:summary, _m, %{result: :ok, ops: [:resize]} = summary}
    refute Map.has_key?(summary, :method)
    refute Map.has_key?(summary, :status)
  end

  test "a field sent after the request ends leaves nothing behind", ctx do
    options = start(ctx)
    config = Caches.plug(options)
    test_pid = self()

    :ok =
      :telemetry.attach(
        {__MODULE__, :capture},
        ctx.prefix ++ [:request, :start],
        fn _e, _m, _meta, _ -> send(test_pid, {:context, RequestContext.capture()}) end,
        nil
      )

    on_exit(fn -> :telemetry.detach({__MODULE__, :capture}) end)

    assert request("/w=40/src/beach.jpg", config, options).status == 200
    assert_received {:context, context}
    assert_received {:summary, _m, _summary}

    # A process that outlived the request, sending what it found late.
    task =
      Task.async(fn ->
        RequestContext.adopt(context)
        Summary.put(%{late: true})
      end)

    Task.await(task)
    refute_received {_alias, %{late: true}}
  end

  test "nothing is collected without a summary handler" do
    test_pid = self()

    :ok =
      :telemetry.attach(
        {__MODULE__, :alias},
        [__MODULE__, :unwatched, :request, :start],
        fn _e, _m, _meta, _ -> send(test_pid, {:alias, Summary.current()}) end,
        nil
      )

    on_exit(fn -> :telemetry.detach({__MODULE__, :alias}) end)

    Telemetry.span([telemetry_prefix: [__MODULE__, :unwatched]], [:request], %{}, fn ->
      {:ok, %{result: :ok}}
    end)

    assert_received {:alias, nil}
  end

  test "a presigned source URL in the path is logged with its credentials redacted", ctx do
    options = start(ctx)
    config = Caches.plug(options)

    request(
      "/w=40/src/https%3A%2F%2Forigin.test%2Fbeach.jpg%3FX-Amz-Signature%3Dsecret%26keep%3D1",
      config,
      options
    )

    assert_received {:summary, _m, %{path: path}}
    assert path == "/w=40/src/https://origin.test/beach.jpg?X-Amz-Signature=REDACTED&keep=1"
  end

  test "credentials are redacted however a source spells them" do
    redacted = "/w=40/src/https://b.example/a.jpg?X-Amz-Signature=REDACTED"

    for spelling <- [
          "https%3A%2F%2Fb.example%2Fa.jpg%3FX-Amz-Signature%3Ds",
          "https%3A%2F%2Fb.example%2Fa.jpg%3FX-Amz%2DSignature%3Ds",
          "https%3A%2F%2Fb.example%2Fa.jpg%3Fx-amz-%53ignature%3Ds",
          "https://b.example/a.jpg%3FX-Amz-Signature%3Ds"
        ] do
      assert String.downcase(Telemetry.request_path("/w=40/src/" <> spelling, "")) ==
               String.downcase(redacted),
             spelling
    end

    assert Telemetry.request_path(
             "/w=40/src/https://b/a.jpg%3FX-Amz-Credential%3DAKIA/2026/s3%3Bsig%3Ds",
             ""
           ) == "/w=40/src/https://b/a.jpg?X-Amz-Credential=REDACTED;sig=REDACTED"

    presigned = "https://b.example/a.jpg?X-Goog-Credential=s"

    for token <- [
          Base.url_encode64(presigned, padding: false),
          Base.url_encode64(presigned),
          Base.encode64(presigned),
          Base.url_encode64(presigned, padding: false) <> ".jpg"
        ] do
      assert Telemetry.request_path("/w=40/src64/" <> token, "") == "/w=40/src64/REDACTED", token

      assert Telemetry.request_path("/wm-src64=#{token}/w=40/src/a.jpg", "") ==
               "/wm-src64=REDACTED/w=40/src/a.jpg",
             token
    end
  end

  test "sources without credentials, and ImagePipe's own signature, are logged as sent" do
    plain = Base.url_encode64("https://b.example/a.jpg?keep=1", padding: false)

    for path <- [
          "/sig=abc/w=40/src/https%3A%2F%2Fb.example%2Fa.jpg%3Fkeep%3D1",
          "/w=40/src64/" <> plain,
          "/w=40/enc/AQRTMotByNyaz"
        ] do
      assert Telemetry.request_path(path, "") == path
    end
  end

  test "credential query values are redacted from the query string" do
    assert Telemetry.request_path(
             "/w=40/src/https://bucket.example/a.jpg",
             "X-Amz-Signature=abc&x-amz-credential=key&sig=s&keep=1"
           ) ==
             "/w=40/src/https://bucket.example/a.jpg?" <>
               "X-Amz-Signature=REDACTED&x-amz-credential=REDACTED&sig=REDACTED&keep=1"

    assert Telemetry.request_path("/w=40/src/a.jpg", "") == "/w=40/src/a.jpg"
  end

  # A `:logger` handler that sends this test each event, to read its metadata.
  def log(event, %{config: %{pid: pid}}), do: send(pid, {:log, event})

  defp start(ctx, options \\ []) do
    body = File.read!("priv/static/images/beach.jpg")
    {extra_sources, options} = Keyword.pop(options, :extra_sources, [])

    origin = fn conn ->
      case conn.path_info do
        ["beach.jpg"] ->
          conn |> put_resp_content_type("image/jpeg") |> send_resp(200, body)

        _other ->
          send_resp(conn, 404, "")
      end
    end

    Caches.start!(
      [
        telemetry_prefix: ctx.prefix,
        http_cache: :auto,
        sources:
          [
            path: [
              adapter: RootHTTPAdapter,
              match: :path,
              options: [
                root_url: "http://origin.test",
                byte_identity: :strong,
                req_options: [plug: origin]
              ]
            ]
          ] ++ extra_sources,
        max_input_pixels: 40_000_000
      ] ++ options
    )
  end

  # An HTTP source for `https://origin.test/`, whose originals are kept.
  defp http_source do
    body = File.read!("priv/static/images/beach.jpg")

    origin = fn conn ->
      conn
      |> put_resp_header("cache-control", "public, max-age=60")
      |> put_resp_content_type("image/jpeg")
      |> send_resp(200, body)
    end

    [
      adapter: ImagePipe.Source.HTTP,
      match: [scheme: ["https"]],
      options: [
        allowed_hosts: ["origin.test"],
        address_resolver: fn _ -> {:ok, [{93, 184, 216, 34}]} end,
        req_options: [plug: origin]
      ]
    ]
  end

  defp request(path, config, options) do
    conn = conn(:get, path) |> ImagePipe.Plug.call(config)
    Caches.await_writes(options)
    conn
  end

  defp hold_slot(instance_config) do
    pool = instance_config.options[:processing_pool]
    test_pid = self()

    start_supervised!(
      {Task,
       fn ->
         ImagePipe.ProcessingPool.run(
           pool,
           fn ->
             send(test_pid, {:holding, self()})
             receive(do: (:release -> :ok))
           end,
           []
         )
       end}
    )

    assert_receive {:holding, holder}
    holder
  end
end
