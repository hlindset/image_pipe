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
    path: {RootHTTPAdapter, root_url: "http://origin.test", req_options: [plug: OriginImage]}
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
         req_options: [plug: {CountingOriginImage, test_pid: self()}]}
    ]
  end

  defp stateful_cache_probe do
    table = :ets.new(:imgproxy_info_wire_cache_probe, [:set, :public])
    {CacheProbe, store: table}
  end

  defp opts(extra \\ []) do
    Imgproxy.init(Keyword.merge([sources: @default_sources], extra))
  end

  defp get(path, config, headers \\ []) do
    conn = conn(:get, path)
    conn = Enum.reduce(headers, conn, fn {k, v}, c -> put_req_header(c, k, v) end)
    Imgproxy.call(conn, config)
  end

  # The framework arm's answer for the same request — the info-parity oracle.
  defp framework_get(path, sources) do
    framework_opts = [parser: ImagePipe.Parser.Imgproxy, sources: sources]
    ImagePipe.Plug.call(conn(:get, path), ImagePipe.Plug.init(framework_opts))
  end

  # ── parity with the framework arm ───────────────────────────────────────

  describe "GET /info/unsafe/plain/images/beach.jpg" do
    test "200 application/json whose decoded body equals the framework arm's, for the same request" do
      path = "/info/unsafe/plain/images/beach.jpg"

      dialect = get(path, opts())
      framework = framework_get(path, @default_sources)

      assert dialect.status == 200
      assert framework.status == 200
      assert get_resp_header(dialect, "content-type") == ["application/json; charset=utf-8"]

      assert get_resp_header(dialect, "content-type") ==
               get_resp_header(framework, "content-type")

      json = JSON.decode!(dialect.resp_body)
      assert json == JSON.decode!(framework.resp_body)

      # Named explicitly, so the parity assertion above cannot pass on two
      # equally-empty documents.
      assert json["format"] == "jpeg"
      assert json["mime_type"] == "image/jpeg"
      assert is_integer(json["width"]) and json["width"] > 0
      assert is_integer(json["height"]) and json["height"] > 0
      assert json["orientation"] in 1..8
      refute Map.has_key?(json, "size")
    end

    test "carries an ETag and does not vary by Accept" do
      conn = get("/info/unsafe/plain/images/beach.jpg", opts())

      assert [etag] = get_resp_header(conn, "etag")
      assert etag != ""
      assert get_resp_header(conn, "vary") == []
    end

    test "reports the swapped display dimensions for a quarter-turn EXIF source, as the framework does" do
      sources = [
        path:
          {RootHTTPAdapter,
           root_url: "http://origin.test", req_options: [plug: ExifOrientationOriginImage]}
      ]

      path = "/info/unsafe/plain/images/oriented.jpg"

      dialect = get(path, opts(sources: sources))
      framework = framework_get(path, sources)

      json = JSON.decode!(dialect.resp_body)

      assert json == JSON.decode!(framework.resp_body)
      assert json["orientation"] == 6
      assert json["width"] == 80
      assert json["height"] == 40
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
               root_url: "http://origin.test", req_options: [plug: OriginShouldNotFetch]}
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

    test "a matching If-None-Match is 304 before any cache lookup or source fetch" do
      warm = get("/info/unsafe/plain/images/beach.jpg", opts())
      assert [etag] = get_resp_header(warm, "etag")

      config =
        opts(
          sources: [
            path:
              {RootHTTPAdapter,
               root_url: "http://origin.test", req_options: [plug: OriginShouldNotFetch]}
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
    test "is 415, as it is on the framework arm" do
      sources = [
        path:
          {RootHTTPAdapter,
           root_url: "http://origin.test", req_options: [plug: CorruptSourceOrigin]}
      ]

      path = "/info/unsafe/plain/images/whatever.jpg"

      dialect = get(path, opts(sources: sources))
      framework = framework_get(path, sources)

      assert dialect.status == 415
      assert framework.status == 415
      assert dialect.resp_body == framework.resp_body
    end
  end
end
