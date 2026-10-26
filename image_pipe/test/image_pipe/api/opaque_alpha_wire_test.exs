defmodule ImagePipe.API.OpaqueAlphaWireTest do
  use ExUnit.Case, async: true

  import Plug.Conn
  import Plug.Test

  alias ImagePipe.SourceTest.RootHTTPAdapter
  alias Vix.Vips.Image, as: VipsImage
  alias Vix.Vips.Operation

  setup_all do
    {:ok, photo} = Image.thumbnail("priv/static/images/dog.jpg", 96)
    {:ok, photo} = VipsImage.copy_memory(photo)
    {:ok, opaque} = Operation.bandjoin_const(photo, [255.0])
    {:ok, gray} = Operation.colourspace(photo, :VIPS_INTERPRETATION_B_W)
    {:ok, opaque_gray} = Operation.bandjoin_const(gray, [255.0])

    %{
      rgb: png(photo),
      opaque_rgba: png(opaque),
      gray: png(gray),
      opaque_gray: png(opaque_gray)
    }
  end

  for format <- ~w(png avif webp) do
    test "an opaque alpha band encodes like no alpha as #{format}", sources do
      plain = response("format=#{unquote(format)}", sources.rgb)
      with_alpha = response("format=#{unquote(format)}", sources.opaque_rgba)

      assert plain.status == 200
      assert with_alpha.status == 200
      assert with_alpha.resp_body == plain.resp_body
      refute Image.has_alpha?(decode(with_alpha))
    end
  end

  test "an opaque gray alpha band encodes like gray", sources do
    plain = response("format=png", sources.gray)
    with_alpha = response("format=png", sources.opaque_gray)

    assert with_alpha.resp_body == plain.resp_body
    assert Image.bands(decode(with_alpha)) == 1
  end

  test "an alpha band with one transparent pixel is kept", sources do
    {:ok, image} = Image.open(sources.opaque_rgba)
    {:ok, image} = Image.Draw.point(image, 5, 5, color: [10, 20, 30, 0])
    response = response("format=png", png(image))

    output = decode(response)
    assert Image.has_alpha?(output)
    assert Image.get_pixel!(output, 5, 5) == [10, 20, 30, 0]
  end

  defp png(image), do: Image.write!(image, :memory, suffix: ".png")

  defp decode(response) do
    {:ok, image} = Image.open(response.resp_body)
    image
  end

  defp response(options, body) do
    origin = fn conn -> conn |> put_resp_content_type("image/png") |> send_resp(200, body) end

    config =
      ImagePipe.Plug.init(
        allow_unsigned: true,
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
