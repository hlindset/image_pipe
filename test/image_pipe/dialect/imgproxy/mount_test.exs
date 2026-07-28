defmodule ImagePipe.Dialect.Imgproxy.MountTest do
  @moduledoc """
  Mount and path semantics for `ImagePipe.Dialect.Imgproxy` [spec §Mount /
  path semantics].

  Which path representation is authoritative is a claim, and the spec's point
  is that it must be pinned rather than assumed. `path.ex` moved with its own
  `parser_request_path/1`, so the dialect inherits imgproxy's mount-prefix
  handling rather than native's `script_name` byte-prefix approach.

  `ImagePipe.Dialect.Imgproxy.PathTest` (`path_test.exs`, same dir) already
  covers `extract/1`'s `script_name` handling at the unit level. This file is
  the wire-level half: a real `Plug.Router.forward/2` mount, so the prefix is
  set by Plug itself rather than by a hand-built conn, and the assertions are
  on the served response.
  """

  use ExUnit.Case, async: true

  import Plug.Conn
  import Plug.Test

  alias ImagePipe.Dialect.Imgproxy
  alias ImagePipe.SourceTest.RootHTTPAdapter
  alias ImgproxyWireConformanceTest.OriginImage

  @signing_key "746573742d6b6579"
  @signing_salt "746573742d73616c74"

  # Records the origin path each fetch actually asks for, so a test can assert
  # what the source segments decoded to — the only place a `%2F` that was
  # wrongly treated as a separator becomes visible.
  defmodule RecordingOrigin do
    @moduledoc false
    def init(opts), do: opts

    def call(conn, opts) do
      opts |> Keyword.fetch!(:test_pid) |> send({:origin_fetch, conn.request_path})

      conn
      |> Plug.Conn.put_resp_content_type("image/jpeg")
      |> Plug.Conn.send_resp(200, File.read!("priv/static/images/beach.jpg"))
    end
  end

  @default_sources [
    path:
      {RootHTTPAdapter,
       root_url: "http://origin.test", byte_identity: :strong, req_options: [plug: OriginImage]}
  ]

  defp opts(extra \\ []) do
    base =
      ImagePipe.Plug.init(
        [dialect: Imgproxy] ++ Keyword.merge([sources: @default_sources], extra)
      )

    Keyword.merge(base, output_capabilities: %{avif: true, webp: true, jpeg_xl: true})
  end

  defp get(path, config, headers \\ []) do
    conn = conn(:get, path)
    conn = Enum.reduce(headers, conn, fn {k, v}, c -> put_req_header(c, k, v) end)
    ImagePipe.Plug.call(conn, config)
  end

  defp decoded_dims(body) do
    {:ok, image} = Image.from_binary(body)
    {Image.width(image), Image.height(image)}
  end

  defp signed_path(signed_path) do
    key = Base.decode16!(@signing_key, case: :lower)
    salt = Base.decode16!(@signing_salt, case: :lower)

    signature =
      :crypto.mac(:hmac, :sha256, key, salt <> signed_path)
      |> Base.url_encode64(padding: false)

    "/" <> signature <> signed_path
  end

  defp signing_opts(extra \\ []) do
    opts(Keyword.merge([signature: [keys: [@signing_key], salts: [@signing_salt]]], extra))
  end

  # ── mounting ────────────────────────────────────────────────────────────
  #
  # Three routers, identical except for where the dialect is forwarded to. A
  # `Plug.Router.forward/2` is what sets `script_name` in production; building
  # the conn by hand would test the test's idea of a mount rather than Plug's.
  #
  # `forward/2` calls `ImagePipe.Plug.init/1` on `init_opts` itself, so these
  # are the RAW host options — the same thing a host writes in its own router.
  defmodule RootRouter do
    @moduledoc false
    use Plug.Router

    plug :match
    plug :dispatch

    forward "/",
      to: ImagePipe.Plug,
      init_opts: [
        dialect: ImagePipe.Dialect.Imgproxy,
        sources: [
          path:
            {ImagePipe.SourceTest.RootHTTPAdapter,
             root_url: "http://origin.test",
             byte_identity: :strong,
             req_options: [plug: ImgproxyWireConformanceTest.OriginImage]}
        ]
      ]
  end

  defmodule PrefixedRouter do
    @moduledoc false
    use Plug.Router

    plug :match
    plug :dispatch

    forward "/img",
      to: ImagePipe.Plug,
      init_opts: [
        dialect: ImagePipe.Dialect.Imgproxy,
        sources: [
          path:
            {ImagePipe.SourceTest.RootHTTPAdapter,
             root_url: "http://origin.test",
             byte_identity: :strong,
             req_options: [plug: ImgproxyWireConformanceTest.OriginImage]}
        ]
      ]
  end

  defmodule MultiSegmentPrefixedRouter do
    @moduledoc false
    use Plug.Router

    plug :match
    plug :dispatch

    forward "/proxy/v1",
      to: ImagePipe.Plug,
      init_opts: [
        dialect: ImagePipe.Dialect.Imgproxy,
        sources: [
          path:
            {ImagePipe.SourceTest.RootHTTPAdapter,
             root_url: "http://origin.test",
             byte_identity: :strong,
             req_options: [plug: ImgproxyWireConformanceTest.OriginImage]}
        ]
      ]
  end

  describe "mount point" do
    test "root mount: the dialect serves the whole path" do
      conn = RootRouter.call(conn(:get, "/unsafe/rs:fit:64:64/plain/images/beach.jpg"), [])

      assert conn.status == 200
      assert {width, height} = decoded_dims(conn.resp_body)
      assert max(width, height) == 64
    end

    test "single-segment prefix mount: the prefix is stripped before the signature segment" do
      conn =
        PrefixedRouter.call(conn(:get, "/img/unsafe/rs:fit:64:64/plain/images/beach.jpg"), [])

      assert conn.status == 200
      assert {width, height} = decoded_dims(conn.resp_body)
      assert max(width, height) == 64
    end

    test "multi-segment prefix mount: every prefix segment is stripped" do
      conn =
        MultiSegmentPrefixedRouter.call(
          conn(:get, "/proxy/v1/unsafe/rs:fit:64:64/plain/images/beach.jpg"),
          []
        )

      assert conn.status == 200
      assert {width, height} = decoded_dims(conn.resp_body)
      assert max(width, height) == 64
    end

    test "a request to the mount root itself is a 400, not a crash" do
      conn = PrefixedRouter.call(conn(:get, "/img"), [])

      assert conn.status == 400
      assert conn.resp_body == "invalid image request: :missing_signature"
    end

    test "the mount prefix is NOT part of the signed material" do
      # The same signed path verifies at the root and under `/img`: the
      # signature covers what follows the signature segment, and the prefix is
      # stripped before `extract/1` ever sees it. If the prefix leaked into the
      # signed material, the prefixed arm would 403.
      path = signed_path("/rs:fit:64:64/plain/images/beach.jpg")

      root = get(path, signing_opts())
      assert root.status == 200

      prefixed =
        conn(:get, "/img" <> path)
        |> Map.put(:script_name, ["img"])
        |> ImagePipe.Plug.call(signing_opts())

      assert prefixed.status == 200
      assert prefixed.resp_body == root.resp_body
    end
  end

  # ── /info under a non-root mount ────────────────────────────────────────

  describe "/info returned conn" do
    test "the returned conn retains the /info path prefix (the runner never returns the dialect's internally prefix-stripped conn)" do
      conn = get("/info/unsafe/plain/images/beach.jpg", opts())

      assert conn.status == 200
      assert conn.request_path == "/info/unsafe/plain/images/beach.jpg"
    end
  end

  describe "/info under a mount prefix" do
    test "the /info terminal is found after the prefix is stripped, and renders info JSON" do
      conn = PrefixedRouter.call(conn(:get, "/img/info/unsafe/plain/images/beach.jpg"), [])

      assert conn.status == 200
      assert get_resp_header(conn, "content-type") == ["application/json; charset=utf-8"]
      assert %{"format" => "jpeg"} = Jason.decode!(conn.resp_body)
    end

    test "the /info prefix is excluded from the signed material under a mount too" do
      # Upstream signs the path WITHOUT the `/info` prefix; `split_endpoint/1`
      # strips it before `extract/1` runs. Under a mount BOTH prefixes come off,
      # so the identical signed path serves at `/info/…` and at `/img/info/…`.
      path = signed_path("/plain/images/beach.jpg")

      root = get("/info" <> path, signing_opts())
      assert root.status == 200

      prefixed =
        conn(:get, "/img/info" <> path)
        |> Map.put(:script_name, ["img"])
        |> ImagePipe.Plug.call(signing_opts())

      assert prefixed.status == 200
      assert prefixed.resp_body == root.resp_body
    end
  end

  # ── percent-encoded source bytes ────────────────────────────────────────

  describe "percent-encoded source bytes" do
    setup do
      test_pid = self()

      config =
        opts(
          sources: [
            path:
              {RootHTTPAdapter,
               root_url: "http://origin.test",
               byte_identity: :strong,
               req_options: [plug: {RecordingOrigin, test_pid: test_pid}]}
          ]
        )

      {:ok, config: config}
    end

    test "a %2F in a plain source stays one segment: it is NOT a path separator", %{
      config: config
    } do
      conn = get("/unsafe/rs:fit:64:64/plain/images/be%2Fach.jpg", config)

      assert conn.status == 200
      # `RootHTTPAdapter` re-encodes each segment, so a `%2F` that survived as a
      # byte inside ONE segment comes back out percent-encoded. Had it split the
      # segment, the origin would have seen `/images/be/ach.jpg`.
      assert_received {:origin_fetch, "/images/be%2Fach.jpg"}
    end

    test "a %2F source and the equivalent literal-slash source are different sources", %{
      config: config
    } do
      encoded = get("/unsafe/rs:fit:64:64/plain/images/be%2Fach.jpg", config)
      assert_received {:origin_fetch, "/images/be%2Fach.jpg"}

      literal = get("/unsafe/rs:fit:64:64/plain/images/be/ach.jpg", config)
      assert_received {:origin_fetch, "/images/be/ach.jpg"}

      # Different source identity => different cache key => different ETag.
      # Collapsing the two would let one source's bytes be served for the other.
      assert encoded.status == 200
      assert literal.status == 200
      assert get_resp_header(encoded, "etag") != get_resp_header(literal, "etag")
    end

    test "a %40 in a plain source is a literal @, not the output-extension separator", %{
      config: config
    } do
      conn = get("/unsafe/rs:fit:64:64/plain/images/be%40ach.jpg@webp", config)

      assert conn.status == 200
      assert_received {:origin_fetch, "/images/be%40ach.jpg"}
      assert get_resp_header(conn, "content-type") == ["image/webp"]
    end

    test "malformed percent encoding is a 400 that never fetches", %{config: config} do
      conn = get("/unsafe/rs:fit:64:64/plain/images/be%ZZach.jpg", config)

      assert conn.status == 400

      assert conn.resp_body ==
               "invalid image request: {:invalid_percent_encoding, \"be%ZZach.jpg\"}"

      refute_received {:origin_fetch, _path}
    end
  end

  # ── query strings are excluded from the signed material ─────────────────

  describe "query strings" do
    test "a signed URL still verifies when a query string is appended" do
      path = signed_path("/rs:fit:64:64/plain/images/beach.jpg")

      without = get(path, signing_opts())
      with_query = get(path <> "?x=y", signing_opts())

      assert without.status == 200
      assert with_query.status == 200
      assert with_query.resp_body == without.resp_body
    end

    test "the query string does not change the representation's identity" do
      path = signed_path("/rs:fit:64:64/plain/images/beach.jpg")

      without = get(path, signing_opts())
      with_query = get(path <> "?cachebuster=1", signing_opts())

      assert get_resp_header(with_query, "etag") == get_resp_header(without, "etag")
    end

    test "an unsigned URL's query string is likewise ignored" do
      plain = get("/unsafe/rs:fit:64:64/plain/images/beach.jpg", opts())
      queried = get("/unsafe/rs:fit:64:64/plain/images/beach.jpg?x=y", opts())

      assert plain.status == 200
      assert queried.status == 200
      assert queried.resp_body == plain.resp_body
    end
  end
end
