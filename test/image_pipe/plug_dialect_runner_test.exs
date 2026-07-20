defmodule ImagePipe.PlugDialectRunnerTest do
  use ExUnit.Case, async: true
  import Plug.Test
  import Plug.Conn

  alias ImagePipe.SourceTest.RootHTTPAdapter
  alias ImagePipe.Test.RunnerFixtureDialect
  alias ImgproxyWireConformanceTest.CacheProbe
  alias ImgproxyWireConformanceTest.CountingOriginImage
  alias ImgproxyWireConformanceTest.OriginImage
  alias ImgproxyWireConformanceTest.OriginShouldNotFetch

  @sources [
    path:
      {RootHTTPAdapter,
       root_url: "http://origin.test", byte_identity: :strong, req_options: [plug: OriginImage]}
  ]

  defp counting_sources do
    [
      path:
        {RootHTTPAdapter,
         root_url: "http://origin.test",
         byte_identity: :strong,
         req_options: [plug: {CountingOriginImage, test_pid: self()}]}
    ]
  end

  defp should_not_fetch_sources do
    [
      path:
        {RootHTTPAdapter,
         root_url: "http://origin.test",
         byte_identity: :strong,
         req_options: [plug: OriginShouldNotFetch]}
    ]
  end

  # A fresh ETS-backed CacheProbe store: makes lookups/commits stateful
  # (real miss-then-hit round trips) rather than the stateless default (see
  # CacheProbe's module doc).
  defp stateful_cache_probe do
    table = :ets.new(:runner_wire_cache_probe, [:set, :public])
    {CacheProbe, store: table}
  end

  defp opts(extra \\ []) do
    base =
      ImagePipe.Plug.init(
        Keyword.merge([dialect: RunnerFixtureDialect, sources: @sources], extra)
      )

    Keyword.merge(base, output_capabilities: %{avif: true, webp: true, jpeg_xl: true})
  end

  defp get(path, config, headers \\ []) do
    conn = conn(:get, path)
    conn = Enum.reduce(headers, conn, fn {k, v}, c -> put_req_header(c, k, v) end)
    ImagePipe.Plug.call(conn, config)
  end

  test "serves an image with an ETag through the dialect mode" do
    conn = get("/fix/images/beach.jpg?format=webp", opts())

    assert conn.status == 200
    assert get_resp_header(conn, "content-type") |> hd() =~ "image/webp"
    assert [etag] = get_resp_header(conn, "etag")
    assert is_binary(etag)
  end

  test "parse errors render through the dialect's render_error" do
    conn = get("/fix/images/beach.jpg?boom=parse", opts())
    assert conn.status == 422
    assert conn.resp_body == "fixture parse reject"
  end

  test "OPTIONS answers 204 and non-GET/HEAD answers 405" do
    assert ImagePipe.Plug.call(conn(:options, "/fix/x.jpg"), opts()).status == 204
    assert ImagePipe.Plug.call(conn(:post, "/fix/x.jpg"), opts()).status == 405
  end

  test "matching If-None-Match returns 304 before any source fetch" do
    config = opts(sources: should_not_fetch_sources())
    first = get("/fix/images/beach.jpg?format=webp", opts())
    [etag] = get_resp_header(first, "etag")

    conn = get("/fix/images/beach.jpg?format=webp", config, [{"if-none-match", etag}])
    assert conn.status == 304
    assert conn.resp_body == ""
  end

  test "miss then hit round trip through the internal cache" do
    config = opts(cache: stateful_cache_probe(), sources: counting_sources())

    miss = get("/fix/images/beach.jpg?format=webp", config)
    assert miss.status == 200
    assert_received :origin_fetch

    hit = get("/fix/images/beach.jpg?format=webp", config)
    assert hit.status == 200
    assert hit.resp_body == miss.resp_body
    refute_received :origin_fetch
  end

  test "If-None-Match: * is honored only on a cache hit" do
    config = opts(cache: stateful_cache_probe(), sources: counting_sources())

    # No entry yet: wildcard proceeds (200, generation happens).
    first = get("/fix/images/beach.jpg?format=webp", config, [{"if-none-match", "*"}])
    assert first.status == 200
    assert_received :origin_fetch

    # Entry exists: wildcard answers 304 without regeneration.
    second = get("/fix/images/beach.jpg?format=webp", config, [{"if-none-match", "*"}])
    assert second.status == 304
    refute_received :origin_fetch
  end

  test "negotiation failure surfaces after source resolution, source failure wins when both fail" do
    # capable source + incapable format -> negotiation error (415)
    conn = get("/fix/images/beach.jpg?format=bmp", opts())
    assert conn.status == 415

    # A config with NO adapter for the :path source kind makes Source.resolve
    # itself fail ({:source, :missing_adapter}) — a genuine resolve-time
    # error, needing no custom adapter. With the incapable format on the
    # same request, the SOURCE error must win (the runner unwraps the
    # deferred negotiation only after resolve succeeds): 404 via the
    # fixture's {:source, _} render_error clause, not 415.
    conn = get("/fix/images/beach.jpg?format=bmp", opts(sources: []))
    assert conn.status == 404
  end

  test "classify_error shapes the [:request] stop result" do
    prefix = [:runner_fixture_classify]
    handler = "runner-fixture-classify-#{inspect(self())}"

    :telemetry.attach(
      handler,
      prefix ++ [:request, :stop],
      fn _event, _measurements, metadata, pid -> send(pid, {:request_stop, metadata}) end,
      self()
    )

    on_exit(fn -> :telemetry.detach(handler) end)

    get("/fix/images/beach.jpg?boom=parse", opts(telemetry_prefix: prefix))
    assert_received {:request_stop, %{result: :parser_error}}
  end
end
