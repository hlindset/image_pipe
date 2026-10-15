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
    assert_received {:summary, _m, %{status: 503, admission: :overloaded}}
    assert log =~ "[error] GET /w=40/src/beach.jpg 503"
    assert log =~ "admission=overloaded"
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

    assert path ==
             "/w=40/src/https%3A%2F%2Forigin.test%2Fbeach.jpg%3FX-Amz-Signature%3DREDACTED%26keep%3D1"
  end

  test "credential values are redacted from the path and the query" do
    assert Telemetry.request_path(
             "/w=40/src/https%3A%2F%2Fb.example%2Fa.jpg%3FX-Amz-Credential%3DAKIA%252F1%26sig%3Ds",
             ""
           ) ==
             "/w=40/src/https%3A%2F%2Fb.example%2Fa.jpg%3FX-Amz-Credential%3DREDACTED%26sig%3DREDACTED"

    # ImagePipe's own signature segment isn't a credential parameter.
    assert Telemetry.request_path("/sig=abc/w=40/src/a.jpg", "") == "/sig=abc/w=40/src/a.jpg"

    presigned = Base.url_encode64("https://b.example/a.jpg?X-Amz-Signature=s", padding: false)
    plain = Base.url_encode64("https://b.example/a.jpg?keep=1", padding: false)
    assert Telemetry.request_path("/w=40/src64/" <> presigned, "") == "/w=40/src64/REDACTED"
    assert Telemetry.request_path("/w=40/src64/" <> plain, "") == "/w=40/src64/" <> plain
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

    origin = fn conn ->
      case conn.path_info do
        ["beach.jpg"] -> conn |> put_resp_content_type("image/jpeg") |> send_resp(200, body)
        _other -> send_resp(conn, 404, "")
      end
    end

    Caches.start!(
      [
        telemetry_prefix: ctx.prefix,
        http_cache: :auto,
        sources: [
          path: [
            adapter: RootHTTPAdapter,
            match: :path,
            options: [
              root_url: "http://origin.test",
              byte_identity: :strong,
              req_options: [plug: origin]
            ]
          ]
        ],
        max_input_pixels: 40_000_000
      ] ++ options
    )
  end

  defp request(path, config, options) do
    conn = conn(:get, path) |> ImagePipe.Plug.call(config)
    Caches.await_writes(options)
    conn
  end

  defp hold_slot(instance_config) do
    pool = instance_config.options[:processing_pool]
    test_pid = self()

    Task.start_link(fn ->
      ImagePipe.ProcessingPool.run(
        pool,
        fn ->
          send(test_pid, {:holding, self()})
          receive(do: (:release -> :ok))
        end,
        []
      )
    end)

    assert_receive {:holding, holder}
    holder
  end
end
