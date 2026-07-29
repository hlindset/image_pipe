defmodule ImagePipe.Dialect.ImgproxyWireSmokeTest do
  use ExUnit.Case, async: true

  import Plug.Conn
  import Plug.Test

  alias ImagePipe.Dialect.Imgproxy
  alias ImagePipe.SourceTest.RootHTTPAdapter
  alias ImgproxyWireConformanceTest.CacheProbe
  alias ImgproxyWireConformanceTest.CountingOriginImage
  alias ImgproxyWireConformanceTest.OriginImage
  alias ImgproxyWireConformanceTest.OriginShouldNotFetch

  @signing_key "746573742d6b6579"
  @signing_salt "746573742d73616c74"

  @default_sources [
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

  # A fresh ETS-backed CacheProbe store makes lookups/commits stateful (a real
  # miss-then-hit round trip) rather than the stateless default.
  defp stateful_cache_probe do
    table = :ets.new(:imgproxy_wire_smoke_cache_probe, [:set, :public])
    {CacheProbe, store: table}
  end

  # `output_capabilities` is an internal test-injection seam, appended AFTER
  # `ImagePipe.Plug.init/1`'s validation (which rejects it as an unknown
  # option).
  defp opts(extra) do
    base =
      ImagePipe.Plug.init(
        [dialect: Imgproxy] ++ Keyword.merge([sources: @default_sources], extra)
      )

    Keyword.merge(base, output_capabilities: %{avif: true, webp: true, jpeg_xl: true})
  end

  defp opts, do: opts([])

  defp get(path, config, headers \\ []) do
    conn = conn(:get, path)
    conn = Enum.reduce(headers, conn, fn {k, v}, c -> put_req_header(c, k, v) end)
    ImagePipe.Plug.call(conn, config)
  end

  defp decoded_dims(body) do
    {:ok, image} = Image.from_binary(body)
    {Image.width(image), Image.height(image)}
  end

  # ── happy path ──────────────────────────────────────────────────────────

  describe "GET /unsafe/rs:fit:100:100/plain/images/beach.jpg" do
    test "200, image body, decoded to fit a 100x100 box, jpeg content type" do
      conn = get("/unsafe/rs:fit:100:100/plain/images/beach.jpg", opts())

      assert conn.status == 200
      assert {width, height} = decoded_dims(conn.resp_body)
      assert max(width, height) == 100
      assert get_resp_header(conn, "content-type") == ["image/jpeg"]
    end
  end

  # ── option-order equivalence ────────────────────────────────────────────

  describe "option order does not change the response" do
    test "w:100/h:80 and h:80/w:100 produce byte-identical bodies and equal ETags" do
      config = opts()

      conn_a = get("/unsafe/w:100/h:80/plain/images/beach.jpg", config)
      conn_b = get("/unsafe/h:80/w:100/plain/images/beach.jpg", config)

      assert conn_a.status == 200
      assert conn_b.status == 200
      assert conn_a.resp_body == conn_b.resp_body
      assert get_resp_header(conn_a, "etag") == get_resp_header(conn_b, "etag")
    end
  end

  # ── signature ───────────────────────────────────────────────────────────

  describe "signature" do
    test "an invalid signature is 403 before any source fetch" do
      config =
        opts(
          signature: [keys: [@signing_key], salts: [@signing_salt]],
          sources: should_not_fetch_sources()
        )

      conn = get("/invalidsig/rs:fit:100:100/plain/images/beach.jpg", config)

      assert conn.status == 403
      assert conn.resp_body == "invalid image request: :invalid_signature"
    end

    test "the unsigned `unsafe` marker is rejected once keys are configured" do
      config =
        opts(
          signature: [keys: [@signing_key], salts: [@signing_salt]],
          sources: should_not_fetch_sources()
        )

      conn = get("/unsafe/rs:fit:100:100/plain/images/beach.jpg", config)

      assert conn.status == 403
    end
  end

  # ── expires gate ────────────────────────────────────────────────────────

  describe "expires gate" do
    test "a past exp: is 400 with the pinned body, before any source fetch" do
      config =
        opts(
          clock: fn -> DateTime.from_unix!(101) end,
          sources: counting_sources()
        )

      conn = get("/unsafe/exp:100/rs:fit:100:100/plain/images/beach.jpg", config)

      assert conn.status == 400
      assert conn.resp_body == "invalid image request: {:expired_request, 100}"
      refute_received :origin_fetch
    end

    test "a future exp: passes the gate" do
      config = opts(clock: fn -> DateTime.from_unix!(100) end)
      conn = get("/unsafe/exp:1000/rs:fit:100:100/plain/images/beach.jpg", config)

      assert conn.status == 200
    end
  end

  # ── request-safety boundary: planner rejection is PRE-fetch ─────────────
  #
  # `Assembly.operations/1` is a pure function of the request, so the chain
  # must run it before the source fetch and the cache lookup: AGENTS.md's
  # request-safety guideline requires parser/planner validation failures to
  # return "before source fetch or cache access".
  #
  # The discriminating signal is `CountingOriginImage`'s `:origin_fetch`
  # message: the positive control below proves it fires for a request that
  # DOES reach the origin through this exact config, so `refute_received`
  # here is a real observation, not a vacuous one.

  describe "planner rejection never reaches source or cache" do
    setup do
      {:ok, config: opts(sources: counting_sources(), cache: {CacheProbe, []})}
    end

    test "positive control: a valid request through this config DOES fetch and DOES look up the cache",
         %{config: config} do
      conn = get("/unsafe/rs:fit:100:100/plain/images/beach.jpg", config)

      assert conn.status == 200
      assert_received :origin_fetch
      assert_received {:cache_lookup, _key}
    end

    test "rs:fill with no dimensions is a 400 that never fetches the source", %{config: config} do
      conn = get("/unsafe/rs:fill/plain/images/beach.jpg", config)

      assert conn.status == 400
      assert conn.resp_body == "invalid image request: {:missing_dimensions, :fill}"
      refute_received :origin_fetch
      refute_received {:cache_lookup, _key}
    end

    test "rs:auto with only one dimension is a 400 that never fetches the source", %{
      config: config
    } do
      conn = get("/unsafe/rs:auto:100/plain/images/beach.jpg", config)

      assert conn.status == 400
      assert conn.resp_body == "invalid image request: {:missing_dimensions, :auto}"
      refute_received :origin_fetch
      refute_received {:cache_lookup, _key}
    end

    test "a geometry rejection in a LATER `-` pipeline is still caught pre-fetch", %{
      config: config
    } do
      conn = get("/unsafe/rs:fit:100:100/-/rs:fill/plain/images/beach.jpg", config)

      assert conn.status == 400
      assert conn.resp_body == "invalid image request: {:missing_dimensions, :fill}"
      refute_received :origin_fetch
      refute_received {:cache_lookup, _key}
    end

    test "an unknown option is a 400 that never fetches the source", %{config: config} do
      conn = get("/unsafe/bogus:10/plain/images/beach.jpg", config)

      assert conn.status == 400
      refute_received :origin_fetch
      refute_received {:cache_lookup, _key}
    end
  end

  # ── conditional GET ─────────────────────────────────────────────────────

  describe "conditional GET is evaluated before the cache lookup and the fetch" do
    test "matching If-None-Match: 304, empty body, no cache lookup, no source fetch" do
      plain_conn = get("/unsafe/rs:fit:100:100/plain/images/beach.jpg", opts())
      assert [etag] = get_resp_header(plain_conn, "etag")
      assert etag != ""

      config = opts(sources: should_not_fetch_sources(), cache: {CacheProbe, []})

      conn =
        get("/unsafe/rs:fit:100:100/plain/images/beach.jpg", config, [{"if-none-match", etag}])

      assert conn.status == 304
      assert conn.resp_body == ""
      refute_received {:cache_lookup, _key}
    end
  end

  # ── response metadata (fn:) rides the request, not the cache entry ──────

  describe "fn: content-disposition" do
    test "is set on the cache MISS and on the cache HIT, and the two share a body" do
      config = opts(sources: counting_sources(), cache: stateful_cache_probe())

      miss = get("/unsafe/fn:custom/rs:fit:100:100/plain/images/beach.jpg", config)
      assert miss.status == 200
      assert_received :origin_fetch
      assert get_resp_header(miss, "content-disposition") == ["inline; filename=\"custom.jpg\""]

      hit = get("/unsafe/fn:custom/rs:fit:100:100/plain/images/beach.jpg", config)
      assert hit.status == 200
      refute_received :origin_fetch
      assert get_resp_header(hit, "content-disposition") == ["inline; filename=\"custom.jpg\""]
      assert hit.resp_body == miss.resp_body
    end

    test "a cache entry warmed under one fn: is delivered with the CURRENT request's fn:" do
      config = opts(sources: counting_sources(), cache: stateful_cache_probe())

      first = get("/unsafe/fn:alpha/rs:fit:100:100/plain/images/beach.jpg", config)
      assert first.status == 200
      assert_received :origin_fetch
      assert get_resp_header(first, "content-disposition") == ["inline; filename=\"alpha.jpg\""]

      second = get("/unsafe/fn:beta/rs:fit:100:100/plain/images/beach.jpg", config)

      assert second.status == 200
      refute_received :origin_fetch
      assert get_resp_header(second, "content-disposition") == ["inline; filename=\"beta.jpg\""]
      assert second.resp_body == first.resp_body
    end

    test "with no fn:, the filename falls back to the source basename" do
      conn = get("/unsafe/rs:fit:100:100/plain/images/beach.jpg", opts())

      assert get_resp_header(conn, "content-disposition") == ["inline; filename=\"beach.jpg\""]
    end
  end

  describe "conditional GET x response metadata" do
    test "two fn: spellings share an ETag, and either one's If-None-Match is a 304 carrying no content-disposition" do
      config = opts()

      alpha = get("/unsafe/fn:alpha/rs:fit:100:100/plain/images/beach.jpg", config)
      beta = get("/unsafe/fn:beta/rs:fit:100:100/plain/images/beach.jpg", config)

      assert [etag] = get_resp_header(alpha, "etag")
      assert get_resp_header(beta, "etag") == [etag]

      assert get_resp_header(alpha, "content-disposition") == ["inline; filename=\"alpha.jpg\""]
      assert get_resp_header(beta, "content-disposition") == ["inline; filename=\"beta.jpg\""]

      not_modified_config = opts(sources: should_not_fetch_sources())

      for spelling <- ["fn:alpha", "fn:beta"] do
        conn =
          get(
            "/unsafe/#{spelling}/rs:fit:100:100/plain/images/beach.jpg",
            not_modified_config,
            [{"if-none-match", etag}]
          )

        assert conn.status == 304
        assert conn.resp_body == ""
        # `Response.Sender`'s core-owned not-modified header allowlist keeps a
        # 304 free of content-disposition, structurally.
        assert get_resp_header(conn, "content-disposition") == []
        assert get_resp_header(conn, "etag") == [etag]
      end
    end
  end

  # ── debug? is delivery-only ─────────────────────────────────────────────

  describe "debug:1 is header-only" do
    test "the same request with and without debug:1 produces byte-identical bodies and equal ETags" do
      config = opts()

      plain = get("/unsafe/rs:fit:100:100/plain/images/beach.jpg", config)
      debug = get("/unsafe/debug:1/rs:fit:100:100/plain/images/beach.jpg", config)

      assert plain.status == 200
      assert debug.status == 200
      assert plain.resp_body == debug.resp_body
      assert get_resp_header(plain, "etag") == get_resp_header(debug, "etag")
    end
  end

  # ── cache reuse ─────────────────────────────────────────────────────────

  describe "cache reuse" do
    test "a semantically permuted URL is served from the SAME cached entry" do
      config = opts(sources: counting_sources(), cache: stateful_cache_probe())

      conn_a = get("/unsafe/w:100/h:80/plain/images/beach.jpg", config)
      assert conn_a.status == 200
      assert_received :origin_fetch

      conn_b = get("/unsafe/h:80/w:100/plain/images/beach.jpg", config)

      assert conn_b.status == 200
      refute_received :origin_fetch
      assert conn_b.resp_body == conn_a.resp_body
      assert get_resp_header(conn_b, "etag") == get_resp_header(conn_a, "etag")
    end
  end

  # ── negotiation ─────────────────────────────────────────────────────────

  describe "output negotiation" do
    test "Accept: image/avif selects avif and varies; an explicit f:webp does not vary" do
      config = opts()

      avif =
        get("/unsafe/rs:fit:100:100/plain/images/beach.jpg", config, [{"accept", "image/avif"}])

      webp = get("/unsafe/rs:fit:100:100/f:webp/plain/images/beach.jpg", config)

      assert get_resp_header(avif, "content-type") == ["image/avif"]
      assert get_resp_header(avif, "vary") == ["Accept"]

      assert get_resp_header(webp, "content-type") == ["image/webp"]
      assert get_resp_header(webp, "vary") == []
    end

    test "an explicit format the build cannot write is 501 before any source fetch" do
      config =
        Keyword.merge(
          opts(sources: should_not_fetch_sources()),
          output_capabilities: %{avif: false}
        )

      conn = get("/unsafe/f:avif/plain/images/beach.jpg", config)

      assert conn.status == 501
      assert conn.resp_body == "requested output format is not supported by this server"
    end
  end
end
