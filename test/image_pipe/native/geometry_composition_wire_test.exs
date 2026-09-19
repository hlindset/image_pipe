defmodule ImagePipe.Native.GeometryCompositionWireTest do
  use ExUnit.Case, async: false

  import Plug.Conn
  import Plug.Test

  alias ImagePipe.SourceTest.RootHTTPAdapter
  alias ImagePipe.Test.Orientation1TwinOrigin
  alias ImagePipe.Test.OrientedFrameOrigin
  alias Vix.Vips.Image, as: VipsImage

  test "a later percentage region resolves against the preceding resize" do
    response =
      request(
        "/w=300/h=200/then/region=10pct,10pct,50pct,50pct/format=png/src/image.png",
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
          path: {RootHTTPAdapter, root_url: "http://origin.test", req_options: [plug: origin]}
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
