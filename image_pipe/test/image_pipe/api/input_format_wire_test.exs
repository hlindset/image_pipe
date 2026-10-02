defmodule ImagePipe.API.InputFormatWireTest do
  @moduledoc """
  The same request on the same image in every input container gives the same
  pixels, within each container's loss, and EXIF orientation applies in every
  container that carries it.
  """
  use ExUnit.Case, async: true

  import Plug.Conn
  import Plug.Test

  alias ImagePipe.SourceTest.RootHTTPAdapter
  alias Vix.Vips.Image, as: VipsImage
  alias Vix.Vips.Operation

  # {file, libvips save suffix, largest mean absolute difference from PNG}
  @containers [
    {"image.jpg", ".jpg[Q=95]", 3.0},
    {"lossless.webp", ".webp[lossless=true]", 0.5},
    {"lossy.webp", ".webp[Q=95]", 3.0},
    {"image.tif", ".tif", 0.5},
    {"image16.tif", :tiff16, 0.5},
    {"image.gif", ".gif", 0.5},
    {"image.avif", ".avif[Q=90,compression=av1]", 4.0},
    {"lossless.jxl", ".jxl[lossless=true]", 0.5}
  ]

  @requests [
    "w=32",
    "crop=40,30/anchor=bottom-right",
    "rotate=90",
    "w=48/h=48/fit=cover/anchor=left",
    "pad=4/bg=ff0000",
    "blur=1"
  ]

  # Downscales may decode at a reduced size (JPEG shrink-on-load, WebP scale),
  # which resamples differently from a full decode.
  @downscales ~w(w=32 w=48/h=48/fit=cover/anchor=left)
  @downscale_tolerance 3.0

  # Containers whose EXIF orientation libvips writes and reads. JPEG XL keeps
  # orientation in its codestream, which libjxl applies on decode; libvips'
  # writer leaves that field at 1, so it can't produce an oriented test file.
  @oriented ~w(png webp tif avif)

  setup_all do
    files =
      Map.new(@containers, fn {file, saver, _tolerance} -> {file, encode(base(), saver)} end)
      |> Map.put("image.png", encode(base(), ".png"))

    oriented =
      Map.new(@oriented, fn ext ->
        {"oriented.#{ext}", base() |> Image.set_orientation!(6) |> encode(oriented_saver(ext))}
      end)

    {:ok, config: config(Map.merge(files, oriented))}
  end

  for {file, _saver, tolerance} <- @containers, request <- @requests do
    @container file
    @tolerance if(request in @downscales,
                 do: max(tolerance, @downscale_tolerance),
                 else: tolerance
               )
    @request request

    test "#{file}: #{request} matches PNG", %{config: config} do
      expected = image("/#{@request}/format=png/src/image.png", config)
      actual = image("/#{@request}/format=png/src/#{@container}", config)

      assert dims(actual) == dims(expected)
      assert mean_difference(actual, expected) <= @tolerance
    end
  end

  for ext <- @oriented, request <- ["", "crop=40,30/anchor=top-left/"] do
    @ext ext
    @request request

    test "oriented.#{ext}: #{request}EXIF orientation 6 applies", %{config: config} do
      {:ok, rotated} = Operation.rot(base(), :VIPS_ANGLE_D90)
      rotated_config = config(%{"rotated.png" => encode(rotated, ".png")})

      expected = image("/#{@request}format=png/src/rotated.png", rotated_config)
      actual = image("/#{@request}format=png/src/oriented.#{@ext}", config)

      assert dims(actual) == dims(expected)
      assert mean_difference(actual, expected) <= 4.0
    end
  end

  # A 128×96 base with distinct regions, large enough that a 4× downscale
  # shrinks on load in the containers that support it.
  defp base do
    128
    |> Image.new!(96, color: [40, 120, 200])
    |> Image.Draw.rect!(0, 0, 128, 12, color: [250, 250, 250])
    |> Image.Draw.rect!(20, 24, 40, 40, color: [220, 40, 40])
    |> Image.Draw.rect!(72, 40, 40, 40, color: [40, 200, 80])
  end

  defp encode(image, :tiff16) do
    {:ok, scaled} = Operation.linear(image, [257.0], [0.0])
    {:ok, cast} = Operation.cast(scaled, :VIPS_FORMAT_USHORT)
    {:ok, rgb16} = Operation.copy(cast, interpretation: :VIPS_INTERPRETATION_RGB16)
    encode(rgb16, ".tif")
  end

  defp encode(image, suffix) do
    {:ok, body} = VipsImage.write_to_buffer(image, suffix)
    body
  end

  defp oriented_saver("png"), do: ".png"
  defp oriented_saver("webp"), do: ".webp[lossless=true]"
  defp oriented_saver("tif"), do: ".tif"
  defp oriented_saver("avif"), do: ".avif[Q=90,compression=av1]"

  defp mean_difference(actual, expected) do
    {:ok, actual} = Operation.cast(flatten(actual), :VIPS_FORMAT_FLOAT)
    {:ok, expected} = Operation.cast(flatten(expected), :VIPS_FORMAT_FLOAT)
    {:ok, delta} = Operation.subtract(actual, expected)
    {:ok, delta} = Operation.abs(delta)
    {:ok, mean} = Operation.avg(delta)
    mean
  end

  defp flatten(image) do
    image = if Image.has_alpha?(image), do: Image.flatten!(image), else: image
    {:ok, srgb} = Operation.colourspace(image, :VIPS_INTERPRETATION_sRGB)
    srgb
  end

  defp dims(image), do: {Image.width(image), Image.height(image)}

  defp image(path, config) do
    response = conn(:get, path) |> ImagePipe.Plug.call(config)
    assert response.status == 200, "#{path}: #{response.status} #{response.resp_body}"
    Image.from_binary!(response.resp_body)
  end

  defp config(files) do
    origin = fn conn ->
      body = Map.fetch!(files, Path.basename(conn.request_path))
      conn |> put_resp_content_type("application/octet-stream") |> send_resp(200, body)
    end

    ImagePipe.Plug.init(
      sources: [
        path: [
          adapter: RootHTTPAdapter,
          match: :path,
          options: [root_url: "http://origin.test", req_options: [plug: origin]]
        ]
      ]
    )
  end
end
