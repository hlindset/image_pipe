defmodule ImagePipe.API.MetadataWireTest do
  use ExUnit.Case, async: false

  import Plug.Conn
  import Plug.Test

  alias ImagePipe.SourceTest.RootHTTPAdapter
  alias ImagePipe.Test.CacheObserver
  alias ImagePipe.Test.Caches
  alias Vix.Vips.Image, as: VipsImage
  alias Vix.Vips.MutableImage, as: VipsMutableImage
  alias Vix.Vips.Operation

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

  test "a malformed EXIF date strips all metadata instead of failing" do
    config = mount(body: metadata_jpeg(%{"exif-ifd0-DateTime" => "2024:01:01 02+02:00:00"}))

    assert_metadata(response("format=jpeg/meta=copyright", config), :strip)
    assert_metadata(response("format=avif/meta=strip", config), :strip)
  end

  test "an EXIF date stored as a number strips all metadata instead of failing" do
    config = mount(body: numeric_date_jpeg())

    assert_metadata(response("format=jpeg/meta=copyright", config), :strip)
    assert_metadata(response("format=webp", config), :strip)
  end

  test "an sRGB result without a profile has EXIF ColorSpace sRGB" do
    config = mount(body: wide_gamut_jpeg())

    for options <- ["format=jpeg/meta=keep", "w=50/format=webp/meta=keep"] do
      image = response(options, config) |> decoded()
      assert header(image, "icc-profile-data") == nil, options
      assert header(image, "exif-ifd0-WhitePoint") == nil, options
      assert header(image, "exif-ifd0-PrimaryChromaticities") == nil, options
      assert "1 (sRGB" <> _ = header(image, "exif-ifd2-ColorSpace"), options
    end

    untagged = mount(body: metadata_jpeg(%{"exif-ifd2-ColorSpace" => "1"}))
    image = response("format=jpeg/meta=keep", untagged) |> decoded()
    assert "1 (sRGB" <> _ = header(image, "exif-ifd2-ColorSpace")

    kept = response("format=jpeg/meta=keep/profile=preserve", config) |> decoded()
    assert is_binary(header(kept, "icc-profile-data"))
    assert "65535 (Uncalibrated" <> _ = header(kept, "exif-ifd2-ColorSpace")
    assert "313/1000" <> _ = header(kept, "exif-ifd0-WhitePoint")
  end

  test "a converted result with kept EXIF has the target's ColorSpace" do
    srgb = mount(body: metadata_jpeg(%{"exif-ifd2-ColorSpace" => "1"}))
    p3 = response("format=jpeg/meta=keep/profile=display-p3", srgb) |> decoded()
    assert is_binary(header(p3, "icc-profile-data"))
    assert "65535 (Uncalibrated" <> _ = header(p3, "exif-ifd2-ColorSpace")

    wide = mount(body: wide_gamut_jpeg())
    image = response("format=jpeg/meta=keep/profile=srgb", wide) |> decoded()
    assert "1 (sRGB" <> _ = header(image, "exif-ifd2-ColorSpace")
    assert header(image, "exif-ifd0-WhitePoint") == nil
    assert header(image, "exif-ifd0-PrimaryChromaticities") == nil
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
    config = observed_mount()

    implicit = response("format=jpeg", config)
    assert implicit.status == 200
    assert_receive :origin_fetch
    assert [implicit_key] = Enum.uniq(CacheObserver.lookup_hashes())
    assert_receive {:cache_put, put_key, _body}
    assert put_key == implicit_key

    explicit = response("format=jpeg/meta=copyright", config)
    assert explicit.status == 200
    assert [explicit_key] = Enum.uniq(CacheObserver.lookup_hashes())
    assert explicit_key == implicit_key
    refute_receive :origin_fetch
    refute_receive {:cache_put, _key, _body}
    assert explicit.resp_body == implicit.resp_body
    assert etag(explicit) == etag(implicit)

    stripped = response("format=jpeg/meta=strip", config)
    assert stripped.status == 200
    assert_receive :origin_fetch
    assert [stripped_key] = Enum.uniq(CacheObserver.lookup_hashes())
    assert_receive {:cache_put, stripped_put_key, _body}
    assert stripped_put_key == stripped_key
    refute stripped_key == implicit_key
    refute etag(stripped) == etag(implicit)
    refute stripped.resp_body == implicit.resp_body

    kept = response("format=jpeg/meta=keep", config)
    assert kept.status == 200
    assert_receive :origin_fetch
    assert [kept_key] = Enum.uniq(CacheObserver.lookup_hashes())
    assert_receive {:cache_put, kept_put_key, _body}
    assert kept_put_key == kept_key
    refute kept_key in [implicit_key, stripped_key]
    refute etag(kept) in [etag(implicit), etag(stripped)]

    cached = response("format=jpeg/meta=keep", config)
    assert cached.status == 200
    assert [cached_key] = Enum.uniq(CacheObserver.lookup_hashes())
    assert cached_key == kept_key
    refute_receive :origin_fetch
    refute_receive {:cache_put, _key, _body}
    assert cached.resp_body == kept.resp_body
    assert etag(cached) == etag(kept)
  end

  describe "output density" do
    test "stripping writes the host density and keep preserves the source density" do
      config = mount()

      assert_density(response("format=jpeg", config), :jpeg, 72)
      stripped = response("format=jpeg/meta=strip", config) |> decoded()
      assert round(VipsImage.xres(stripped) * 25.4) == 72
      assert_density(response("w=50/format=jpeg/meta=keep", config), :jpeg, 300)
      assert_density(response("gradient=0.5,black/format=jpeg/meta=keep", config), :jpeg, 300)

      host = mount(stripped_dpi: 96)
      assert_density(response("format=jpeg", host), :jpeg, 96)
      assert_density(response("format=jpeg/meta=keep", host), :jpeg, 300)
    end

    test "dpi replaces the density under every metadata policy and format" do
      config = mount()

      for meta <- ["strip", "copyright", "keep"] do
        assert_density(response("format=jpeg/meta=#{meta}/dpi=150", config), :jpeg, 150)
      end

      assert_density(response("w=50/format=png/dpi=150", config), :png, 150)
      assert_density(response("format=webp/dpi=150", config), :webp, 150)
      assert_density(response("format=avif/dpi=150", config), :avif, 150)
    end

    test "stripped output at 72 dpi has no EXIF block" do
      config = mount()

      for format <- ["jpeg", "png", "webp", "avif"] do
        image = response("format=#{format}/meta=strip", config) |> decoded()
        assert header(image, "exif-data") == nil, format
      end

      image = response("format=webp/meta=strip/dpi=150", config) |> decoded()
      assert header(image, "exif-ifd0-Copyright") == nil
      assert header(image, "exif-ifd0-ImageDescription") == nil
    end

    test "density leaves pixels and dimensions unchanged" do
      config = mount()
      plain = Image.from_binary!(response("w=50/format=png", config).resp_body)
      dense = Image.from_binary!(response("w=50/format=png/dpi=600", config).resp_body)

      assert {Image.width(dense), Image.height(dense)} == {50, 50}
      assert VipsImage.write_to_binary(dense) == VipsImage.write_to_binary(plain)
    end

    test "different densities have different cache keys and ETags" do
      config = observed_mount()

      implicit = response("format=jpeg", config)
      assert [implicit_key] = Enum.uniq(CacheObserver.lookup_hashes())

      explicit = response("format=jpeg/dpi=72", config)
      assert [explicit_key] = Enum.uniq(CacheObserver.lookup_hashes())
      assert explicit_key == implicit_key
      assert etag(explicit) == etag(implicit)

      other = response("format=jpeg/dpi=300", config)
      assert [other_key] = Enum.uniq(CacheObserver.lookup_hashes())
      refute other_key == implicit_key
      refute etag(other) == etag(implicit)
    end
  end

  test "BlurHash ignores image-only URL output policies" do
    plain = response("output=blurhash", mount())

    for options <- [
          "output=blurhash/meta=keep",
          "output=blurhash/profile=srgb",
          "output=blurhash/hdr=preserve",
          "output=blurhash/dpi=300"
        ] do
      ignored = response(options, mount())
      assert ignored.status == 200, options
      assert ignored.resp_body == plain.resp_body
      assert etag(ignored) == etag(plain)
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

    exif =
      case Image.exif(image) do
        {:ok, exif} -> exif
        {:error, _no_exif} -> %{}
      end

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

  # PNG carries density in pHYs, and the other formats in EXIF.
  # JFIF stores integer DPI; PNG stores pixels per metre and EXIF a
  # three-decimal rational, so compare to the nearest inch.
  defp assert_density(response, format, dpi) do
    assert response.status == 200
    assert get_resp_header(response, "content-type") == ["image/#{format}"]
    image = Image.from_binary!(response.resp_body)

    if format in [:jpeg, :png] do
      assert round(VipsImage.xres(image) * 25.4) == dpi
      assert round(VipsImage.yres(image) * 25.4) == dpi
    end

    if format != :png do
      {:ok, exif} = Image.exif(image)
      assert round(exif[:x_resolution]) == dpi
      assert round(exif[:y_resolution]) == dpi
    end
  end

  defp decoded(response) do
    assert response.status == 200
    Image.from_binary!(response.resp_body)
  end

  defp header(image, field) do
    case VipsImage.header_value(image, field) do
      {:ok, value} -> value
      {:error, _} -> nil
    end
  end

  defp etag(response) do
    assert [etag] = get_resp_header(response, "etag")
    etag
  end

  defp mount(overrides \\ []),
    do: overrides |> options() |> Keyword.put_new(:allow_unsigned, true) |> ImagePipe.Plug.init()

  defp observed_mount, do: [] |> options() |> CacheObserver.observe() |> Caches.plug()

  defp options(overrides) do
    {body, overrides} = Keyword.pop_lazy(overrides, :body, &metadata_jpeg/0)
    pid = self()

    origin = fn conn ->
      send(pid, :origin_fetch)
      conn |> put_resp_content_type("image/jpeg") |> send_resp(200, body)
    end

    [
      sources: [
        path: [
          adapter: RootHTTPAdapter,
          match: :path,
          options: [
            root_url: "http://origin.test",
            byte_identity: :strong,
            internal_cache: :enabled,
            req_options: [plug: origin]
          ]
        ]
      ],
      http_cache: :auto,
      max_body_bytes: 10_000_000,
      max_input_pixels: 40_000_000
    ]
    |> Keyword.merge(overrides)
  end

  defp metadata_jpeg(extra_fields \\ %{}) do
    {:ok, image} =
      Operation.copy(Image.new!(100, 100, color: :white),
        xres: 300 / 25.4,
        yres: 300 / 25.4
      )

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

        Enum.each(extra_fields, fn {field, value} ->
          VipsMutableImage.set(mutable, field, :gchararray, value)
        end)
      end)

    Image.write!(with_metadata, :memory, suffix: ".jpg")
  end

  # A wide-gamut camera JPEG: a Display P3 profile, with EXIF that marks the
  # colours as uncalibrated and records the P3 chromaticities.
  defp wide_gamut_jpeg do
    image = Image.open!("test/support/image_pipe/test/sources/icc_p3.png", access: :random)

    {:ok, tagged} =
      VipsImage.mutate(image, fn mutable ->
        VipsMutableImage.set(mutable, "exif-ifd0-WhitePoint", :gchararray, "313/1000 329/1000")

        VipsMutableImage.set(
          mutable,
          "exif-ifd0-PrimaryChromaticities",
          :gchararray,
          "680/1000 320/1000 265/1000 690/1000 150/1000 60/1000"
        )

        VipsMutableImage.set(mutable, "exif-ifd2-ColorSpace", :gchararray, "65535")
      end)

    Image.write!(tagged, :memory, suffix: ".jpg", strip_metadata: false)
  end

  # IFD0 DateTime stored as SHORT 2024, as some cameras and editors write it.
  defp numeric_date_jpeg do
    tiff =
      "II" <>
        <<42::little-16, 8::little-32, 1::little-16, 0x0132::little-16, 3::little-16,
          1::little-32, 2024::little-16, 0::16, 0::little-32>>

    {:ok, with_exif} =
      VipsImage.mutate(Image.new!(100, 100, color: :white), fn mutable ->
        VipsMutableImage.set(mutable, "exif-data", :VipsBlob, "Exif\0\0" <> tiff)
      end)

    Image.write!(with_exif, :memory, suffix: ".jpg")
  end
end
