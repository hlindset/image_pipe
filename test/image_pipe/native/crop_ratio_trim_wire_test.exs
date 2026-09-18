defmodule ImagePipe.Native.CropRatioTrimWireTest do
  use ExUnit.Case, async: false

  import Plug.Conn
  import Plug.Test

  alias ImagePipe.Native.Parser
  alias ImagePipe.Native.Path
  alias ImagePipe.SourceTest.RootHTTPAdapter
  alias ImagePipe.Transform.DecodePlanner
  alias ImagePipe.Transform.Executor
  alias ImagePipe.Transform.PendingOrientation
  alias ImagePipe.Transform.SourceGeometry
  alias Vix.Vips.Image, as: VipsImage

  test "trim symmetry keeps equal opposing margins in the display frame" do
    source =
      Image.new!(100, 80, color: :white)
      |> Image.Draw.rect!(10, 20, 60, 30, color: :red)
      |> Image.write!(:memory, suffix: ".png")

    for {symmetry, region} <- [
          {"h", "10,20,80,30"},
          {"v", "10,20,60,40"},
          {"hv", "10,20,80,40"}
        ] do
      actual = image("trim=fff/trim-symmetry=#{symmetry}", source)
      expected = image("region=#{region}", source)
      assert_same_pixels(actual, expected)
    end

    rotated = image("rotate=90/trim=fff/trim-symmetry=h", source)
    assert {Image.width(rotated), Image.height(rotated)} == {40, 60}

    assert_same_pixels(
      image("trim=fff/trim-symmetry=hv/then/trim=fff", source),
      image("trim=fff", source)
    )
  end

  test "crop ratio correction shrinks or grows the selected box before placement" do
    source = source()

    for {options, region} <- [
          {"crop=60,60/crop-ratio=2", "30,36,60,30"},
          {"crop=60,60/crop-ratio=2/crop-ratio-enlarge", "0,20,120,60"},
          {"crop=100,100/crop-ratio=2/crop-ratio-enlarge", "0,20,120,60"},
          {"crop=60,60/crop-ratio=2/anchor=top-left", "0,0,60,30"}
        ] do
      assert_same_pixels(image(options, source), image("region=#{region}", source))
    end
  end

  test "crop ratios use displayed axes after rotation" do
    source = source()
    rotated = image("rotate=90", source) |> Image.write!(:memory, suffix: ".png")
    actual = image("rotate=90/crop=60,60/crop-ratio=2", source)
    expected = image("crop=60,60/crop-ratio=2", rotated)
    assert_same_pixels(actual, expected)
    assert {Image.width(actual), Image.height(actual)} == {60, 30}
  end

  test "DPR does not rescale source crop ratio dimensions" do
    output = image("crop=60,60/crop-ratio=2/dpr=2/pad=5", source())
    assert {Image.width(output), Image.height(output)} == {80, 50}
  end

  test "a later group starts with a fresh crop ratio" do
    output = image("crop=60,60/crop-ratio=2/then/crop=20,20", source())
    assert {Image.width(output), Image.height(output)} == {20, 20}
  end

  test "decode shrink accounts for the ratio-corrected crop extent" do
    geometry = %SourceGeometry{
      storage_dimensions: {800, 600},
      display_dimensions: {800, 600},
      pending_orientation: %PendingOrientation{},
      source_format: :jpeg
    }

    {:ok, lexed} = conn(:get, "/crop=200,200/crop-ratio=2/h=25/src/image.jpg") |> Path.extract()
    {:ok, request} = Parser.parse(lexed, [])
    decode_request = Executor.decode_request(request, geometry)

    assert DecodePlanner.open_options_for(decode_request, :jpeg, {800, 600})[:shrink] == 4
  end

  test "out-of-range crop ratios fail before source access" do
    origin = fn _conn -> flunk("invalid crop ratio fetched its source") end

    config =
      ImagePipe.Plug.init(
        sources: [
          path: {RootHTTPAdapter, root_url: "http://origin.test", req_options: [plug: origin]}
        ]
      )

    huge = String.duplicate("9", 400)

    for ratio <- [huge, "#{huge}:1", "1:#{huge}"] do
      response =
        conn(:get, "/crop=60,60/crop-ratio=#{ratio}/src/image.png") |> ImagePipe.Plug.call(config)

      assert response.status == 400
    end
  end

  defp source do
    Image.new!(120, 100, color: :blue)
    |> Image.Draw.rect!(12, 17, 61, 48, color: :red)
    |> Image.write!(:memory, suffix: ".png")
  end

  defp image(options, body) do
    origin = fn conn -> conn |> put_resp_content_type("image/png") |> send_resp(200, body) end

    config =
      ImagePipe.Plug.init(
        sources: [
          path: {RootHTTPAdapter, root_url: "http://origin.test", req_options: [plug: origin]}
        ]
      )

    response = conn(:get, "/#{options}/format=png/src/image.png") |> ImagePipe.Plug.call(config)
    assert response.status == 200
    Image.from_binary!(response.resp_body)
  end

  defp assert_same_pixels(actual, expected) do
    assert {Image.width(actual), Image.height(actual)} ==
             {Image.width(expected), Image.height(expected)}

    assert VipsImage.write_to_binary(actual) == VipsImage.write_to_binary(expected)
  end
end
