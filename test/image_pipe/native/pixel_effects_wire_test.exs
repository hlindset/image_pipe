defmodule ImagePipe.Native.PixelEffectsWireTest do
  use ExUnit.Case, async: true

  import Plug.Conn
  import Plug.Test

  alias ImagePipe.SourceTest.RootHTTPAdapter
  alias ImagePipe.Test.Orientation1TwinOrigin
  alias ImagePipe.Test.OrientedFrameOrigin
  alias Vix.Vips.Image, as: VipsImage

  setup do
    source =
      Image.new!(47, 71, color: [80, 120, 160])
      |> Image.Draw.rect!(3, 5, 19, 27, color: [200, 70, 40])
      |> Image.Draw.rect!(24, 34, 17, 29, color: [40, 180, 90])
      |> Image.blur!(sigma: 1.0)

    body = Image.write!(source, :memory, suffix: ".png")
    %{body: body, config: mount(png_origin(body))}
  end

  for effect <- [
        "sharpen=2",
        "pixelate=7",
        "monochrome=0.8",
        "duotone=0.8,123456,efab89",
        "brightness=40",
        "contrast=1.8",
        "saturation=0.2",
        "colorize=0.5,red",
        "gradient=0.8,black,right,0.2,0.8"
      ] do
    test "#{effect} changes pixels without geometry", %{config: config} do
      baseline = image("", config)
      changed = image(unquote(effect), config)
      assert dimensions(changed) == dimensions(baseline)
      refute pixels(changed) == pixels(baseline)
    end
  end

  test "effects use fixed order and then explicitly changes that order", %{config: config} do
    options = ["w=23", "brightness=40", "contrast=1.8", "colorize=0.3,blue", "gradient=0.5,black"]
    forward = response(Enum.join(options, "/"), config)
    reverse = response(options |> Enum.reverse() |> Enum.join("/"), config)
    assert forward.status == 200
    assert forward.resp_body == reverse.resp_body
    assert etag(forward) == etag(reverse)

    fixed = image("brightness=40/contrast=1.8", config)
    separated = image("contrast=1.8/then/brightness=40", config)
    refute pixels(fixed) == pixels(separated)

    single = image("colorize=0.5,red/w=23", config)
    later = image("colorize=0.5,red/w=23/then/pad=0", config)
    assert pixels(single) == pixels(later)
    twice = image("colorize=0.5,red/w=23/then/colorize=0.5,red", config)
    refute pixels(single) == pixels(twice)
  end

  test "monochrome and duotone accept grayscale and bitonal input", %{config: config} do
    for first <- ["gray", "bitonal"],
        second <- ["monochrome=0.8,red", "duotone=1,123456,efab89"] do
      baseline = image(first, config)
      tinted = image("#{first}/#{second}", config)
      reordered = image("#{second}/#{first}", config)
      assert dimensions(tinted) == dimensions(baseline)
      assert VipsImage.bands(tinted) == 3
      assert length(Enum.uniq(Image.get_pixel!(tinted, 35, 50))) > 1
      assert pixels(tinted) == pixels(reordered)
      staged = image("#{first}/then/#{second}", config)
      assert pixels(tinted) == pixels(staged)
    end
  end

  test "tinting grayscale input preserves alpha" do
    body =
      Image.new!(13, 9, color: [200, 100, 50, 128], bands: 4)
      |> Image.write!(:memory, suffix: ".png")

    config = mount(png_origin(body))

    for first <- ["gray", "bitonal"],
        second <- ["monochrome=0.8,red", "duotone=1,123456,efab89"] do
      tinted = image("#{first}/#{second}", config)
      assert Image.has_alpha?(tinted)
      assert List.last(Image.get_pixel!(tinted, 5, 4)) == 128
      assert VipsImage.bands(tinted) == 4
    end
  end

  test "identity values disappear from response identity", %{config: config} do
    baseline = response("", config)

    for options <- [
          "sharpen=0/pixelate=1/brightness=0/contrast=1/saturation=1",
          "monochrome=0/duotone=0/colorize=0,red/gradient=0,blue",
          "sharpen=0.0/contrast=1.0/saturation=1.0/monochrome=0.0,fff"
        ] do
      actual = response(options, config)
      assert actual.status == 200
      assert actual.resp_body == baseline.resp_body
      assert etag(actual) == etag(baseline)
    end
  end

  test "color aliases and equivalent gradient directions share response identity", %{
    config: config
  } do
    for {a, b} <- [
          {"colorize=0.5,red", "colorize=0.50,ff0000"},
          {"gradient=0.5,black,right", "gradient=0.50,000,-90.0,0.0,1.0"},
          {"monochrome=1", "monochrome=1.0,b3b3b3"},
          {"duotone=1", "duotone=1.0,black,white"}
        ] do
      first = response(a, config)
      second = response(b, config)
      assert first.status == 200
      assert second.status == 200
      assert first.resp_body == second.resp_body
      assert etag(first) == etag(second)
    end
  end

  test "colorize controls alpha while gradient preserves it" do
    body =
      Image.new!(13, 9, color: [200, 100, 50, 128], bands: 4)
      |> Image.write!(:memory, suffix: ".png")

    config = mount(png_origin(body))
    opaque = image("colorize=0.5,black", config)
    preserved = image("colorize=0.5,black,keep-alpha", config)
    gradient = image("gradient=0.5,black", config)
    refute Image.has_alpha?(opaque)

    for output <- [preserved, gradient] do
      assert Image.has_alpha?(output)
      assert List.last(Image.get_pixel!(output, 5, 4)) == 128
    end

    assert pixels(image("colorize=0,black", config)) == pixels(image("", config))
  end

  test "gradient direction, reversed ramps and hard stops reach native pixels" do
    body = Image.new!(11, 11, color: :white) |> Image.write!(:memory, suffix: ".png")
    config = mount(png_origin(body))
    down = image("gradient=1,black,down", config)
    right = image("gradient=1,black,right", config)
    reversed = image("gradient=1,black,down,1,0", config)
    step = image("gradient=1,black,down,0.5,0.5", config)
    assert Image.get_pixel!(down, 0, 0) == [255, 255, 255]
    assert Image.get_pixel!(down, 0, 10) == [0, 0, 0]
    assert Image.get_pixel!(right, 10, 0) == [0, 0, 0]
    assert Image.get_pixel!(reversed, 0, 0) == [0, 0, 0]
    assert Image.get_pixel!(reversed, 0, 10) == [255, 255, 255]
    assert Image.get_pixel!(step, 0, 4) == [255, 255, 255]
    assert Image.get_pixel!(step, 0, 5) == [0, 0, 0]
  end

  test "pixelate and gradient use the display frame for every EXIF orientation", %{body: body} do
    for orientation <- 1..8,
        options <- ["pixelate=7", "gradient=1,black,down"] do
      oriented = image(options, mount({OrientedFrameOrigin, {body, orientation}}))
      twin = image(options, mount({Orientation1TwinOrigin, {body, orientation}}))
      assert dimensions(oriented) == dimensions(twin)

      assert pixels(oriented) == pixels(twin), "#{options}, EXIF #{orientation}"
    end
  end

  test "gradient addresses the realized display dimensions after resizing", %{body: body} do
    for orientation <- 1..8 do
      config = mount({OrientedFrameOrigin, {body, orientation}})
      resized = response("w=31", config)
      assert resized.status == 200
      expected = image("gradient=0.8,red,right", mount(png_origin(resized.resp_body)))
      actual = image("w=31/gradient=0.8,red,right", config)
      assert dimensions(actual) == dimensions(expected)
      assert pixels(actual) == pixels(expected), "EXIF #{orientation}"
    end
  end

  test "effect size stays in physical pixels when DPR changes", %{config: config} do
    for effect <- ["sharpen=2", "pixelate=7", "gradient=0.5,red,right"] do
      assert pixels(image(effect, config)) == pixels(image("dpr=2/#{effect}", config))
    end
  end

  test "invalid effects reject before source fetch", %{config: config} do
    for options <- [
          "sharpen=-1",
          "pixelate=0",
          "pixelate=1.5",
          "brightness=256",
          "contrast=0",
          "saturation=-1",
          "monochrome=1.1",
          "duotone=1,red",
          "colorize=0.5",
          "colorize=0.5,red,true",
          "gradient=0,notacolor",
          "gradient=1,red,diagonal",
          "gradient=1,red,down,0,1.1"
        ] do
      assert response(options, config).status == 400, options
      refute_received :origin_fetch
    end
  end

  defp response(options, config) do
    path = [options, "format=png", "src/image.png"] |> Enum.reject(&(&1 == "")) |> Enum.join("/")
    conn(:get, "/" <> path) |> ImagePipe.Plug.call(config)
  end

  defp image(options, config) do
    response = response(options, config)
    assert response.status == 200, "#{options}: HTTP #{response.status}"
    Image.from_binary!(response.resp_body)
  end

  defp etag(response) do
    assert [etag] = get_resp_header(response, "etag")
    etag
  end

  defp dimensions(image), do: {Image.width(image), Image.height(image)}
  defp pixels(image), do: VipsImage.write_to_binary(image)

  defp mount(origin) do
    ImagePipe.Plug.init(
      sources: [
        path:
          {RootHTTPAdapter,
           root_url: "http://origin.test", byte_identity: :strong, req_options: [plug: origin]}
      ],
      http_cache: [mode: :enabled]
    )
  end

  defp png_origin(body) do
    pid = self()

    fn conn ->
      send(pid, :origin_fetch)
      conn |> put_resp_content_type("image/png") |> send_resp(200, body)
    end
  end
end
