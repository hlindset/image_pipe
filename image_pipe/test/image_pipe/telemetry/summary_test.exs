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
             path: "/w=40/format=png/src/REDACTED",
             source_url: "beach.jpg",
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

  test "a HEAD cache miss sends and counts no body bytes", ctx do
    options = start(ctx, cache: [root: Path.join(ctx.root, "output")])
    config = Caches.plug(options)

    head = conn(:head, "/w=40/format=png/src/beach.jpg") |> ImagePipe.Plug.call(config)
    Caches.await_writes(options)
    assert head.status == 200
    assert head.resp_body == ""
    assert_received {:summary, _measurements, %{cache: :miss} = summary}
    assert Map.get(summary, :bytes, 0) == 0
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

  test "an invalid source URL is a parser error with the reason the response gives", ctx do
    options = start(ctx)
    config = Caches.plug(options)

    assert request("/w=40/src/ftp://origin.test/beach.jpg", config, options).status == 400

    assert_received {:summary, _m,
                     %{
                       status: 400,
                       result: :parser_error,
                       error: :invalid_source,
                       reason: "invalid source"
                     }}
  end

  test "a URL naming too many presets is a parser error", ctx do
    lookup = {ImagePipe.Test.PresetLookup, presets: %{"a" => "w=30", "b" => "blur=1"}}
    options = start(ctx, preset_lookup: lookup, max_preset_lookups: 1)
    config = Caches.plug(options)

    assert request("/preset=a,b/src/beach.jpg", config, options).status == 400

    assert_received {:summary, _m,
                     %{status: 400, result: :parser_error, reason: "too many presets"}}
  end

  test "client errors log at warning", ctx do
    options = start(ctx, max_input_pixels: 100)
    config = Caches.plug(options)
    Telemetry.attach_default_logger(prefix: ctx.prefix)

    log =
      capture_log(fn ->
        assert request("/w=40/src/ftp://origin.test/beach.jpg", config, options).status == 400
        assert request("/w=40/src/notimage.jpg", config, options).status == 415
        assert request("/w=40/src/beach.jpg", config, options).status == 413
      end)

    assert log =~
             ~r"\[warning\] GET /w=40/src/REDACTED 400 .* source_url=ftp://origin.test/beach.jpg "

    assert log =~ ~r"\[warning\] GET /w=40/src/REDACTED 415 .* source_url=notimage.jpg "
    assert log =~ ~r"\[warning\] GET /w=40/src/REDACTED 413 .* source_url=beach.jpg "
    refute log =~ "[error]"
  end

  test "an overloaded pool's 503 is summarized as an error line", ctx do
    options = start(ctx, pool: [max_concurrency: 1, max_queue: 0])
    config = Caches.plug(options)
    holder = hold_slot(ImagePipe.Config.fetch_instance!(Caches.instance(options)))
    Telemetry.attach_default_logger(prefix: ctx.prefix)

    log =
      capture_log(fn ->
        assert request("/w=40/src/beach.jpg", config, options).status == 503
      end)

    send(holder, :release)
    assert_received {:summary, _m, %{status: 503, admission: :overloaded} = summary}
    refute Map.has_key?(summary, :priority)
    assert log =~ "[error] GET /w=40/src/REDACTED 503"
    assert log =~ "admission=overloaded"
  end

  test "a low-priority request turned away by a full pool is summarized below warning", ctx do
    options = start(ctx, pool: [max_concurrency: 1, max_queue: 0])
    config = Caches.plug(options)
    holder = hold_slot(ImagePipe.Config.fetch_instance!(Caches.instance(options)))
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
    assert log =~ "[warning] GET /w=50/h=50/fit=cover/detect=car/src/REDACTED 200"
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
    assert log =~ "[warning] GET /w=50/h=50/fit=cover/detect=face/src/REDACTED 200"
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
             log |> String.split("\n") |> Enum.filter(&(&1 =~ "/w=40/format=png/src/REDACTED"))

    assert line =~
             ~r/\[info\] GET \/w=40\/format=png\/src\/REDACTED 200 \d+ms [\d.]+kB source_url=beach\.jpg /

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
    inner_config = ImagePipe.config(allow_unsigned: true, telemetry_prefix: [__MODULE__, :inner])
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
      |> Keyword.put_new(:allow_unsigned, true)
      |> Keyword.put_new(:allow_unsigned, true)
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
    assert log =~ "[error] GET /w=40/format=png/src/REDACTED 200"
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

    assert log =~
             ~r"\[info\] GET /w=40/src/REDACTED 200 \S+ \S+ source_url=https://origin.test/beach.jpg "

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
      assert log =~ "[warning] GET #{String.replace(path, "beach.jpg", "REDACTED")} 200", path
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
    config = ImagePipe.config(allow_unsigned: true, telemetry_prefix: ctx.prefix)

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

  test "the path ends at the source, which is shown parsed with its credentials redacted", ctx do
    options = start(ctx, extra_sources: [http: http_source()])
    config = Caches.plug(options)

    request(
      "/w=40/src/https%3A%2F%2Forigin.test%2Fbeach.jpg%3FX-Amz-Signature%3Dsecret%26keep%3D1",
      config,
      options
    )

    assert_received {:summary, _m, summary}
    assert summary.path == "/w=40/src/REDACTED"
    assert summary.source_url == "https://origin.test/beach.jpg?X-Amz-Signature=REDACTED&keep=1"
    refute Map.has_key?(summary, :watermark_source_urls)
  end

  test "a src64 source is shown decoded and an enc source decrypted", ctx do
    options =
      start(ctx,
        keys: [String.duplicate("a1", 32)],
        source_encryption_keys: [String.duplicate("2a49", 16)]
      )

    config = Caches.plug(options)
    instance = Caches.options(options)
    {:ok, token} = ImagePipe.Security.encrypt_source("beach.jpg?sig=s", instance, [])

    for tail <- [
          "src64/" <> Base.url_encode64("beach.jpg?sig=s", padding: false),
          "enc/" <> token
        ] do
      path = "/w=40/" <> tail
      signature = ImagePipe.Security.sign(path, instance)
      request("/sig=#{signature}" <> path, config, options)

      assert_received {:summary, _m, summary}
      marker = hd(String.split(tail, "/"))
      assert summary.path == "/sig=#{signature}/w=40/#{marker}/REDACTED"
      assert summary.source_url == "beach.jpg?sig=REDACTED"
    end
  end

  test "each group's watermark source is listed", ctx do
    options = start(ctx, request_watermarks: true)
    config = Caches.plug(options)
    first = Base.url_encode64("mark.png?sig=s", padding: false)
    second = Base.url_encode64("logo.png", padding: false)

    request("/wm-src64=#{first}/w=40/-/wm-src64=#{second}/src/beach.jpg", config, options)

    assert_received {:summary, _m, summary}
    assert summary.path == "/wm-src64=REDACTED/w=40/-/wm-src64=REDACTED/src/REDACTED"
    assert summary.watermark_source_urls == ["mark.png?sig=REDACTED", "logo.png"]
  end

  test "a request that doesn't parse has no source fields", ctx do
    options = start(ctx)
    config = Caches.plug(options)

    request("/w=40/bogus=1/src/beach.jpg", config, options)

    assert_received {:summary, _m, summary}
    assert summary.path == "/w=40/bogus=1/src/REDACTED"
    refute Map.has_key?(summary, :source_url)
    refute Map.has_key?(summary, :watermark_source_urls)
  end

  test "a mounted request's path includes the mount path", ctx do
    options = start(ctx)
    config = Caches.plug(options)
    conn = conn(:get, "/img/w=40/src/beach.jpg")

    Plug.forward(conn, tl(conn.path_info), ImagePipe.Plug, config)
    Caches.await_writes(options)

    assert_received {:summary, _m, %{path: "/img/w=40/src/REDACTED", source_url: "beach.jpg"}}
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

        ["notimage.jpg"] ->
          conn |> put_resp_content_type("image/jpeg") |> send_resp(200, "not an image")

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
      ]
      |> Keyword.merge(options)
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
