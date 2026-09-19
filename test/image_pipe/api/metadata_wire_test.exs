defmodule ImagePipe.API.MetadataWireTest do
  use ExUnit.Case, async: false

  import Plug.Conn
  import Plug.Test

  alias ImagePipe.SourceTest.RootHTTPAdapter
  alias ImagePipe.Test.PlugFixture.CacheProbe
  alias Vix.Vips.Image, as: VipsImage
  alias Vix.Vips.MutableImage, as: VipsMutableImage

  @moduletag timeout: 180_000

  test "metadata modes retain or remove the requested fields with and without geometry" do
    kept = response("format=jpeg/meta=keep", mount())
    assert_image(kept, {100, 100})
    assert_metadata(kept, :keep)

    copyright = response("w=50/format=jpeg/meta=copyright", mount())
    assert_image(copyright, {50, 50})
    assert_metadata(copyright, :copyright)

    stripped = response("format=jpeg/meta=strip", mount())
    assert_image(stripped, {100, 100})
    assert_metadata(stripped, :strip)
  end

  test "URL metadata policy overrides either host metadata policy" do
    host_keeps = mount(strip_metadata: false, keep_copyright: false)
    assert_metadata(response("format=jpeg", host_keeps), :keep)
    assert_metadata(response("format=jpeg/meta=strip", host_keeps), :strip)

    host_strips = mount(strip_metadata: true, keep_copyright: false)
    assert_metadata(response("format=jpeg", host_strips), :strip)
    assert_metadata(response("format=jpeg/meta=keep", host_strips), :keep)
    assert_metadata(response("format=jpeg/meta=copyright", host_strips), :copyright)
  end

  test "the implicit copyright policy shares identity and cache while other modes vary" do
    config = mount(cache: stateful_cache_probe())

    implicit = response("format=jpeg", config)
    assert implicit.status == 200
    assert_receive :origin_fetch
    assert_receive {:cache_lookup, implicit_key}
    assert_receive {:cache_put, put_key, _body}
    assert put_key.hash == implicit_key.hash

    explicit = response("format=jpeg/meta=copyright", config)
    assert explicit.status == 200
    assert_receive {:cache_lookup, explicit_key}
    assert explicit_key.hash == implicit_key.hash
    refute_receive :origin_fetch
    refute_receive {:cache_put, _key, _body}
    assert explicit.resp_body == implicit.resp_body
    assert etag(explicit) == etag(implicit)

    stripped = response("format=jpeg/meta=strip", config)
    assert stripped.status == 200
    assert_receive :origin_fetch
    assert_receive {:cache_lookup, stripped_key}
    assert_receive {:cache_put, stripped_put_key, _body}
    assert stripped_put_key.hash == stripped_key.hash
    refute stripped_key.hash == implicit_key.hash
    refute etag(stripped) == etag(implicit)
    refute stripped.resp_body == implicit.resp_body

    kept = response("format=jpeg/meta=keep", config)
    assert kept.status == 200
    assert_receive :origin_fetch
    assert_receive {:cache_lookup, kept_key}
    assert_receive {:cache_put, kept_put_key, _body}
    assert kept_put_key.hash == kept_key.hash
    refute kept_key.hash in [implicit_key.hash, stripped_key.hash]
    refute etag(kept) in [etag(implicit), etag(stripped)]

    cached = response("format=jpeg/meta=keep", config)
    assert cached.status == 200
    assert_receive {:cache_lookup, cached_key}
    assert cached_key.hash == kept_key.hash
    refute_receive :origin_fetch
    refute_receive {:cache_put, _key, _body}
    assert cached.resp_body == kept.resp_body
    assert etag(cached) == etag(kept)
  end

  test "image-only URL output policies reject BlurHash before source or cache access" do
    config = mount(cache: {CacheProbe, []})

    for options <- [
          "output=blurhash/meta=strip",
          "output=blurhash/profile=srgb",
          "output=blurhash/hdr=preserve"
        ] do
      assert response(options, config).status == 400, options
      refute_received :origin_fetch
      refute_received {:cache_lookup, _key}
      refute_received {:cache_put, _key, _body}
    end
  end

  test "BlurHash ignores configured image metadata, profile, and HDR policies" do
    plain = response("output=blurhash", mount())

    configured =
      response(
        "output=blurhash",
        mount(
          strip_metadata: false,
          keep_copyright: false,
          strip_color_profile: false,
          preserve_hdr: true
        )
      )

    assert plain.status == 200
    assert configured.status == 200
    assert get_resp_header(configured, "content-type") == ["text/plain; charset=utf-8"]
    assert get_resp_header(configured, "vary") == []
    assert configured.resp_body == plain.resp_body
  end

  defp response(options, config) do
    conn(:get, "/#{options}/src/metadata.jpg")
    |> ImagePipe.Plug.call(config)
  end

  defp assert_image(response, dimensions) do
    assert response.status == 200
    assert get_resp_header(response, "content-type") == ["image/jpeg"]
    image = Image.from_binary!(response.resp_body)
    assert {Image.width(image), Image.height(image)} == dimensions
  end

  defp assert_metadata(response, expected) do
    assert response.status == 200
    image = Image.from_binary!(response.resp_body)
    {:ok, fields} = VipsImage.header_field_names(image)
    {:ok, exif} = Image.exif(image)

    case expected do
      :keep ->
        assert exif[:copyright] == "(c) ACME"
        assert exif[:artist] == "ImagePipe Artist"
        assert exif[:image_description] == "A test image"
        assert "xmp-data" in fields

      :copyright ->
        assert exif[:copyright] == "(c) ACME"
        assert exif[:artist] == "ImagePipe Artist"
        refute Map.has_key?(exif, :image_description)
        refute "xmp-data" in fields

      :strip ->
        refute Map.has_key?(exif, :copyright)
        refute Map.has_key?(exif, :artist)
        refute Map.has_key?(exif, :image_description)
        refute "xmp-data" in fields
    end
  end

  defp etag(response) do
    assert [etag] = get_resp_header(response, "etag")
    etag
  end

  defp stateful_cache_probe do
    table = :ets.new(:api_metadata_wire_cache_probe, [:set, :public])
    {CacheProbe, store: table}
  end

  defp mount(overrides \\ []) do
    body = metadata_jpeg()
    pid = self()

    origin = fn conn ->
      send(pid, :origin_fetch)
      conn |> put_resp_content_type("image/jpeg") |> send_resp(200, body)
    end

    [
      sources: [
        path:
          {RootHTTPAdapter,
           root_url: "http://origin.test",
           byte_identity: :strong,
           internal_cache: :enabled,
           req_options: [plug: origin]}
      ],
      http_cache: [mode: :enabled],
      max_body_bytes: 10_000_000,
      max_input_pixels: 40_000_000
    ]
    |> Keyword.merge(overrides)
    |> ImagePipe.Plug.init()
  end

  defp metadata_jpeg do
    image = Image.new!(100, 100, color: :white)

    {:ok, with_metadata} =
      VipsImage.mutate(image, fn mutable ->
        VipsMutableImage.set(mutable, "exif-ifd0-Copyright", :gchararray, "(c) ACME")
        VipsMutableImage.set(mutable, "exif-ifd0-Artist", :gchararray, "ImagePipe Artist")

        VipsMutableImage.set(
          mutable,
          "exif-ifd0-ImageDescription",
          :gchararray,
          "A test image"
        )

        VipsMutableImage.set(mutable, "xmp-data", :VipsBlob, "<x:xmpmeta/>")
        :ok
      end)

    Image.write!(with_metadata, :memory, suffix: ".jpg")
  end
end
