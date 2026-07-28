defmodule ImagePipe.Dialect.ByteIdentityCacheHeadersTest do
  # The byte-identity ETag gate, asserted on the OBSERVABLE response headers of
  # both dialect stacks (EC#1). A source whose bytes carry no stable identity
  # (`byte_identity: :none`) must get NO `ETag` and a `Cache-Control: no-store`
  # — otherwise a conditional GET 304s against changed content and a shared
  # cache stores bytes with no stable identity. A strong-identity source still
  # emits its `ETag`. The gate lives in `ImagePipe.Representation.build/3`, the
  # one boundary both dialects reach, so neither can re-ship the divergence.
  #
  # These assert on the response, not an internal field: the D5 lesson is that a
  # header/internal assertion can pass while the real contract is violated.
  use ExUnit.Case, async: true

  import Plug.Conn
  import Plug.Test

  alias ImagePipe.Dialect.Imgproxy
  alias ImagePipe.Dialect.Native
  alias ImagePipe.SourceTest.RootHTTPAdapter
  alias ImgproxyWireConformanceTest.OriginImage

  defp none_sources do
    [path: {RootHTTPAdapter, root_url: "http://origin.test", req_options: [plug: OriginImage]}]
  end

  defp strong_sources do
    [
      path:
        {RootHTTPAdapter,
         root_url: "http://origin.test", req_options: [plug: OriginImage], byte_identity: :strong}
    ]
  end

  defp imgproxy_opts(sources) do
    base = ImagePipe.Plug.init(dialect: Imgproxy, sources: sources)
    Keyword.merge(base, output_capabilities: %{avif: true, webp: true, jpeg_xl: true})
  end

  defp native_opts(sources) do
    base = ImagePipe.Plug.init(dialect: Native, sources: sources)
    Keyword.merge(base, output_capabilities: %{avif: true, webp: true, jpeg_xl: true})
  end

  defp call(mod, path, config), do: mod.call(conn(:get, path), config)

  defp cache_control(conn), do: conn |> get_resp_header("cache-control") |> Enum.join(", ")

  @imgproxy_image "/unsafe/rs:fit:100:100/plain/images/beach.jpg"
  @imgproxy_info "/info/unsafe/plain/images/beach.jpg"
  @native_image "/w=64/src/images/cat.jpg"
  @native_blurhash "/w=32/output=blurhash/src/images/cat.jpg"

  describe "byte_identity :none withholds the ETag and sends Cache-Control: no-store" do
    test "imgproxy streamed image" do
      conn = call(ImagePipe.Plug, @imgproxy_image, imgproxy_opts(none_sources()))

      assert conn.status == 200
      assert get_resp_header(conn, "etag") == []
      assert cache_control(conn) =~ "no-store"
    end

    test "imgproxy /info complete body" do
      conn = call(ImagePipe.Plug, @imgproxy_info, imgproxy_opts(none_sources()))

      assert conn.status == 200
      assert get_resp_header(conn, "etag") == []
      assert cache_control(conn) =~ "no-store"
    end

    test "native streamed image" do
      conn = call(ImagePipe.Plug, @native_image, native_opts(none_sources()))

      assert conn.status == 200
      assert get_resp_header(conn, "etag") == []
      assert cache_control(conn) =~ "no-store"
    end

    test "native blurhash complete body" do
      conn = call(ImagePipe.Plug, @native_blurhash, native_opts(none_sources()))

      assert conn.status == 200
      assert get_resp_header(conn, "etag") == []
      assert cache_control(conn) =~ "no-store"
    end
  end

  describe "a strong byte_identity source emits an ETag and no no-store" do
    test "imgproxy streamed image" do
      conn = call(ImagePipe.Plug, @imgproxy_image, imgproxy_opts(strong_sources()))

      assert conn.status == 200
      assert [etag] = get_resp_header(conn, "etag")
      assert etag != ""
      refute cache_control(conn) =~ "no-store"
    end

    test "native streamed image" do
      conn = call(ImagePipe.Plug, @native_image, native_opts(strong_sources()))

      assert conn.status == 200
      assert [etag] = get_resp_header(conn, "etag")
      assert etag != ""
      refute cache_control(conn) =~ "no-store"
    end
  end
end
