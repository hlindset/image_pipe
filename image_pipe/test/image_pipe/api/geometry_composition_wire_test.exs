defmodule ImagePipe.API.GeometryCompositionWireTest do
  use ExUnit.Case, async: false

  import Plug.Conn
  import Plug.Test

  alias ImagePipe.SourceTest.RootHTTPAdapter
  alias ImagePipe.Test.Orientation1TwinOrigin
  alias ImagePipe.Test.OrientedFrameOrigin
  alias Vix.Vips.Image, as: VipsImage
  alias Vix.Vips.Operation

  test "a later percentage region resolves against the preceding resize" do
    response =
      request(
        "/w=300/h=200/-/region=10pct,10pct,50pct,50pct/format=png/src/image.png",
        png_origin(marked(600, 400))
      )

    assert response.status == 200
    assert dimensions(response) == {150, 100}
  end

  test "auto resize classifies against a preceding region crop" do
    response =
      request(
        "/region=0,0,200,400/w=300/h=200/fit=auto/format=png/src/image.png",
        png_origin(marked(600, 400))
      )

    assert response.status == 200
    assert dimensions(response) == {100, 200}
  end

  test "padding creates transparent pixels that an opaque background flattens" do
    origin = png_origin(marked(2, 2))

    transparent = image("/pad=1,0,0,1/format=png/src/image.png", origin)
    assert {Image.width(transparent), Image.height(transparent)} == {3, 3}
    assert Image.get_pixel!(transparent, 0, 0) == [0, 0, 0, 0]

    opaque = image("/pad=1,0,0,1/bg=ff0000/format=png/src/image.png", origin)
    assert {Image.width(opaque), Image.height(opaque)} == {3, 3}
    assert Image.get_pixel!(opaque, 0, 0) == [255, 0, 0]
  end

  test "an opaque background on a grayscale image uses the color's gray value" do
    gray = image("/pad=1,0,0,1/bg=808080/format=png/src/image.png", png_origin(gray(:uchar)))
    assert Image.get_pixel!(gray, 0, 0) == [128]

    gray16 =
      image(
        "/pad=1,0,0,1/bg=808080/hdr=preserve/format=png/src/image.png",
        png_origin(gray(:ushort))
      )

    assert Image.get_pixel!(gray16, 0, 0) == [128 * 257]
  end

  test "an opaque color background promotes a grayscale image to RGB" do
    rgb = image("/pad=1,0,0,1/bg=ff0000/format=png/src/image.png", png_origin(gray(:uchar)))
    assert VipsImage.interpretation(rgb) == :VIPS_INTERPRETATION_sRGB
    assert Image.get_pixel!(rgb, 0, 0) == [255, 0, 0]
    assert Image.get_pixel!(rgb, 1, 1) == [50, 50, 50]

    rgb16 =
      image(
        "/pad=1,0,0,1/bg=ff0000/hdr=preserve/format=png/src/image.png",
        png_origin(gray(:ushort))
      )

    assert VipsImage.interpretation(rgb16) == :VIPS_INTERPRETATION_RGB16
    assert Image.get_pixel!(rgb16, 0, 0) == [65_535, 0, 0]
    assert Image.get_pixel!(rgb16, 1, 1) == List.duplicate(50 * 257, 3)
  end

  test "an arbitrary rotation of a grayscale image has transparent corners" do
    output = image("/rotate=30/format=png/src/image.png", png_origin(gray(:uchar, 20)))
    assert VipsImage.interpretation(output) == :VIPS_INTERPRETATION_B_W
    assert Image.get_pixel!(output, 0, 0) == [0, 0]

    assert Image.get_pixel!(output, div(Image.width(output), 2), div(Image.height(output), 2)) ==
             [50, 255]
  end

  test "padding, canvas and rotation keep a 16-bit image opaque" do
    for options <- ["pad=1,0,0,1", "w=40/h=40/fit=contain/extend", "rotate=30"] do
      output =
        image(
          "/#{options}/hdr=preserve/format=png/src/image.png",
          png_origin(gray(:ushort, 20))
        )

      centre = Image.get_pixel!(output, div(Image.width(output), 2), div(Image.height(output), 2))
      assert centre == [50 * 257, 65_535], options
    end
  end

  test "an alpha background preserves alpha in generated padding" do
    padded =
      image(
        "/pad=1,0,0,1/bg=ff0000,0.5/format=png/src/image.png",
        png_origin(marked(2, 2))
      )

    assert {Image.width(padded), Image.height(padded)} == {3, 3}
    assert Image.get_pixel!(padded, 0, 0) == [255, 0, 0, 128]
  end

  test "EXIF orientation is applied before an arbitrary-angle rotation" do
    base = marked(40, 80)
    path = "/rotate=30/format=png/src/image.jpg"

    oriented = image(path, {OrientedFrameOrigin, {base, 6}})
    twin = image(path, {Orientation1TwinOrigin, {base, 6}})

    assert {Image.width(oriented), Image.height(oriented)} ==
             {Image.width(twin), Image.height(twin)}

    assert VipsImage.write_to_binary(oriented) == VipsImage.write_to_binary(twin)
  end

  defp request(path, origin) do
    config =
      ImagePipe.Plug.init(
        sources: [
          path: [
            adapter: RootHTTPAdapter,
            match: :path,
            options: [root_url: "http://origin.test", req_options: [plug: origin]]
          ]
        ],
        max_body_bytes: 10_000_000,
        max_input_pixels: 40_000_000
      )

    conn(:get, path) |> ImagePipe.Plug.call(config)
  end

  defp image(path, origin) do
    response = request(path, origin)
    assert response.status == 200
    Image.from_binary!(response.resp_body)
  end

  defp dimensions(response) do
    output = Image.from_binary!(response.resp_body)
    {Image.width(output), Image.height(output)}
  end

  defp png_origin(body) do
    fn conn ->
      conn
      |> put_resp_content_type("image/png")
      |> send_resp(200, body)
    end
  end

  defp gray(format, size \\ 2)

  defp gray(:uchar, size) do
    {:ok, image} = Operation.black(size, size)
    {:ok, image} = Operation.linear(image, [1.0], [50.0])
    {:ok, image} = Operation.cast(image, :VIPS_FORMAT_UCHAR)
    {:ok, image} = Operation.copy(image, interpretation: :VIPS_INTERPRETATION_B_W)
    Image.write!(image, :memory, suffix: ".png")
  end

  defp gray(:ushort, size) do
    {:ok, image} = Operation.black(size, size)
    {:ok, image} = Operation.linear(image, [1.0], [50.0 * 257])
    {:ok, image} = Operation.cast(image, :VIPS_FORMAT_USHORT)
    {:ok, image} = Operation.copy(image, interpretation: :VIPS_INTERPRETATION_GREY16)
    Image.write!(image, :memory, suffix: ".png")
  end

  defp marked(width, height) do
    width
    |> Image.new!(height, color: [10, 20, 30])
    |> Image.Draw.rect!(0, 0, div(width, 2), div(height, 2), color: [240, 40, 40])
    |> Image.Draw.rect!(div(width, 2), 0, width - div(width, 2), div(height, 2),
      color: [40, 240, 40]
    )
    |> Image.Draw.rect!(0, div(height, 2), div(width, 2), height - div(height, 2),
      color: [40, 40, 240]
    )
    |> Image.write!(:memory, suffix: ".png")
  end
end
