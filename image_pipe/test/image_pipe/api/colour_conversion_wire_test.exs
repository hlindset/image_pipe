defmodule ImagePipe.API.ColourConversionWireTest do
  use ExUnit.Case, async: true

  import Plug.Conn
  import Plug.Test

  alias ImagePipe.Output.ColorProfile
  alias ImagePipe.SourceTest.RootHTTPAdapter
  alias Vix.Vips.Image, as: VipsImage
  alias Vix.Vips.Operation

  @sources "test/support/image_pipe/test/sources"

  describe "request colours are sRGB on a tagged source" do
    test "a background keeps its sRGB colour under strip" do
      output = file_image("w=300/h=200/fit=contain/extend/bg=4080c0/format=png", "icc_p3.png")
      assert close?(Image.get_pixel!(output, 0, 100), [64, 128, 192])
    end

    test "under preserve, a background is the sRGB colour expressed in the source profile" do
      output =
        file_image(
          "w=300/h=200/fit=contain/extend/bg=4080c0/profile=preserve/format=png",
          "icc_p3.png"
        )

      {:ok, srgb} = Operation.icc_transform(output, "sRGB", embedded: true)
      assert close?(Image.get_pixel!(srgb, 0, 100), [64, 128, 192])
    end

    test "an explicit trim colour matches in sRGB" do
      field =
        Image.new!(40, 30, color: [200, 50, 50])
        |> Image.Draw.rect!(5, 5, 30, 20, color: [70, 130, 180])

      {:ok, p3} =
        Operation.icc_transform(field, ColorProfile.path!(:display_p3), input_profile: "sRGB")

      body = Image.write!(p3, :memory, suffix: ".png")

      output = body_image("trim=c83232,2/format=png", body)
      assert {Image.width(output), Image.height(output)} == {30, 20}
    end
  end

  describe "CMYK sources" do
    test "a background is the sRGB colour" do
      output = file_image("pad=6/bg=4080c0/format=png", "cmyk.jpg")
      assert close?(Image.get_pixel!(srgb(output), 0, 0), [64, 128, 192])
    end

    # Only JPEG can hold CMYK; other formats fall back to sRGB without the profile.
    for format <- ~w(png webp avif) do
      @format format

      test "under preserve, #{format} output is sRGB" do
        output = file_image("pad=6/bg=4080c0/profile=preserve/format=#{@format}", "cmyk.jpg")
        assert VipsImage.interpretation(output) == :VIPS_INTERPRETATION_sRGB
        assert {:error, _} = VipsImage.header_value(output, "icc-profile-data")
        # Inside the padding, clear of lossy edge artefacts.
        assert close?(Image.get_pixel!(output, 3, 3), [64, 128, 192], 3)
      end
    end

    test "under preserve, JPEG output keeps CMYK and its profile" do
      # 4080c0 is outside the source's CMYK gamut; 806040 is inside it.
      output = file_image("pad=6/bg=806040/profile=preserve/format=jpeg", "cmyk.jpg")
      assert VipsImage.interpretation(output) == :VIPS_INTERPRETATION_CMYK
      assert close?(Image.get_pixel!(srgb(output), 0, 0), [128, 96, 64], 4)
    end

    test "trim finds a border by its sRGB colour" do
      {:ok, cmyk} =
        Operation.icc_transform(bordered([200, 50, 50]), "cmyk", input_profile: "sRGB")

      body = Image.write!(cmyk, :memory, suffix: ".jpg", quality: 95)

      for request <- ["trim=auto", "trim=c83232,20"] do
        output = body_image("#{request}/format=png", body)
        assert {Image.width(output), Image.height(output)} == {30, 20}, request
      end
    end
  end

  describe "16-bit images" do
    test "colorize and gradient apply colours at 16-bit scale" do
      colorized = file_image("hdr=preserve/colorize=1,ff0000/format=png", "rgb16.png")
      assert VipsImage.format(colorized) == :VIPS_FORMAT_USHORT
      assert Image.get_pixel!(colorized, 10, 10) == [65_535, 0, 0]

      gradient = file_image("hdr=preserve/gradient=1,ff0000,down/format=png", "rgb16.png")
      assert VipsImage.format(gradient) == :VIPS_FORMAT_USHORT
      assert Image.get_pixel!(gradient, 10, Image.height(gradient) - 1) == [65_535, 0, 0]
    end

    test "trim finds a border by its sRGB colour and keeps 16-bit depth" do
      {:ok, scaled} = Operation.linear(bordered([200, 50, 50]), [257.0], [0.0])
      {:ok, cast} = Operation.cast(scaled, :VIPS_FORMAT_USHORT)
      {:ok, rgb16} = Operation.copy(cast, interpretation: :VIPS_INTERPRETATION_RGB16)
      body = png(rgb16)

      for request <- ["trim=auto", "trim=c83232,2"] do
        output = body_image("hdr=preserve/#{request}/format=png", body)
        assert {Image.width(output), Image.height(output)} == {30, 20}, request
        assert VipsImage.format(output) == :VIPS_FORMAT_USHORT, request
      end
    end

    test "duotone and gray keep 16-bit depth" do
      duotone = file_image("hdr=preserve/duotone=1,123456,efab89/format=png", "rgb16.png")
      assert VipsImage.format(duotone) == :VIPS_FORMAT_USHORT
      assert VipsImage.interpretation(duotone) == :VIPS_INTERPRETATION_RGB16

      gray = file_image("hdr=preserve/gray/format=png", "rgb16.png")
      assert VipsImage.interpretation(gray) == :VIPS_INTERPRETATION_GREY16
    end
  end

  test "a colour applied to a gray image promotes it to RGB" do
    output = file_image("colorize=1,ff0000/format=png", "gray.png")
    assert VipsImage.interpretation(output) == :VIPS_INTERPRETATION_sRGB
    assert Image.get_pixel!(output, 10, 10) == [255, 0, 0]
  end

  describe "watermarks convert into the frame's space" do
    setup do
      p3 = ColorProfile.path!(:display_p3)

      {:ok, red_p3} =
        Operation.icc_transform(Image.new!(10, 10, color: [255, 0, 0]), p3, input_profile: "sRGB")

      {:ok, blue_p3} =
        Operation.icc_transform(Image.new!(40, 40, color: [0, 0, 255]), p3, input_profile: "sRGB")

      files = %{
        "frame.png" => png(Image.new!(40, 40, color: [0, 0, 255])),
        "frame_p3.png" => png(blue_p3),
        "red.png" => png(Image.new!(10, 10, color: [255, 0, 0])),
        "red_p3.png" => png(red_p3)
      }

      origin = fn conn ->
        body = Map.fetch!(files, Path.basename(conn.request_path))
        conn |> put_resp_content_type("image/png") |> send_resp(200, body)
      end

      %{origin: origin, blue_p3: Image.get_pixel!(blue_p3, 0, 0)}
    end

    test "a tagged watermark on an sRGB frame keeps both colours", %{origin: origin} do
      output = watermarked(origin, "red_p3.png", "frame.png", "preserve")
      assert close?(Image.get_pixel!(output, 20, 20), [255, 0, 0])
      assert Image.get_pixel!(output, 2, 2) == [0, 0, 255]
      assert {:error, _} = VipsImage.header_value(output, "icc-profile-data")
    end

    test "an sRGB watermark on a preserved P3 frame lands in P3 values", %{
      origin: origin,
      blue_p3: blue_p3
    } do
      output = watermarked(origin, "red.png", "frame_p3.png", "preserve")
      assert close?(Image.get_pixel!(output, 20, 20), [234, 51, 35])
      assert Image.get_pixel!(output, 2, 2) == blue_p3
    end
  end

  defp watermarked(origin, mark, frame, profile) do
    config =
      ImagePipe.Plug.init(
        sources: [
          path: [
            adapter: RootHTTPAdapter,
            match: :path,
            options: [root_url: "http://origin.test", req_options: [plug: origin]]
          ]
        ],
        watermarks: %{mark: [source: mark]}
      )

    request_image("/wm=mark/profile=#{profile}/format=png/src/#{frame}", config)
  end

  # A 30×20 field inside a 5px border of `border`.
  defp bordered(border) do
    Image.new!(40, 30, color: border)
    |> Image.Draw.rect!(5, 5, 30, 20, color: [70, 130, 180])
  end

  defp srgb(image) do
    case VipsImage.header_value(image, "icc-profile-data") do
      {:ok, _profile} ->
        {:ok, srgb} = Operation.icc_transform(image, "sRGB", embedded: true)
        srgb

      {:error, _absent} ->
        image
    end
  end

  defp close?(actual, expected, tolerance \\ 1),
    do: Enum.zip(actual, expected) |> Enum.all?(fn {a, e} -> abs(a - e) <= tolerance end)

  defp file_image(options, file) do
    config =
      ImagePipe.Plug.init(
        sources: [
          path: [
            adapter: ImagePipe.Source.File,
            match: :path,
            options: [root: @sources, root_id: "colour-conversion"]
          ]
        ]
      )

    request_image("/#{options}/src/#{file}", config)
  end

  defp body_image(options, body) do
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

    request_image("/#{options}/src/image.png", config)
  end

  defp request_image(path, config) do
    response = conn(:get, path) |> ImagePipe.Plug.call(config)
    assert response.status == 200, "#{path}: #{response.status} #{response.resp_body}"
    Image.from_binary!(response.resp_body)
  end

  defp png(image), do: Image.write!(image, :memory, suffix: ".png")
end
