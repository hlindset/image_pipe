defmodule ImagePipe.API.OffsetCanvasWireTest do
  use ExUnit.Case, async: false

  import Plug.Conn
  import Plug.Test

  alias ImagePipe.SourceTest.RootHTTPAdapter
  alias ImagePipe.Test.Orientation1TwinOrigin
  alias ImagePipe.Test.OrientedFrameOrigin
  alias ImagePipe.Test.PlugFixture.CountingOriginImage
  alias Vix.Vips.Image, as: VipsImage

  @placement_source Path.expand(
                      "../../support/image_pipe/test/sources/placement.png",
                      __DIR__
                    )

  test "signed and fractional pixel anchor offsets move a guided crop after DPR scaling" do
    origin = png_origin(File.read!(@placement_source))

    for {options, region} <- [
          {"crop=800,600/anchor=center/anchor-offset=-10,5", "390,305,800,600"},
          {"crop=800,600/anchor=top-left/anchor-offset=0.49,0.49/dpr=2", "1,1,800,600"}
        ] do
      actual = image(options, origin)
      expected = image("region=#{region}", origin)
      assert_same_pixels(actual, expected)
    end
  end

  test "percentage anchor offsets use each crop input once at DPR 2" do
    origin = png_origin(File.read!(@placement_source))

    source_crop =
      image(
        "crop=800,600/anchor=top-left/anchor-offset=10pct,25pct/dpr=2",
        origin
      )

    assert_same_pixels(source_crop, image("region=160,300,800,600", origin))

    result_crop =
      image(
        "w=300/h=300/fit=cover/enlarge/anchor=top-left/anchor-offset=10pct,0/dpr=2",
        origin
      )

    resized = image("w=800/h=600/fit=stretch/enlarge", origin)
    expected = Image.crop!(resized, 80, 0, 600, 600)
    assert_same_pixels(result_crop, expected)
  end

  test "a source-crop offset uses the following resize's effective DPR" do
    origin = png_origin(File.read!(@placement_source))

    actual =
      image(
        "crop=60,40/anchor=top-left/anchor-offset=10,0/w=40/h=40/dpr=2",
        origin
      )

    expected = image("region=15,0,60,40/w=40/h=40/dpr=2", origin)
    assert_same_pixels(actual, expected)
  end

  test "one anchor offset guides a source crop and a following cover result crop" do
    origin = png_origin(File.read!(@placement_source))

    actual =
      image(
        "crop=120,80/anchor=top-left/anchor-offset=10,0/w=40/h=40/fit=cover",
        origin
      )

    expected =
      image(
        "region=10,0,120,80/then/w=60/h=40/fit=stretch/then/region=10,0,40,40",
        origin
      )

    assert_same_pixels(actual, expected)
  end

  test "an auto resize resolving to contain does not reuse the source-crop offset" do
    origin = png_origin(File.read!(@placement_source))

    actual =
      image(
        "crop=120,80/anchor=top-left/anchor-offset=10,0/w=30/h=40/fit=auto",
        origin
      )

    expected = image("region=10,0,120,80/w=30/h=40/fit=contain", origin)
    assert_same_pixels(actual, expected)
  end

  test "anchor offsets address near and far edges in every displayed EXIF frame" do
    source = marked_source()

    for orientation <- 1..8, anchor <- ["top-left", "bottom-right"] do
      options = "crop=20,20/anchor=#{anchor}/anchor-offset=5,7"
      oriented = image(options, {OrientedFrameOrigin, {source, orientation}})
      displayed = image(options, {Orientation1TwinOrigin, {source, orientation}})

      assert_same_pixels(oriented, displayed)
    end
  end

  test "box canvas uses effective DPR for its size and pixel offset" do
    origin = png_origin(solid_source(60, 30, [220, 30, 40]))

    output =
      image(
        "w=40/h=30/fit=contain/dpr=2/extend/extend-at=top/extend-offset=0,4",
        origin
      )

    assert dimensions(output) == {60, 45}
    assert transparent?(Image.get_pixel!(output, 30, 5))
    assert rgb(Image.get_pixel!(output, 30, 6)) == [220, 30, 40]
    assert rgb(Image.get_pixel!(output, 30, 35)) == [220, 30, 40]
    assert transparent?(Image.get_pixel!(output, 30, 36))
  end

  test "canvas placement follows displayed axes after EXIF and user rotation" do
    source = marked_source()

    options =
      "rotate=90/w=60/h=60/dpr=2/extend/extend-at=bottom-right/extend-offset=3,5pct"

    for orientation <- 1..8 do
      oriented = image(options, {OrientedFrameOrigin, {source, orientation}})
      displayed = image(options, {Orientation1TwinOrigin, {source, orientation}})
      assert_same_pixels(oriented, displayed)
    end
  end

  test "percentage canvas offsets use the realized target canvas without extra DPR" do
    origin = png_origin(solid_source(60, 30, [220, 30, 40]))

    output =
      image(
        "w=40/h=30/fit=contain/dpr=2/extend/extend-at=top/extend-offset=0,20pct",
        origin
      )

    assert dimensions(output) == {60, 45}
    assert transparent?(Image.get_pixel!(output, 30, 8))
    assert rgb(Image.get_pixel!(output, 30, 9)) == [220, 30, 40]
  end

  test "fractional canvas offsets scale before rounding" do
    origin = png_origin(solid_source(20, 10, [220, 30, 40]))

    output =
      image(
        "w=20/h=15/fit=contain/dpr=2/enlarge/extend/extend-at=top/extend-offset=0,0.49",
        origin
      )

    assert dimensions(output) == {40, 30}
    assert transparent?(Image.get_pixel!(output, 20, 0))
    assert rgb(Image.get_pixel!(output, 20, 1)) == [220, 30, 40]
  end

  test "zoom changes the resize but not the box canvas" do
    origin = png_origin(solid_source(40, 20, [220, 30, 40]))
    output = image("w=40/h=30/zoom=0.5/enlarge/extend", origin)

    assert dimensions(output) == {40, 30}
    assert transparent?(Image.get_pixel!(output, 9, 10))
    assert rgb(Image.get_pixel!(output, 10, 10)) == [220, 30, 40]
    assert rgb(Image.get_pixel!(output, 29, 19)) == [220, 30, 40]
    assert transparent?(Image.get_pixel!(output, 30, 19))
  end

  test "ratio canvas uses raw w:h and expands without cropping" do
    origin = png_origin(marked_source(40, 20))
    resized = image("w=40/h=30/zoom=0.5,1/enlarge", origin)
    output = image("w=40/h=30/zoom=0.5,1/enlarge/extend-ratio", origin)

    assert dimensions(resized) == {20, 10}
    assert dimensions(output) == {20, 15}
    assert Image.has_alpha?(output)
    assert_same_pixels(Image.crop!(output, 0, 3, 20, 10), Image.add_alpha!(resized, :opaque))
  end

  test "canvas is transparent before padding and background flattening" do
    origin = png_origin(solid_source(20, 10, [220, 30, 40]))

    transparent = image("w=20/h=15/enlarge/extend/pad=2,3,4,5", origin)
    assert dimensions(transparent) == {28, 21}
    assert transparent?(Image.get_pixel!(transparent, 0, 0))
    assert transparent?(Image.get_pixel!(transparent, 5, 4))
    assert rgb(Image.get_pixel!(transparent, 5, 5)) == [220, 30, 40]

    flattened = image("w=20/h=15/enlarge/extend/pad=2,3,4,5/bg=0000ff", origin)
    assert dimensions(flattened) == {28, 21}
    assert Image.get_pixel!(flattened, 0, 0) == [0, 0, 255]
    assert Image.get_pixel!(flattened, 5, 4) == [0, 0, 255]
    assert Image.get_pixel!(flattened, 5, 5) == [220, 30, 40]
  end

  test "canvas options reset at then" do
    origin = png_origin(solid_source(20, 10, [220, 30, 40]))
    output = image("w=20/h=15/enlarge/extend/then/w=10/h=10/enlarge", origin)

    assert dimensions(output) == {10, 8}
  end

  test "invalid offset and canvas combinations fail before source access" do
    config = api_config({CountingOriginImage, test_pid: self()})
    huge = "1" <> String.duplicate("0", 200)

    for options <- [
          "crop=10,10/anchor-offset=1,2",
          "crop=10,10/anchor=smart/anchor-offset=1,2",
          "w=20/extend",
          "w=20/h=auto/extend",
          "w=20/extend-ratio",
          "w=20/h=20/extend/extend-ratio",
          "w=20/h=20/extend-at=top",
          "w=20/h=20/extend-offset=1,2",
          "w=20/h=20/extend=false/extend-at=top",
          "w=20/h=20/extend-ratio=false/extend-offset=1,2",
          "crop=10,10/anchor=top-left/anchor-offset=#{huge},0/dpr=#{huge}",
          "w=20/h=20/extend/extend-offset=0,#{huge}/dpr=#{huge}"
        ] do
      response =
        conn(:get, "/#{options}/format=png/src/images/x.png")
        |> ImagePipe.Plug.call(config)

      assert response.status == 400
      refute_received :origin_fetch
    end
  end

  test "equivalent offset numbers share ETags and response bytes" do
    origin = png_origin(marked_source())

    for {first, second} <- [
          {"crop=20,20/anchor=top-left/anchor-offset=10,5",
           "crop=20,20/anchor=top-left/anchor-offset=10.0,5.0"},
          {"crop=20,20/anchor=top-left/anchor-offset=10pct,5pct",
           "crop=20,20/anchor=top-left/anchor-offset=10.0pct,5.0pct"},
          {"w=60/h=60/extend/extend-offset=1,0", "w=60/h=60/extend/extend-offset=1.0,0.0"},
          {"w=60/h=60/extend/extend-offset=5pct,0", "w=60/h=60/extend/extend-offset=5.0pct,0pct"}
        ] do
      first_response = response(first, origin)
      second_response = response(second, origin)
      assert first_response.status == 200
      assert second_response.status == 200
      assert [_etag] = get_resp_header(first_response, "etag")
      assert get_resp_header(first_response, "etag") == get_resp_header(second_response, "etag")
      assert first_response.resp_body == second_response.resp_body
    end
  end

  defp image(options, origin) do
    response = response(options, origin)
    assert response.status == 200
    Image.from_binary!(response.resp_body)
  end

  defp response(options, origin) do
    conn(:get, "/#{options}/format=png/src/image.png")
    |> ImagePipe.Plug.call(api_config(origin))
  end

  defp api_config(origin) do
    ImagePipe.Plug.init(
      sources: [
        path:
          {RootHTTPAdapter,
           root_url: "http://origin.test", byte_identity: :strong, req_options: [plug: origin]}
      ],
      http_cache: [mode: :enabled],
      max_body_bytes: 10_000_000,
      max_input_pixels: 40_000_000
    )
  end

  defp png_origin(body) do
    fn conn -> conn |> put_resp_content_type("image/png") |> send_resp(200, body) end
  end

  defp solid_source(width, height, color) do
    width
    |> Image.new!(height, color: color)
    |> Image.write!(:memory, suffix: ".png")
  end

  defp marked_source(width \\ 40, height \\ 80) do
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

  defp assert_same_pixels(actual, expected) do
    assert dimensions(actual) == dimensions(expected)
    assert VipsImage.write_to_binary(actual) == VipsImage.write_to_binary(expected)
  end

  defp dimensions(image), do: {Image.width(image), Image.height(image)}
  defp transparent?(pixel), do: List.last(pixel) == 0
  defp rgb(pixel), do: Enum.take(pixel, 3)
end
