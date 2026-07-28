defmodule ImagePipe.Dialect.Imgproxy.InfoWireTest do
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

  # A 40x80 source carrying EXIF orientation 6 (a quarter turn), so /info must
  # report the swapped display dimensions rather than the stored ones.
  defmodule ExifOrientationOriginImage do
    @moduledoc false

    def call(conn, _opts) do
      body =
        40
        |> Image.new!(80, color: :white)
        |> Image.Draw.rect!(0, 0, 40, 40, color: :red)
        |> Image.set_orientation!(6)
        |> Image.write!(:memory, suffix: ".jpg")

      conn
      |> Plug.Conn.put_resp_content_type("image/jpeg")
      |> Plug.Conn.send_resp(200, body)
    end
  end

  # A body that survives the source layer's own validation (it carries
  # non-printable bytes) but is not a decodable image, so the failure lands on
  # the decode step -> {:decode, _} -> 415, rather than on the source step.
  defmodule CorruptSourceOrigin do
    @moduledoc false

    def call(conn, _opts) do
      conn
      |> Plug.Conn.put_resp_content_type("image/png")
      |> Plug.Conn.send_resp(200, "not a valid image \xFF\xFE\x00")
    end
  end

  # Fails every write_chunk/3 — the /info analog of the image path's error-matrix
  # row 7. The response must still be delivered (cache errors fail open).
  defmodule FailingWriteChunkCache do
    @moduledoc false

    @behaviour ImagePipe.Cache

    @impl true
    def get(_key, _opts), do: :miss

    @impl true
    def open_sink(key, metadata, _opts) do
      send(target(), {:cache_open_sink, key, metadata})
      {:ok, %{}}
    end

    @impl true
    def write_chunk(state, _chunk, _opts) do
      send(target(), :cache_write_chunk_failed)
      {:error, :forced_write_failure, state}
    end

    @impl true
    def commit_sink(_state, _opts) do
      send(target(), :cache_commit_sink)
      :ok
    end

    @impl true
    def abort_sink(_state, _opts) do
      send(target(), :cache_abort_sink)
      :ok
    end

    defp target do
      case Process.get(:"$callers") do
        [pid | _rest] when is_pid(pid) -> pid
        _callers -> self()
      end
    end
  end

  defp counting_sources do
    [
      path:
        {RootHTTPAdapter,
         root_url: "http://origin.test",
         byte_identity: :strong,
         req_options: [plug: {CountingOriginImage, test_pid: self()}]}
    ]
  end

  defp stateful_cache_probe do
    table = :ets.new(:imgproxy_info_wire_cache_probe, [:set, :public])
    {CacheProbe, store: table}
  end

  defp opts(extra \\ []) do
    ImagePipe.Plug.init([dialect: Imgproxy] ++ Keyword.merge([sources: @default_sources], extra))
  end

  defp get(path, config, headers \\ []) do
    conn = conn(:get, path)
    conn = Enum.reduce(headers, conn, fn {k, v}, c -> put_req_header(c, k, v) end)
    ImagePipe.Plug.call(conn, config)
  end

  # ── the /info body contract ─────────────────────────────────────────────

  describe "GET /info/unsafe/plain/images/beach.jpg" do
    test "200 application/json whose decoded body matches the committed golden" do
      path = "/info/unsafe/plain/images/beach.jpg"

      dialect = get(path, opts())

      assert dialect.status == 200
      assert get_resp_header(dialect, "content-type") == ["application/json; charset=utf-8"]

      assert JSON.decode!(dialect.resp_body) == %{
               "format" => "jpeg",
               "mime_type" => "image/jpeg",
               "width" => 4000,
               "height" => 2667,
               "orientation" => 1
             }
    end

    test "carries an ETag and does not vary by Accept" do
      conn = get("/info/unsafe/plain/images/beach.jpg", opts())

      assert [etag] = get_resp_header(conn, "etag")
      assert etag != ""
      assert get_resp_header(conn, "vary") == []
    end

    test "reports the swapped display dimensions for a quarter-turn EXIF source" do
      sources = [
        path:
          {RootHTTPAdapter,
           root_url: "http://origin.test",
           byte_identity: :strong,
           req_options: [plug: ExifOrientationOriginImage]}
      ]

      path = "/info/unsafe/plain/images/oriented.jpg"

      dialect = get(path, opts(sources: sources))

      assert JSON.decode!(dialect.resp_body) == %{
               "format" => "jpeg",
               "mime_type" => "image/jpeg",
               "width" => 80,
               "height" => 40,
               "orientation" => 6
             }
    end
  end

  # ── signature ───────────────────────────────────────────────────────────

  describe "signature" do
    test "a bad signature is 403 before any source fetch" do
      config =
        opts(
          signature: [keys: [@signing_key], salts: [@signing_salt]],
          sources: [
            path:
              {RootHTTPAdapter,
               root_url: "http://origin.test",
               byte_identity: :strong,
               req_options: [plug: OriginShouldNotFetch]}
          ]
        )

      conn = get("/info/invalidsig/plain/images/beach.jpg", config)

      assert conn.status == 403
      assert conn.resp_body == "invalid image request: :invalid_signature"
    end
  end

  # ── expires ─────────────────────────────────────────────────────────────

  describe "expires gate" do
    test "a past exp: is 400 before any source fetch" do
      config = opts(clock: fn -> DateTime.from_unix!(101) end, sources: counting_sources())

      conn = get("/info/unsafe/exp:100/plain/images/beach.jpg", config)

      assert conn.status == 400
      assert conn.resp_body == "invalid image request: {:expired_request, 100}"
      refute_received :origin_fetch
    end
  end

  # ── complete-body cache round trip ──────────────────────────────────────

  # ── identity ignores what /info does not execute ────────────────────────

  # /info never runs a pipeline and never encodes: `serve_info/4` goes straight
  # to `source_info/2` with `@info_decode_request`. So an option that only feeds
  # the pipeline or the encoder cannot change a byte of the response, and must
  # not move the ETag (a byte-identity validator, AGENTS.md) or the cache key.
  #
  # All three of these parse: `Options.parse` accepts `rs:fill` (the
  # missing-dimensions rejection is `Assembly`'s, and `route_info` correctly
  # never runs `check_geometry`), and `q:`/`f:` are plain output options.
  describe "/info identity" do
    @ignored_option_paths [
      "/info/unsafe/plain/images/beach.jpg",
      "/info/unsafe/rs:fill:100:100/plain/images/beach.jpg",
      "/info/unsafe/q:50/plain/images/beach.jpg",
      "/info/unsafe/f:webp/plain/images/beach.jpg"
    ]

    test "options /info cannot execute change neither the body, the ETag, nor the cache key" do
      config = opts(cache: {CacheProbe, []})

      results =
        for path <- @ignored_option_paths do
          conn = get(path, config)
          assert conn.status == 200
          assert_received {:cache_lookup, key}

          {conn.resp_body, get_resp_header(conn, "etag"), key.hash}
        end

      {bodies, etags, key_hashes} = unzip3(results)

      # The premise: these four requests genuinely return the same bytes.
      assert length(Enum.uniq(bodies)) == 1

      assert [etag] = Enum.uniq(etags)
      assert [_single] = etag
      assert length(Enum.uniq(key_hashes)) == 1
    end
  end

  # A configured `storage_inputs` header selects a different resolved source, so
  # it varies the /info body for real — and `Representation.storage_inputs/2`
  # duly returns it as a vary name. The 304 branch emits it (`cache_headers/1` ->
  # `representation_headers`); the 200 must agree, or a shared cache keyed
  # without it hands one tenant's /info to another.
  describe "/info Vary" do
    test "a 200 and its own 304 agree on the Vary a configured storage_input adds" do
      config = opts(storage_inputs: [header: "x-tenant"], cache: {CacheProbe, []})
      tenant = [{"x-tenant", "acme"}]

      ok = get("/info/unsafe/plain/images/beach.jpg", config, tenant)
      assert ok.status == 200
      assert [etag] = get_resp_header(ok, "etag")

      not_modified =
        get("/info/unsafe/plain/images/beach.jpg", config, [{"if-none-match", etag} | tenant])

      assert not_modified.status == 304

      assert get_resp_header(ok, "vary") == ["x-tenant"]
      assert get_resp_header(ok, "vary") == get_resp_header(not_modified, "vary")
    end

    test "a 200 carries no Vary when no storage_input is configured" do
      conn = get("/info/unsafe/plain/images/beach.jpg", opts(cache: {CacheProbe, []}))

      assert conn.status == 200
      assert get_resp_header(conn, "vary") == []
    end
  end

  defp unzip3(triples) do
    {Enum.map(triples, &elem(&1, 0)), Enum.map(triples, &elem(&1, 1)),
     Enum.map(triples, &elem(&1, 2))}
  end

  describe "complete-body cache" do
    test "the second request is served from the stored entry: same body, no second source fetch" do
      config = opts(sources: counting_sources(), cache: stateful_cache_probe())

      miss = get("/info/unsafe/plain/images/beach.jpg", config)
      assert miss.status == 200
      assert_received :origin_fetch
      assert_received {:source_order, :cache_put}

      hit = get("/info/unsafe/plain/images/beach.jpg", config)

      assert hit.status == 200
      refute_received :origin_fetch
      assert_received {:source_order, :cache_lookup}
      refute_received {:source_order, :cache_put}

      assert hit.resp_body == miss.resp_body
      assert get_resp_header(hit, "content-type") == get_resp_header(miss, "content-type")
      assert get_resp_header(hit, "content-type") == ["application/json; charset=utf-8"]
      assert get_resp_header(hit, "etag") == get_resp_header(miss, "etag")
    end

    test "the stored entry is tagged a complete body with the renderer's content type" do
      config = opts(cache: {CacheProbe, []})

      conn = get("/info/unsafe/plain/images/beach.jpg", config)
      assert conn.status == 200

      assert_received {:cache_open_sink, _key, metadata}
      assert metadata.representation == {:complete_body, "application/json"}
      assert metadata.cost_us > 0
    end

    # The image path's `internal_cache: :disabled` contract, on the /info
    # terminal. The status is 200 whether or not the flag is honored, so the
    # cache-access messages are the whole assertion.
    test "a source that disabled the internal cache is neither read from nor written to" do
      config =
        opts(
          sources: [
            path:
              {RootHTTPAdapter,
               root_url: "http://origin.test",
               byte_identity: :strong,
               req_options: [plug: {CountingOriginImage, test_pid: self()}],
               internal_cache: :disabled}
          ],
          cache: stateful_cache_probe()
        )

      conn = get("/info/unsafe/plain/images/beach.jpg", config)

      assert conn.status == 200
      assert JSON.decode!(conn.resp_body)["format"] == "jpeg"
      assert_received :origin_fetch
      refute_received {:cache_lookup, _key}
      refute_received {:cache_open_sink, _key, _metadata}
      refute_received {:source_order, :cache_put}
    end

    test "a matching If-None-Match is 304 before any cache lookup or source fetch" do
      warm = get("/info/unsafe/plain/images/beach.jpg", opts())
      assert [etag] = get_resp_header(warm, "etag")

      config =
        opts(
          sources: [
            path:
              {RootHTTPAdapter,
               root_url: "http://origin.test",
               byte_identity: :strong,
               req_options: [plug: OriginShouldNotFetch]}
          ],
          cache: {CacheProbe, []}
        )

      conn = get("/info/unsafe/plain/images/beach.jpg", config, [{"if-none-match", etag}])

      assert conn.status == 304
      assert conn.resp_body == ""
      refute_received {:cache_lookup, _key}
    end
  end

  # ── cache-write failure fails open (the /info analog of row 7) ──────────

  describe "cache-write failure" do
    test "a failing write_chunk/3 still delivers the correct JSON body: the sink aborts, no commit" do
      config = opts(cache: {FailingWriteChunkCache, []})

      conn = get("/info/unsafe/plain/images/beach.jpg", config)

      assert conn.status == 200
      assert get_resp_header(conn, "content-type") == ["application/json; charset=utf-8"]
      assert JSON.decode!(conn.resp_body)["format"] == "jpeg"

      assert_received {:cache_open_sink, _key, _metadata}
      assert_received :cache_write_chunk_failed
      assert_received :cache_abort_sink
      refute_received :cache_commit_sink
    end
  end

  # ── the /info decode taxonomy ───────────────────────────────────────────

  describe "a non-image source" do
    test "is 415" do
      sources = [
        path:
          {RootHTTPAdapter,
           root_url: "http://origin.test",
           byte_identity: :strong,
           req_options: [plug: CorruptSourceOrigin]}
      ]

      path = "/info/unsafe/plain/images/whatever.jpg"

      dialect = get(path, opts(sources: sources))

      assert dialect.status == 415
    end
  end
end
