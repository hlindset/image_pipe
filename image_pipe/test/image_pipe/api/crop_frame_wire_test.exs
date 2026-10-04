defmodule ImagePipe.API.CropFrameWireTest do
  use ExUnit.Case, async: true

  import Plug.Conn
  import Plug.Test

  alias ImagePipe.SourceTest.RootHTTPAdapter
  alias Vix.Vips.Image, as: Vimage

  test "out-of-range focus is rejected before fetching a source" do
    config =
      ImagePipe.Plug.init(
        sources: [
          path: [
            adapter: RootHTTPAdapter,
            match: :path,
            options: [
              root_url: "http://origin.test",
              req_options: [plug: fn _conn -> flunk("invalid focus fetched a source") end]
            ]
          ]
        ]
      )

    for {x, y} <- [{-0.1, 0.5}, {1.1, 0.5}, {0.5, -0.1}, {0.5, 1.1}] do
      response =
        conn(:get, "/crop=20,20/focus=#{x},#{y}/src/image.png")
        |> ImagePipe.Plug.call(config)

      assert response.status == 400

      assert_raise ArgumentError, fn ->
        ImagePipe.URL.new() |> ImagePipe.URL.group(crop: {20, 20}, focus: {x, y})
      end
    end
  end

  test "a negative region origin is rejected before fetching a source" do
    config =
      ImagePipe.Plug.init(
        sources: [
          path: [
            adapter: RootHTTPAdapter,
            match: :path,
            options: [
              root_url: "http://origin.test",
              req_options: [plug: fn _conn -> flunk("negative region fetched a source") end]
            ]
          ]
        ]
      )

    for region <- ["-500,-500,10,10", "0,-1,10,10", "-5pct,0,10,10"] do
      response =
        conn(:get, "/region=#{region}/src/image.png")
        |> ImagePipe.Plug.call(config)

      assert response.status == 400, region
    end
  end

  test "an odd-sized region keeps its exact origin" do
    body =
      Image.new!(10, 10, color: :white)
      |> Image.compose!(Image.new!(1, 1, color: :black), x: 0, y: 0)
      |> Image.write!(:memory, suffix: ".png")

    origin = fn conn -> conn |> put_resp_content_type("image/png") |> send_resp(200, body) end

    config =
      ImagePipe.Plug.init(
        sources: [
          path: [
            adapter: RootHTTPAdapter,
            match: :path,
            options: [root_url: "http://origin.test", req_options: [plug: origin]]
          ]
        ]
      )

    conn =
      conn(:get, "/region=0,0,3,3/format=png/src/image.png")
      |> ImagePipe.Plug.call(config)

    assert conn.status == 200
    actual = Image.from_binary!(conn.resp_body)
    assert {Image.width(actual), Image.height(actual)} == {3, 3}
    assert Image.get_pixel!(actual, 0, 0) == [0, 0, 0, 255]
  end

  test "percentage crops use the trimmed input and preserve its pixel coordinates" do
    content =
      Image.new!(80, 40, color: [220, 20, 60])
      |> Image.compose!(Image.new!(40, 40, color: [20, 80, 220]), x: 40, y: 0)

    body =
      Image.new!(120, 80, color: :white)
      |> Image.compose!(content, x: 20, y: 20)
      |> Image.write!(:memory, suffix: ".png")

    origin = fn conn -> conn |> put_resp_content_type("image/png") |> send_resp(200, body) end

    config =
      ImagePipe.Plug.init(
        sources: [
          path: [
            adapter: RootHTTPAdapter,
            match: :path,
            options: [root_url: "http://origin.test", req_options: [plug: origin]]
          ]
        ]
      )

    for {crop, expected} <- [
          {"crop=50pct,100pct/anchor=right", Image.crop!(content, 40, 0, 40, 40)},
          {"region=50pct,0,50pct,100pct", Image.crop!(content, 40, 0, 40, 40)}
        ] do
      conn =
        conn(:get, "/#{crop}/trim=fff,0/format=png/src/image.png")
        |> ImagePipe.Plug.call(config)

      assert conn.status == 200
      actual = Image.from_binary!(conn.resp_body)
      assert {Image.width(actual), Image.height(actual)} == {40, 40}
      assert Vimage.write_to_binary(actual) == Vimage.write_to_binary(expected)
    end
  end
end
