defmodule ImagePipe.API.PngBitdepthWireTest do
  use ExUnit.Case, async: true

  import Plug.Conn
  import Plug.Test

  alias ImagePipe.SourceTest.RootHTTPAdapter
  alias Vix.Vips.Image, as: VipsImage
  alias Vix.Vips.Operation

  test "a gray result at 2 or 4 bits keeps its gray levels" do
    body = 16 |> Image.new!(16, color: [150]) |> Image.write!(:memory, suffix: ".png")

    for {bitdepth, expected} <- [{4, 153}, {2, 170}] do
      response = response("format=png/png-options=bitdepth:#{bitdepth}", body)
      assert response.status == 200, "bitdepth #{bitdepth}"

      image = Image.from_binary!(response.resp_body)
      assert [^expected] = Image.get_pixel!(image, 8, 8), "bitdepth #{bitdepth}"
    end
  end

  test "a gray result at 1 bit splits at mid-gray" do
    for {gray, expected} <- [{100, 0}, {127, 0}, {128, 255}, {150, 255}] do
      body = 16 |> Image.new!(16, color: [gray]) |> Image.write!(:memory, suffix: ".png")
      response = response("format=png/png-options=bitdepth:1", body)
      assert response.status == 200, "gray #{gray}"

      image = Image.from_binary!(response.resp_body)
      assert [^expected] = Image.get_pixel!(image, 8, 8), "gray #{gray}"
    end
  end

  test "an 8-bit result at 16 bits scales each value by 257" do
    for color <- [[128], [128, 100], [128, 64, 200], [128, 64, 200, 100]] do
      body = 16 |> Image.new!(16, color: color) |> Image.write!(:memory, suffix: ".png")

      for options <- ["bitdepth:16", "palette,bitdepth:16"] do
        response = response("format=png/png-options=#{options}", body)
        assert response.status == 200, "#{options} #{inspect(color)}"

        image = Image.from_binary!(response.resp_body)
        assert Image.bands(image) == length(color)

        assert Image.get_pixel!(image, 8, 8) == Enum.map(color, &(&1 * 257)),
               "#{options} #{inspect(color)}"
      end
    end
  end

  test "a 16-bit color or gray-and-alpha result below 8 bits encodes at 8 bits" do
    for {color, interpretation} <- [
          {[128, 64, 200], :VIPS_INTERPRETATION_RGB16},
          {[128, 64], :VIPS_INTERPRETATION_GREY16}
        ] do
      {:ok, source} = Image.new(16, 16, color: Enum.map(color, &(&1 * 257)), format: {:u, 16})
      {:ok, source} = Operation.copy(source, interpretation: interpretation)
      body = Image.write!(source, :memory, suffix: ".png")

      response = response("hdr=preserve/format=png/png-options=bitdepth:2", body)
      assert response.status == 200, inspect(color)

      image = Image.from_binary!(response.resp_body)
      assert VipsImage.format(image) == :VIPS_FORMAT_UCHAR, inspect(color)
      assert Image.get_pixel!(image, 8, 8) == color
    end
  end

  test "a 16-bit source narrows to 8 bits by rounding" do
    for {color, interpretation} <- [
          {[65_400, 129, 65_400], :VIPS_INTERPRETATION_RGB16},
          {[65_400], :VIPS_INTERPRETATION_GREY16},
          {[129], :VIPS_INTERPRETATION_GREY16},
          {[65_400, 129], :VIPS_INTERPRETATION_GREY16}
        ],
        options <- [
          "format=png",
          "format=webp/webp-options=lossless",
          "format=png/hdr=preserve/png-options=bitdepth:8"
        ] do
      {:ok, source} = Image.new(16, 16, color: color, format: {:u, 16})
      {:ok, source} = Operation.copy(source, interpretation: interpretation)
      body = Image.write!(source, :memory, suffix: ".png")

      response = response(options, body)
      assert response.status == 200, "#{options} #{inspect(color)}"

      image = Image.from_binary!(response.resp_body)
      expected = color |> Enum.map(&round(&1 / 257)) |> as_bands(Image.bands(image))

      assert Image.get_pixel!(image, 8, 8) == expected, "#{options} #{inspect(color)}"
    end
  end

  test "q doesn't change a palette PNG at 16 bits" do
    body = 16 |> Image.new!(16, color: [128, 64, 200]) |> Image.write!(:memory, suffix: ".png")

    etags =
      for q <- [50, 60] do
        response = response("format=png/png-options=palette,bitdepth:16/q=#{q}", body)
        assert response.status == 200
        get_resp_header(response, "etag")
      end

    assert [same, same] = etags
  end

  test "a result with more than one band encodes at 8 bits instead of failing" do
    for {source, options} <- [
          {"alpha.png", "bitonal/format=png/png-options=bitdepth:1"},
          {"gray_alpha.png", "format=png/png-options=bitdepth:2"},
          {"high_freq.jpg", "rotate=30/bitonal/format=png/png-options=bitdepth:1"}
        ] do
      body = File.read!("test/support/image_pipe/test/sources/#{source}")
      response = response(options, body)
      assert response.status == 200, "#{options} on #{source}"
      assert {:ok, _image} = Image.from_binary(response.resp_body)
    end
  end

  # WebP stores gray as color.
  defp as_bands([gray], 3), do: [gray, gray, gray]
  defp as_bands([gray, alpha], 4), do: [gray, gray, gray, alpha]
  defp as_bands(pixel, _bands), do: pixel

  defp response(options, body) do
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

    conn(:get, "/#{options}/src/image") |> ImagePipe.Plug.call(config)
  end
end
