defmodule ImagePipe.API.TrimFrameWireTest do
  use ExUnit.Case, async: false
  use ExUnitProperties

  import Plug.Conn
  import Plug.Test

  alias ImagePipe.SourceTest.RootHTTPAdapter
  alias ImagePipe.Test.Orientation1TwinOrigin
  alias ImagePipe.Test.OrientedFrameOrigin
  alias Vix.Vips.Image, as: VipsImage

  test "automatic trim samples the displayed top-left after EXIF orientation" do
    source = source()

    for orientation <- 1..8 do
      oriented = image("trim=auto", {OrientedFrameOrigin, {source, orientation}})
      displayed = image("trim=auto", {Orientation1TwinOrigin, {source, orientation}})

      assert_same_pixels(oriented, displayed)
    end
  end

  test "automatic trim follows user rotation and flips within a group" do
    origin = png_origin(source())

    for options <- ["rotate=90", "rotate=180", "flip=h", "flip=v", "rotate=90/flip=h"] do
      transformed = image(options, origin)

      expected =
        image("trim=auto", png_origin(Image.write!(transformed, :memory, suffix: ".png")))

      actual = image(options <> "/trim=auto", origin)

      assert_same_pixels(actual, expected)
    end
  end

  test "a later trim uses the completed preceding group" do
    origin = png_origin(source())
    transformed = image("w=20/rotate=90", origin)
    expected = image("trim=auto", png_origin(Image.write!(transformed, :memory, suffix: ".png")))
    actual = image("w=20/rotate=90/-/trim=auto", origin)

    assert_same_pixels(actual, expected)
  end

  property "trim follows the display frame across source shapes and user orientation" do
    check all width <- integer(32..96),
              height <- integer(64..128),
              orientation <- integer(1..8),
              rotate <- member_of([0, 90, 180, 270]),
              flip <- member_of(["h", "v", "hv"]),
              max_runs: 24 do
      source = source(width, height)
      options = "rotate=#{rotate}/flip=#{flip}/trim=auto"

      actual = image(options, {OrientedFrameOrigin, {source, orientation}})
      expected = image(options, {Orientation1TwinOrigin, {source, orientation}})

      assert_same_pixels(actual, expected)
    end
  end

  defp assert_same_pixels(actual, expected) do
    assert {Image.width(actual), Image.height(actual)} ==
             {Image.width(expected), Image.height(expected)}

    assert VipsImage.write_to_binary(actual) == VipsImage.write_to_binary(expected)
  end

  defp image(options, origin) do
    config =
      ImagePipe.Plug.init(
        sources: [
          path: {RootHTTPAdapter, root_url: "http://origin.test", req_options: [plug: origin]}
        ]
      )

    response =
      conn(:get, "/" <> options <> "/format=png/src/image.png") |> ImagePipe.Plug.call(config)

    assert response.status == 200
    Image.from_binary!(response.resp_body)
  end

  defp png_origin(body) do
    fn conn -> conn |> put_resp_content_type("image/png") |> send_resp(200, body) end
  end

  defp source(width \\ 40, height \\ 80) do
    width
    |> Image.new!(height, color: :white)
    |> Image.Draw.rect!(10, 20, 16, 40, color: :red)
    |> Image.Draw.rect!(0, 0, 8, 8, color: :black)
    |> Image.write!(:memory, suffix: ".png")
  end
end
