defmodule ImagePipe.Dialect.TwicPics.DebugTest do
  use ExUnit.Case, async: true

  import Plug.Conn
  import Plug.Test

  alias ImagePipe.Dialect.TwicPics
  alias ImagePipe.SourceTest.RootHTTPAdapter
  alias ImgproxyWireConformanceTest.CacheProbe
  alias ImgproxyWireConformanceTest.CountingOriginImage
  alias ImgproxyWireConformanceTest.OriginImage

  @default_sources [
    path:
      {RootHTTPAdapter,
       root_url: "http://origin.test", byte_identity: :strong, req_options: [plug: OriginImage]}
  ]

  defp opts(extra \\ []) do
    ImagePipe.Plug.init(Keyword.merge([dialect: TwicPics, sources: @default_sources], extra))
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

  defp stateful_cache do
    table = :ets.new(:twic_pics_debug_cache, [:set, :public])
    {CacheProbe, store: table}
  end

  defp get(path, config) do
    :get
    |> conn(path)
    |> ImagePipe.Plug.call(config)
  end

  defp header(conn, name) do
    case get_resp_header(conn, name) do
      [value] -> value
      [] -> nil
    end
  end

  defp assert_no_debug(conn) do
    assert header(conn, "x-imagepipe-source-format") == nil
    assert header(conn, "x-imagepipe-output-format") == nil
    assert header(conn, "x-imagepipe-cache") == nil
    assert header(conn, "server-timing") == nil
  end

  describe "delivery-time debug gating" do
    test "debug=1 with host permission emits stable semantic facts and measured timings" do
      conn =
        get(
          "/images/beach.jpg?twic=v1/focus=auto/cover=100x80/quality=72/output=jpeg/debug=1",
          opts(allow_debug_headers: true)
        )

      assert conn.status == 200
      assert header(conn, "x-imagepipe-source-format") == "jpeg"
      assert header(conn, "x-imagepipe-source-width") == "4000"
      assert header(conn, "x-imagepipe-source-height") == "2667"
      assert header(conn, "x-imagepipe-source-size") == "851508"
      assert header(conn, "x-imagepipe-source-color-space") == "VIPS_INTERPRETATION_sRGB"
      assert header(conn, "x-imagepipe-source-icc") == "true"
      assert header(conn, "x-imagepipe-source-bit-depth") == "8"
      assert header(conn, "x-imagepipe-source-alpha") == "false"
      assert header(conn, "x-imagepipe-source-orientation") == nil

      assert header(conn, "x-imagepipe-output-format") == "jpeg"
      assert header(conn, "x-imagepipe-output-negotiated") == "false"
      assert header(conn, "x-imagepipe-output-width") == "100"
      assert header(conn, "x-imagepipe-output-height") == "80"
      assert header(conn, "x-imagepipe-output-quality") == "72"
      assert header(conn, "x-imagepipe-pipeline") == "resize"
      assert header(conn, "x-imagepipe-cache") == "miss"

      server_timing = header(conn, "server-timing")
      assert is_binary(server_timing)

      for stage <- ~w(decode transform encode total) do
        assert server_timing =~ ~r/(^|, )#{stage};dur=\d+(\.\d+)?/
      end
    end

    test "an absent debug segment emits no debug headers" do
      conn =
        get(
          "/images/beach.jpg?twic=v1/resize=64/output=jpeg",
          opts(allow_debug_headers: true)
        )

      assert conn.status == 200
      assert_no_debug(conn)
    end

    test "debug=1 is suppressed when the host disallows debug headers" do
      conn = get("/images/beach.jpg?twic=v1/resize=64/output=jpeg/debug=1", opts())

      assert conn.status == 200
      assert_no_debug(conn)
    end

    test "debug=0 explicitly opts out even when the host permits headers" do
      conn =
        get(
          "/images/beach.jpg?twic=v1/resize=64/output=jpeg/debug=0",
          opts(allow_debug_headers: true)
        )

      assert conn.status == 200
      assert_no_debug(conn)
    end

    test "invalid debug rejects before source fetch" do
      conn =
        get(
          "/images/beach.jpg?twic=v1/resize=64/debug=maybe/output=jpeg",
          opts(allow_debug_headers: true, sources: counting_sources())
        )

      assert conn.status == 400
      refute_received :origin_fetch
      assert_no_debug(conn)
    end
  end

  describe "cache replay" do
    test "debug is excluded from identity and a hit uses the current request's gate" do
      config =
        opts(
          allow_debug_headers: true,
          sources: counting_sources(),
          cache: stateful_cache()
        )

      path = "/images/beach.jpg?twic=v1/resize=64/output=jpeg"
      plain = get(path, config)
      assert plain.status == 200
      assert_received :origin_fetch
      assert_no_debug(plain)

      hit = get(path <> "/debug=1", config)
      assert hit.status == 200
      refute_received :origin_fetch
      assert hit.resp_body == plain.resp_body
      assert header(hit, "etag") == header(plain, "etag")
      assert header(hit, "x-imagepipe-source-format") == "jpeg"
      assert header(hit, "x-imagepipe-output-width") == "64"
      assert header(hit, "x-imagepipe-cache") == "hit"
      assert header(hit, "server-timing") =~ "cache;dur="
    end

    test "a miss with debug enabled stores facts replayed on the next hit" do
      config =
        opts(
          allow_debug_headers: true,
          sources: counting_sources(),
          cache: stateful_cache()
        )

      path = "/images/beach.jpg?twic=v1/contain=73x61/output=jpeg/debug=1"
      miss = get(path, config)
      assert miss.status == 200
      assert_received :origin_fetch
      assert header(miss, "x-imagepipe-source-format") == "jpeg"
      assert header(miss, "x-imagepipe-source-size") == "851508"
      assert header(miss, "x-imagepipe-source-color-space") == "VIPS_INTERPRETATION_sRGB"
      assert header(miss, "x-imagepipe-source-icc") == "true"
      assert header(miss, "x-imagepipe-source-bit-depth") == "8"
      assert header(miss, "x-imagepipe-source-alpha") == "false"
      assert header(miss, "x-imagepipe-source-orientation") == nil
      assert header(miss, "x-imagepipe-cache") == "miss"

      hit = get(path, config)
      assert hit.status == 200
      refute_received :origin_fetch

      for name <- [
            "x-imagepipe-source-format",
            "x-imagepipe-source-width",
            "x-imagepipe-source-height",
            "x-imagepipe-source-size",
            "x-imagepipe-source-color-space",
            "x-imagepipe-source-icc",
            "x-imagepipe-source-bit-depth",
            "x-imagepipe-source-alpha",
            "x-imagepipe-output-format",
            "x-imagepipe-output-width",
            "x-imagepipe-output-height",
            "x-imagepipe-output-quality",
            "x-imagepipe-pipeline"
          ] do
        assert header(hit, name) == header(miss, name)
      end

      assert header(hit, "x-imagepipe-source-orientation") == nil
      assert header(hit, "x-imagepipe-cache") == "hit"
      assert header(hit, "server-timing") =~ "cache;dur="
    end
  end
end
