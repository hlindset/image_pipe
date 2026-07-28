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

  defmodule Origin503 do
    @moduledoc false
    def init(opts), do: opts

    def call(conn, opts) do
      opts |> Keyword.fetch!(:test_pid) |> send(:origin_fetch)
      Plug.Conn.send_resp(conn, 503, "origin 503")
    end
  end

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

  defp failing_origin_sources do
    [
      path:
        {RootHTTPAdapter,
         root_url: "http://origin.test",
         byte_identity: :strong,
         req_options: [plug: {Origin503, test_pid: self()}]}
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

  test "a source resolve failure skips negotiation entirely" do
    conn = get("/fix/images/beach.jpg?format=webp", opts(sources: []))
    assert conn.status == 404
    refute_received :negotiation_invoked
  end

  test "negotiation runs once after a successful source resolution" do
    conn = get("/fix/images/beach.jpg?format=webp", opts())
    assert conn.status == 200
    assert_received :negotiation_invoked
    refute_received :negotiation_invoked
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

  test "debug facts are stored with the entry and replayed on hit only when enabled" do
    cache = stateful_cache_probe()

    # Generated with rendering OFF: no debug headers, but the entry stores facts.
    off = get("/fix/images/beach.jpg?format=webp&debug=1", opts(cache: cache))
    assert off.status == 200
    assert get_resp_header(off, "x-imagepipe-source-format") == []

    # Same mount with rendering ON: the hit replays the STORED facts.
    on =
      get(
        "/fix/images/beach.jpg?format=webp&debug=1",
        opts(cache: cache, allow_debug_headers: true)
      )

    assert on.status == 200
    assert get_resp_header(on, "x-imagepipe-cache") == ["hit"]
    assert get_resp_header(on, "x-imagepipe-source-format") == ["jpeg"]
    assert [timing] = get_resp_header(on, "server-timing")
    assert timing =~ "cache;dur="
  end

  test "a debug miss renders measured timings and the six source facts" do
    conn = get("/fix/images/beach.jpg?format=webp&debug=1", opts(allow_debug_headers: true))

    assert conn.status == 200
    assert get_resp_header(conn, "x-imagepipe-cache") == ["miss"]
    assert [timing] = get_resp_header(conn, "server-timing")
    assert timing =~ "decode;dur=" and timing =~ "transform;dur=" and timing =~ "encode;dur="
    assert get_resp_header(conn, "x-imagepipe-source-size") != []
    assert get_resp_header(conn, "x-imagepipe-source-color-space") != []
  end

  test "complete-body render terminal: generate, cache, hit, wildcard" do
    config = opts(cache: stateful_cache_probe(), sources: counting_sources())

    first = get("/fix/images/beach.jpg?render=text", config)
    assert first.status == 200
    assert first.resp_body == "fixture-body"
    assert get_resp_header(first, "content-type") |> hd() =~ "text/plain"
    assert [_etag] = get_resp_header(first, "etag")

    hit = get("/fix/images/beach.jpg?render=text", config)
    assert hit.status == 200
    assert hit.resp_body == "fixture-body"

    wildcard = get("/fix/images/beach.jpg?render=text", config, [{"if-none-match", "*"}])
    assert wildcard.status == 304
  end

  test "a delivery failure under automatic output carries the policy's Vary header" do
    conn = get("/fix/images/beach.jpg?format=auto", opts(sources: failing_origin_sources()))

    assert_received :origin_fetch
    # The fixture renders {:source, _} as 404; the status is the fixture's
    # choice — the assertion is the header.
    assert conn.status == 404
    assert get_resp_header(conn, "vary") == ["Accept"]
  end

  test "a delivery failure under explicit output carries no policy headers" do
    conn = get("/fix/images/beach.jpg?format=webp", opts(sources: failing_origin_sources()))

    assert_received :origin_fetch
    assert conn.status == 404
    assert get_resp_header(conn, "vary") == []
  end

  describe "render terminal with cache: :none" do
    test "negotiates the offered content type against the request's Accept and varies" do
      conn =
        :get
        |> conn("/fix/images/beach.jpg?render=uncached")
        |> put_req_header("accept", "application/ld+json")
        |> ImagePipe.Plug.call(opts())

      assert conn.status == 200
      assert hd(get_resp_header(conn, "content-type")) =~ "application/ld+json"
      assert get_resp_header(conn, "vary") == ["Accept"]
    end

    test "falls back to the canonical content type without a matching Accept" do
      conn = get("/fix/images/beach.jpg?render=uncached", opts())

      assert conn.status == 200
      assert hd(get_resp_header(conn, "content-type")) =~ "application/json"
      assert get_resp_header(conn, "vary") == ["Accept"]
    end

    test "never reads or writes the internal cache" do
      config = opts(cache: stateful_cache_probe())

      assert get("/fix/images/beach.jpg?render=uncached", config).status == 200
      assert get("/fix/images/beach.jpg?render=uncached", config).status == 200

      refute_received {:cache_lookup, _key}
      refute_received {:cache_put, _key, _body}
    end
  end

  describe "http_cache: :generated" do
    test "generates Cache-Control and the representation ETag, and round-trips a 304" do
      config = opts(http_cache: [mode: :enabled])
      conn = get("/fix/images/beach.jpg?http_cache=generated", config)

      assert conn.status == 200
      assert get_resp_header(conn, "cache-control") == ["public, max-age=31536000, immutable"]
      assert [etag] = get_resp_header(conn, "etag")

      revalidated =
        :get
        |> conn("/fix/images/beach.jpg?http_cache=generated")
        |> put_req_header("if-none-match", etag)
        |> ImagePipe.Plug.call(config)

      assert revalidated.status == 304
    end

    test "suppressing the ETag also vetoes the 304" do
      etag =
        "/fix/images/beach.jpg?http_cache=generated"
        |> get(opts(http_cache: [mode: :enabled]))
        |> get_resp_header("etag")
        |> hd()

      conn =
        :get
        |> conn("/fix/images/beach.jpg?http_cache=generated")
        |> put_req_header("if-none-match", etag)
        |> ImagePipe.Plug.call(opts(http_cache: [mode: :disabled]))

      assert conn.status == 200
      assert get_resp_header(conn, "etag") == []
    end

    test "dialect_owned emits the representation ETag and no policy events" do
      prefix = [:runner_dialect_owned_test]
      attach_forwarding_handler(prefix ++ [:http_cache, :prepare])
      attach_forwarding_handler(prefix ++ [:http_cache, :conditional, :match])
      attach_forwarding_handler(prefix ++ [:http_cache, :fallback, :no_store])

      conn = get("/fix/images/beach.jpg", opts(telemetry_prefix: prefix))

      assert [_etag] = get_resp_header(conn, "etag")
      # Plug's own untouched default — no generated Cache-Control was added.
      assert get_resp_header(conn, "cache-control") == ["max-age=0, private, must-revalidate"]
      refute_received {:telemetry, _, _, _}
    end
  end

  defp attach_forwarding_handler(event) do
    handler = {__MODULE__, event, self()}
    test_pid = self()

    :telemetry.attach(
      handler,
      event,
      fn name, measurements, metadata, _config ->
        send(test_pid, {:telemetry, name, measurements, metadata})
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler) end)
  end
end
