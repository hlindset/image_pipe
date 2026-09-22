defmodule ImagePipe.API.RetainedEffectsWireTest do
  use ExUnit.Case, async: true

  import Plug.Conn
  import Plug.Test

  alias ImagePipe.SourceTest.RootHTTPAdapter
  alias ImagePipe.Test.OrientedFrameOrigin
  alias Vix.Vips.Image, as: Vimage

  defp source do
    Image.new!(40, 20, color: [230, 20, 50])
    |> Image.compose!(Image.new!(20, 20, color: [240, 240, 240]), x: 20, y: 0)
  end

  defp request(options, orientation \\ nil) do
    body = Image.write!(source(), :memory, suffix: ".png")

    origin =
      if orientation do
        {OrientedFrameOrigin, {body, orientation}}
      else
        fn conn -> conn |> put_resp_content_type("image/png") |> send_resp(200, body) end
      end

    config =
      ImagePipe.Plug.init(
        sources: [
          path: {RootHTTPAdapter, root_url: "http://origin.test", req_options: [plug: origin]}
        ]
      )

    conn(:get, "/#{options}/format=png/src/image.png") |> ImagePipe.Plug.call(config)
  end

  defp image(options, orientation \\ nil) do
    response = request(options, orientation)
    assert response.status == 200
    Image.from_binary!(response.resp_body)
  end

  defp color_at(image, x, y) do
    pixel = Image.get_pixel!(image, x, y)
    if Image.has_alpha?(image), do: Enum.drop(pixel, -1), else: pixel
  end

  test "arbitrary rotation works without a resize and preserves transparent corners" do
    rotated = image("rotate=30")
    assert Image.width(rotated) > 40
    assert Image.height(rotated) > 20
    assert Image.has_alpha?(rotated)
    assert List.last(Image.get_pixel!(rotated, 0, 0)) == 0
  end

  test "rotation precedes crop and resize regardless of URL order" do
    first = request("rotate=90/region=0,0,20,20/w=10")
    second = request("w=10/region=0,0,20,20/rotate=90")
    assert first.status == 200
    assert first.resp_body == second.resp_body
    output = Image.from_binary!(first.resp_body)
    assert {Image.width(output), Image.height(output)} == {10, 10}
    assert [red, green, _blue] = color_at(output, 5, 5)
    assert red > green * 4
  end

  test "EXIF orientation is applied once across rotated groups" do
    output = image("rotate=90/-/rotate=90", 6)
    assert {Image.width(output), Image.height(output)} == {20, 40}
    assert [red, green, _blue] = color_at(output, 10, 30)
    assert red > green * 4
  end

  test "quarter turns compose with every EXIF orientation" do
    for orientation <- 1..8, angle <- [90, 180, 270] do
      baseline = image("rotate=0", orientation)
      expected = Image.rotate!(baseline, angle)
      actual = image("rotate=#{angle}", orientation)

      assert {Image.width(actual), Image.height(actual)} ==
               {Image.width(expected), Image.height(expected)}

      assert Vimage.write_to_binary(actual) == Vimage.write_to_binary(expected)
    end
  end

  test "grayscale changes pixels without requiring geometry" do
    gray = image("gray")
    assert {Image.width(gray), Image.height(gray)} == {40, 20}
    assert [_luminance] = gray |> color_at(5, 5) |> Enum.uniq()
    refute color_at(gray, 5, 5) == color_at(source(), 5, 5)
  end

  test "flips work without geometry after rotation in every EXIF frame" do
    for orientation <- 1..8,
        {value, axes} <- [
          {"h", [:horizontal]},
          {"v", [:vertical]},
          {"hv", [:horizontal, :vertical]}
        ] do
      baseline = image("rotate=90", orientation)
      expected = Enum.reduce(axes, baseline, &Image.flip!(&2, &1))
      actual = image("flip=#{value}/rotate=90", orientation)

      assert Vimage.write_to_binary(actual) == Vimage.write_to_binary(expected)
    end
  end

  test "flip precedes region crop regardless of URL order" do
    first = request("flip=h/region=0,0,20,20/w=10")
    second = request("w=10/region=0,0,20,20/flip=h")
    assert first.status == 200
    assert first.resp_body == second.resp_body
    output = Image.from_binary!(first.resp_body)
    assert color_at(output, 5, 5) == [240, 240, 240]
  end

  test "later groups rotate the completed result of earlier flips" do
    for flip <- ["h", "v", "hv"], angle <- [90, 180, 270], orientation <- [1, 6] do
      baseline = image("rotate=90/flip=#{flip}", orientation)
      expected = Image.rotate!(baseline, angle)
      actual = image("rotate=90/flip=#{flip}/-/rotate=#{angle}", orientation)

      assert Vimage.write_to_binary(actual) == Vimage.write_to_binary(expected)
    end
  end

  test "bitonal produces black and white pixels without requiring geometry" do
    bitonal = image("bitonal")
    assert Enum.uniq(color_at(bitonal, 5, 5)) == [0]
    assert Enum.uniq(color_at(bitonal, 30, 5)) == [255]
  end

  test "zero rotations and disabled effects have canonical identity" do
    baseline = request("rotate=0")

    for options <- ["rotate=360", "rotate=0.0/gray=false/bitonal=false"] do
      response = request(options)
      assert response.status == 200
      assert response.resp_body == baseline.resp_body
      assert get_resp_header(response, "etag") == get_resp_header(baseline, "etag")
    end
  end

  test "invalid rotation, flip, and effect values fail validation" do
    for options <- [
          "rotate=-1",
          "rotate=361",
          "rotate=abc",
          "flip=diagonal",
          "gray=yes",
          "bitonal=1"
        ] do
      assert request(options).status == 400
    end
  end
end
