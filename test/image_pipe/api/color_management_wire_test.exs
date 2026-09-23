defmodule ImagePipe.API.ColorManagementWireTest do
  use ExUnit.Case, async: true

  import Plug.Conn
  import Plug.Test

  alias ImagePipe.Output.ColorProfile
  alias ImagePipe.SourceTest.RootHTTPAdapter
  alias ImagePipe.Test.PlugFixture.CacheProbe
  alias Vix.Vips.Image, as: VipsImage
  alias Vix.Vips.MutableImage
  alias Vix.Vips.Operation

  @sources "test/support/image_pipe/test/sources"

  test "unprofiled linear TIFF preserves pixels with and without resize" do
    image =
      Image.new!(240, 160, color: [20, 90, 180])
      |> Image.Draw.rect!(10, 20, 100, 70, color: [240, 40, 20])

    {:ok, linear} = Operation.colourspace(image, :VIPS_INTERPRETATION_scRGB)
    body = Image.write!(linear, :memory, suffix: ".tif")
    decoded = Image.from_binary!(body)
    assert VipsImage.interpretation(decoded) == :VIPS_INTERPRETATION_scRGB
    assert header(decoded, "icc-profile-data") == nil
    {:ok, reference} = Operation.colourspace(decoded, :VIPS_INTERPRETATION_sRGB)

    config = body_source(body, "image/tiff") |> ImagePipe.Plug.init()

    for {options, expected} <- [
          {"", reference},
          {"w=80/", Image.resize!(reference, 1 / 3, vertical_scale: 53 / 160)}
        ] do
      response = conn(:get, "/#{options}format=png/src/linear.tif") |> ImagePipe.Plug.call(config)
      actual = decoded(response)
      assert Image.shape(actual) == Image.shape(expected)
      assert pixels(actual) == pixels(expected)
      assert header(actual, "icc-profile-data") == nil
    end
  end

  test "wide-gamut source pixels are converted once before PNG delivery" do
    source = Image.open!(@sources <> "/icc_p3.png", access: :random)
    assert {:ok, profile} = VipsImage.header_value(source, "icc-profile-data")
    assert byte_size(profile) > 0

    {:ok, imported} = Operation.icc_import(source, embedded: true, pcs: :VIPS_PCS_XYZ)
    {:ok, reference} = Operation.colourspace(imported, :VIPS_INTERPRETATION_sRGB)

    config =
      ImagePipe.Plug.init(
        sources: [path: {ImagePipe.Source.File, root: @sources, root_id: "wide-gamut"}]
      )

    conn =
      conn(:get, "/format=png/src/icc_p3.png")
      |> ImagePipe.Plug.call(config)

    assert conn.status == 200
    actual = Image.from_binary!(conn.resp_body)
    assert VipsImage.write_to_binary(actual) == VipsImage.write_to_binary(reference)
    refute VipsImage.write_to_binary(actual) == VipsImage.write_to_binary(source)
  end

  test "preserving a wide-gamut profile restores its encoding after processing" do
    source = source("icc_p3.png")
    profile = header(source, "icc-profile-data")
    assert is_binary(profile)

    for geometry <- ["", "w=128/"] do
      kept = response("#{geometry}format=png/profile=preserve", "icc_p3.png")
      stripped = response("#{geometry}format=png/profile=strip", "icc_p3.png")
      kept_image = decoded(kept)
      stripped_image = decoded(stripped)

      assert header(kept_image, "icc-profile-data") == profile
      assert header(stripped_image, "icc-profile-data") == nil
      refute pixels(kept_image) == pixels(stripped_image)
      assert Image.shape(kept_image) == Image.shape(stripped_image)

      {:ok, expected} =
        VipsImage.mutate(stripped_image, fn mutable ->
          MutableImage.set(mutable, "icc-profile-data", :VipsBlob, profile)
        end)

      {:ok, expected} = Operation.icc_export(expected, pcs: :VIPS_PCS_XYZ, depth: 8)
      assert pixels(kept_image) == pixels(expected)
      refute etag(kept) == etag(stripped)
    end
  end

  test "named profiles transform pixels and embed the matching profile without geometry" do
    input = source("small.png")
    {:ok, srgb} = Operation.colourspace(input, :VIPS_INTERPRETATION_sRGB)

    for {name, target} <- [
          {"srgb", :srgb},
          {"display-p3", :display_p3},
          {"adobe-rgb", :adobe_rgb}
        ] do
      output = response("format=png/profile=#{name}", "small.png") |> decoded()
      profile_path = ColorProfile.path!(target)
      assert header(output, "icc-profile-data") == File.read!(profile_path)
      {:ok, expected} = Operation.icc_transform(srgb, profile_path, input_profile: "sRGB")
      assert pixels(output) == pixels(expected)
      assert Image.shape(output) == Image.shape(input)
    end
  end

  test "CMYK input becomes standard RGB or retains its source profile" do
    input = source("cmyk.jpg")
    assert VipsImage.interpretation(input) == :VIPS_INTERPRETATION_CMYK
    profile = header(input, "icc-profile-data")
    assert is_binary(profile)
    standard = response("format=png/profile=strip", "cmyk.jpg") |> decoded()
    {:ok, imported} = Operation.icc_import(input, embedded: true, pcs: :VIPS_PCS_LAB)
    {:ok, expected} = Operation.colourspace(imported, :VIPS_INTERPRETATION_sRGB)
    assert pixels(standard) == pixels(expected)
    assert VipsImage.bands(standard) == 3
    assert header(standard, "icc-profile-data") == nil

    kept = response("format=jpeg/profile=preserve", "cmyk.jpg") |> decoded()
    assert header(kept, "icc-profile-data") == profile
    assert VipsImage.interpretation(kept) == :VIPS_INTERPRETATION_CMYK
  end

  test "HDR preserves 16-bit pixels with and without resize, while tone mapping returns 8-bit" do
    input = source("rgb16.png")
    assert VipsImage.format(input) == :VIPS_FORMAT_USHORT

    for geometry <- ["", "w=200/"] do
      kept = response("#{geometry}format=png/hdr=preserve", "rgb16.png") |> decoded()
      mapped = response("#{geometry}format=png/hdr=tonemap", "rgb16.png") |> decoded()
      assert VipsImage.format(kept) == :VIPS_FORMAT_USHORT
      assert VipsImage.format(mapped) == :VIPS_FORMAT_UCHAR
      assert Image.shape(kept) == Image.shape(mapped)
      refute pixels(kept) == pixels(mapped)
    end

    kept = response("format=png/hdr=preserve", "rgb16.png") |> decoded()
    assert pixels(kept) == pixels(input)
    jpeg = response("format=jpeg/hdr=preserve", "rgb16.png") |> decoded()
    assert VipsImage.format(jpeg) == :VIPS_FORMAT_UCHAR
  end

  test "high-bit-depth alpha survives preserved HDR and rescales under tone mapping" do
    fixture = source("rgba16.png")
    {:ok, coordinates} = Operation.xyz(Image.width(fixture), Image.height(fixture))
    {:ok, x} = Operation.extract_band(coordinates, 0)
    {:ok, ramp} = Operation.linear(x, [65_535.0 / (Image.width(fixture) - 1)], [0.0])
    {:ok, ramp} = Operation.cast(ramp, :VIPS_FORMAT_USHORT)
    {:ok, rgb} = Operation.extract_band(fixture, 0, n: 3)
    {:ok, input} = Operation.bandjoin([rgb, ramp])
    body = Image.write!(input, :memory, suffix: ".png")
    opts = body_source(body, "image/png")
    assert Image.has_alpha?(input)
    assert List.last(Image.get_pixel!(input, 128, 128)) in 16_000..17_000
    kept = response("format=png/hdr=preserve", "alpha.png", opts) |> decoded()
    mapped = response("format=png/hdr=tonemap", "alpha.png", opts) |> decoded()
    assert Image.has_alpha?(kept)
    assert Image.has_alpha?(mapped)
    assert VipsImage.format(kept) == :VIPS_FORMAT_USHORT
    assert VipsImage.format(mapped) == :VIPS_FORMAT_UCHAR
    assert pixels(alpha(kept)) == pixels(alpha(input))
    {:ok, expected} = Operation.colourspace(input, :VIPS_INTERPRETATION_sRGB)
    assert pixels(alpha(mapped)) == pixels(alpha(expected))
  end

  test "URL profile and HDR policies override host defaults and canonicalize their identity" do
    opts = [strip_color_profile: false, preserve_hdr: true]
    configured = response("format=png", "rgb16.png", opts)
    explicit = response("format=png/profile=preserve/hdr=preserve", "rgb16.png")
    assert configured.status == 200
    assert configured.resp_body == explicit.resp_body
    assert etag(configured) == etag(explicit)

    overridden = response("format=png/profile=strip/hdr=tonemap", "rgb16.png", opts)
    baseline = response("format=png", "rgb16.png")
    assert overridden.status == 200
    assert overridden.resp_body == baseline.resp_body
    assert etag(overridden) == etag(baseline)
  end

  test "named profile conversion cannot silently discard requested HDR preservation" do
    origin = fn _conn -> flunk("conflicting color policy fetched its source") end

    guarded = [
      sources: [
        path: {RootHTTPAdapter, root_url: "http://origin.test", req_options: [plug: origin]}
      ],
      cache: {CacheProbe, []}
    ]

    for {options, opts} <- [
          {"format=png/profile=display-p3/hdr=preserve", []},
          {"format=png/profile=srgb", [preserve_hdr: true]}
        ] do
      response = response(options, "rgb16.png", guarded ++ opts)
      assert response.status == 400
      refute_received {:cache_lookup, _key}
      refute_received {:cache_put, _key, _body}
    end

    response =
      response("format=png/profile=display-p3/hdr=tonemap", "rgb16.png", preserve_hdr: true)

    assert response.status == 200
    assert response |> decoded() |> VipsImage.format() == :VIPS_FORMAT_UCHAR
  end

  test "preserving a corrupt embedded profile keeps decode failure classification" do
    profile = <<1, 2, 3, 4>>

    <<0xFF, 0xD8, jpeg::binary>> =
      Image.new!(16, 16, color: [100], bands: 1) |> Image.write!(:memory, suffix: ".jpg")

    payload = <<"ICC_PROFILE", 0, 1, 1, profile::binary>>
    body = <<0xFF, 0xD8, 0xFF, 0xE2, byte_size(payload) + 2::16, payload::binary, jpeg::binary>>
    assert header(Image.from_binary!(body), "icc-profile-data") == profile
    assert VipsImage.bands(Image.from_binary!(body)) == 1
    prefix = [:api_malformed_icc]
    event = prefix ++ [:request, :stop]
    handler = {__MODULE__, make_ref()}
    pid = self()

    :ok =
      :telemetry.attach(
        handler,
        event,
        fn _, _, meta, _ -> send(pid, {:result, meta.result, meta[:error]}) end,
        nil
      )

    on_exit(fn -> :telemetry.detach(handler) end)

    origin = fn conn -> conn |> put_resp_content_type("image/jpeg") |> send_resp(200, body) end

    config =
      ImagePipe.Plug.init(
        sources: [
          path: {RootHTTPAdapter, root_url: "http://origin.test", req_options: [plug: origin]}
        ],
        telemetry_prefix: prefix
      )

    response =
      conn(:get, "/format=png/profile=preserve/src/invalid.jpg") |> ImagePipe.Plug.call(config)

    assert response.status == 415
    assert_received {:result, :processing_error, :decode}

    fallback =
      conn(:get, "/format=png/profile=strip/src/invalid.jpg") |> ImagePipe.Plug.call(config)

    assert fallback.status == 200
  end

  defp source(name), do: Image.open!(Path.join(@sources, name), access: :random)

  defp body_source(body, content_type) do
    origin = fn conn -> conn |> put_resp_content_type(content_type) |> send_resp(200, body) end

    [
      sources: [
        path: {RootHTTPAdapter, root_url: "http://origin.test", req_options: [plug: origin]}
      ]
    ]
  end

  defp response(options, name, opts \\ []) do
    config =
      [
        sources: [
          path: {ImagePipe.Source.File, root: @sources, root_id: "api-color", stable: :trusted}
        ],
        http_cache: [mode: :enabled]
      ]
      |> Keyword.merge(opts)
      |> ImagePipe.Plug.init()

    conn(:get, "/#{options}/src/#{name}") |> ImagePipe.Plug.call(config)
  end

  defp decoded(response) do
    assert response.status == 200
    Image.from_binary!(response.resp_body)
  end

  defp pixels(image), do: VipsImage.write_to_binary(image)

  defp alpha(image) do
    {:ok, alpha} = Operation.extract_band(image, VipsImage.bands(image) - 1)
    alpha
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
end
