defmodule ImagePipe.Dialect.Imgproxy.DebugHeadersWireTest do
  use ExUnit.Case, async: true
  import Plug.Test
  import Plug.Conn

  alias ImagePipe.Dialect.Imgproxy
  alias ImagePipe.SourceTest.RootHTTPAdapter
  alias ImgproxyWireConformanceTest.CacheProbe
  alias ImgproxyWireConformanceTest.CountingOriginImage
  alias ImgproxyWireConformanceTest.OriginImage

  @sources [
    path:
      {RootHTTPAdapter,
       root_url: "http://origin.test", byte_identity: :strong, req_options: [plug: OriginImage]}
  ]

  defp opts(extra \\ []) do
    ImagePipe.Plug.init(Keyword.merge([dialect: Imgproxy, sources: @sources], extra))
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
    table = :ets.new(:imgproxy_debug_cache, [:set, :public])
    {CacheProbe, store: table}
  end

  defp get(path, config) do
    ImagePipe.Plug.call(conn(:get, path), config)
  end

  defp header(conn, name) do
    case get_resp_header(conn, name) do
      [value] -> value
      [] -> nil
    end
  end

  # Signs the path AFTER inserting `debug:1` (rather than signing a plain
  # path and mutating it after the fact) so the resulting signature actually
  # covers the debug flag, the same way the tamper test in
  # imgproxy_wire_conformance_test.exs proves the reverse case invalid.
  defp signed_debug_path do
    signed_request_path("/debug:1/f:jpeg/rs:fill:100:80/plain/images/beach.jpg")
  end

  defp signed_request_path(signed_path) do
    key = Base.decode16!("746573742d6b6579", case: :lower)
    salt = Base.decode16!("746573742d73616c74", case: :lower)

    signature =
      :crypto.mac(:hmac, :sha256, key, salt <> signed_path)
      |> Base.url_encode64(padding: false)

    "/" <> signature <> signed_path
  end

  test "a signed debug:1 request renders source facts and measured timings" do
    conn =
      get(
        signed_debug_path(),
        opts(
          signature: [keys: ["746573742d6b6579"], salts: ["746573742d73616c74"]],
          allow_debug_headers: true
        )
      )

    assert conn.status == 200
    assert header(conn, "x-imagepipe-source-format") == "jpeg"
    assert header(conn, "x-imagepipe-source-size") == "851508"
    assert header(conn, "x-imagepipe-source-color-space") == "VIPS_INTERPRETATION_sRGB"
    assert header(conn, "x-imagepipe-source-icc") == "true"
    assert header(conn, "x-imagepipe-source-bit-depth") == "8"
    assert header(conn, "x-imagepipe-source-alpha") == "false"
    assert header(conn, "x-imagepipe-source-orientation") == nil
    assert header(conn, "x-imagepipe-output-format") == "jpeg"
    assert header(conn, "x-imagepipe-cache") == "miss"

    timing = header(conn, "server-timing")
    assert is_binary(timing)

    for stage <- ~w(decode transform encode total) do
      assert timing =~ ~r/(^|, )#{stage};dur=\d+(\.\d+)?/
    end
  end

  test "debug:1 renders nothing without the mount flag, and a plain request renders nothing under it" do
    off = get("/_/debug:1/f:jpeg/plain/images/beach.jpg", opts())
    assert off.status == 200
    assert header(off, "x-imagepipe-source-format") == nil
    assert header(off, "server-timing") == nil

    plain = get("/_/f:jpeg/plain/images/beach.jpg", opts(allow_debug_headers: true))
    assert plain.status == 200
    assert header(plain, "x-imagepipe-source-format") == nil

    # The documented explicit opt-out (support matrix, `debug` extension row):
    # debug:0 under an enabled mount renders nothing. TwicPics pins its
    # counterpart at test/image_pipe/dialect/twic_pics/debug_test.exs:105.
    opted_out = get("/_/debug:0/f:jpeg/plain/images/beach.jpg", opts(allow_debug_headers: true))
    assert opted_out.status == 200
    assert header(opted_out, "x-imagepipe-source-format") == nil
    assert header(opted_out, "server-timing") == nil
  end

  test "debug:1 is identity-excluded: one cache entry, one ETag, facts replayed on the hit" do
    config = opts(allow_debug_headers: true, cache: stateful_cache(), sources: counting_sources())

    plain = get("/_/f:jpeg/rs:fill:64:64/plain/images/beach.jpg", config)
    assert plain.status == 200
    assert_received :origin_fetch
    assert header(plain, "x-imagepipe-source-format") == nil

    debug = get("/_/debug:1/f:jpeg/rs:fill:64:64/plain/images/beach.jpg", config)
    assert debug.status == 200
    refute_received :origin_fetch
    assert debug.resp_body == plain.resp_body
    assert header(debug, "etag") == header(plain, "etag")
    assert header(debug, "x-imagepipe-cache") == "hit"
    assert header(debug, "x-imagepipe-source-format") == "jpeg"
    assert header(debug, "x-imagepipe-source-size") == "851508"
    assert header(debug, "x-imagepipe-source-color-space") == "VIPS_INTERPRETATION_sRGB"
    assert header(debug, "x-imagepipe-source-icc") == "true"
    assert header(debug, "x-imagepipe-source-bit-depth") == "8"
    assert header(debug, "x-imagepipe-source-alpha") == "false"
    assert header(debug, "x-imagepipe-source-orientation") == nil
    assert header(debug, "server-timing") =~ "cache;dur="
  end
end
