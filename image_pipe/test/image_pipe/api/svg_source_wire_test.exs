defmodule ImagePipe.API.SVGSourceWireTest do
  use ExUnit.Case, async: true

  import Plug.Conn
  import Plug.Test

  alias ImagePipe.SourceTest.RootHTTPAdapter

  # Red left half, blue right half, at an intrinsic 40×20.
  @svg ~s(<svg xmlns="http://www.w3.org/2000/svg" width="40" height="20" viewBox="0 0 40 20">) <>
         ~s(<rect width="20" height="20" fill="#ff0000"/>) <>
         ~s(<rect x="20" width="20" height="20" fill="#0000ff"/></svg>)

  @transparent ~s(<svg xmlns="http://www.w3.org/2000/svg" width="40" height="20">) <>
                 ~s(<rect width="20" height="20" fill="#ff0000"/></svg>)

  # The render always has an alpha band, so without a format or a negotiated
  # one every SVG falls back to PNG.
  test "renders to PNG, keeping transparency" do
    response = request("w=40", mount(@transparent))

    assert content_type(response) == "image/png"
    assert dimensions(response) == {40, 20}
    assert pixel(response, 10, 10) == [255, 0, 0, 255]
    assert pixel(response, 30, 10) == [0, 0, 0, 0]
  end

  test "negotiates a modern format from Accept" do
    response =
      conn(:get, "/w=40/src/source.svg")
      |> put_req_header("accept", "image/webp")
      |> ImagePipe.Plug.call(mount(@svg))

    assert content_type(response) == "image/webp"
    assert get_resp_header(response, "vary") == ["Accept"]
  end

  test "renders past its intrinsic size with sharp edges, without enlarge" do
    response = request("w=400/format=png", mount(@svg))

    assert dimensions(response) == {400, 200}
    # A raster upscale blends the colours across several pixels at the edge.
    assert pixel(response, 198, 100) == [255, 0, 0, 255]
    assert pixel(response, 201, 100) == [0, 0, 255, 255]
  end

  test "applies DPR past the intrinsic size" do
    assert dimensions(request("w=40/dpr=2/format=png", mount(@svg))) == {80, 40}
  end

  test "measures regions in intrinsic pixels whatever size it renders at" do
    response = request("region=20,0,20,20/w=100/format=png", mount(@svg))

    assert dimensions(response) == {100, 100}
    assert pixel(response, 2, 50) == [0, 0, 255, 255]
    assert pixel(response, 97, 50) == [0, 0, 255, 255]
  end

  test "rotates before resizing past the intrinsic size" do
    turned = request("rotate=90/w=40/format=png", mount(@svg))

    assert dimensions(turned) == {40, 80}
    assert pixel(turned, 20, 10) == [255, 0, 0, 255]
    assert pixel(turned, 20, 70) == [0, 0, 255, 255]

    assert {width, _height} = dimensions(request("rotate=30/w=200/format=png", mount(@svg)))
    assert width == 200
  end

  test "keeps the enlargement clamp in later groups, which resize the rendered raster" do
    assert dimensions(request("w=10/-/w=100/format=png", mount(@svg))) == {10, 5}
  end

  test "reports its intrinsic size and format in info" do
    response = request("w=400/output=info", mount(@svg))
    info = JSON.decode!(response.resp_body)

    assert %{"format" => "svg", "width" => 40, "height" => 20} = info["source"]
    assert %{"width" => 400, "height" => 200} = info["result"]
  end

  test "fails a render larger than max_input_pixels" do
    config = mount(@svg, max_input_pixels: 4_000)

    assert request("w=80/format=png", config).status == 200
    assert request("w=100/format=png", config).status == 413
  end

  test "fails a render over the render budget" do
    blurs =
      ~s(<svg xmlns="http://www.w3.org/2000/svg" width="100" height="100">) <>
        ~s[<filter id="f"><feGaussianBlur stdDeviation="5"/></filter>] <>
        String.duplicate(~s[<rect width="100" height="100" filter="url(#f)"/>], 200) <>
        "</svg>"

    assert request("w=1000/format=png", mount(blurs)).status == 413
  end

  test "rejects a malformed SVG as an unsupported source" do
    malformed = ~s(<svg xmlns="http://www.w3.org/2000/svg" width="8"><rect)
    assert request("w=8", mount(malformed)).status == 415
  end

  defp request(options, config),
    do: conn(:get, "/#{options}/src/source.svg") |> ImagePipe.Plug.call(config)

  defp mount(body, options \\ []) do
    origin = fn conn ->
      conn |> put_resp_content_type("image/svg+xml") |> send_resp(200, body)
    end

    ImagePipe.Plug.init(
      [
        sources: [
          path: [
            adapter: RootHTTPAdapter,
            match: :path,
            options: [root_url: "http://origin.test", req_options: [plug: origin]]
          ]
        ]
      ] ++ options
    )
  end

  defp content_type(response) do
    [value] = get_resp_header(response, "content-type")
    value |> String.split(";") |> hd()
  end

  defp dimensions(response) do
    assert response.status == 200
    image = Image.from_binary!(response.resp_body)
    {Image.width(image), Image.height(image)}
  end

  defp pixel(response, x, y) do
    response.resp_body |> Image.from_binary!() |> Image.get_pixel!(x, y)
  end
end
