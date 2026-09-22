defmodule ImagePipe.API.TerminalShrinkWireTest do
  use ExUnit.Case, async: false

  import Plug.Conn
  import Plug.Test

  alias ImagePipe.SourceTest.RootHTTPAdapter

  test "BlurHash decode shrink preserves a small source crop's detail" do
    patterned = Image.new!(3200, 2400, color: [5, 11, 17]) |> patterned(4, 4)

    jpeg = Image.write!(patterned, :memory, suffix: ".jpg", quality: 92)
    full_pixels = jpeg |> Image.from_binary!() |> Image.write!(:memory, suffix: ".png")

    for crop <- ["region=0,0,32,32", "crop=32,32/anchor=top-left"] do
      path = "/#{crop}/output=blurhash/src/image"
      actual = request(path, jpeg, "image/jpeg")
      expected = request(path, full_pixels, "image/png")

      assert actual.status == 200
      assert expected.status == 200
      assert actual.resp_body == expected.resp_body, crop
    end
  end

  test "oversized regions use the clamped source extent for terminal decode" do
    webp =
      Image.new!(800, 600)
      |> patterned(100, 75)
      |> Image.write!(:memory, suffix: ".webp")

    oversized = request("/region=0,0,1600,1200/output=blurhash/src/image", webp, "image/webp")
    clamped = request("/region=0,0,800,600/output=blurhash/src/image", webp, "image/webp")

    assert oversized.status == 200
    assert clamped.status == 200
    assert oversized.resp_body == clamped.resp_body
  end

  test "BlurHash terminal reduction does not change a later group's trim input" do
    jpeg =
      800
      |> Image.new!(600, color: :white)
      |> Image.Draw.rect!(11, 17, 515, 369, color: :blue)
      |> Image.Draw.rect!(220, 170, 120, 80, color: :red)
      |> Image.write!(:memory, suffix: ".jpg")

    full_pixels = jpeg |> Image.from_binary!() |> Image.write!(:memory, suffix: ".png")
    path = "/blur=1/-/trim=auto/output=blurhash/src/image"

    actual = request(path, jpeg, "image/jpeg")
    expected = request(path, full_pixels, "image/png")

    assert actual.status == 200
    assert expected.status == 200
    assert actual.resp_body == expected.resp_body
  end

  defp patterned(image, block_width, block_height) do
    Enum.reduce(0..7, image, fn y, image ->
      Enum.reduce(0..7, image, fn x, image ->
        color = [rem(x * 73 + y * 31, 256), rem(x * 19 + y * 97, 256), rem(x * 151 + y * 43, 256)]

        Image.Draw.rect!(image, x * block_width, y * block_height, block_width, block_height,
          color: color
        )
      end)
    end)
  end

  defp request(path, body, content_type) do
    origin = fn conn -> conn |> put_resp_content_type(content_type) |> send_resp(200, body) end

    config =
      ImagePipe.Plug.init(
        sources: [
          path: {RootHTTPAdapter, root_url: "http://origin.test", req_options: [plug: origin]}
        ]
      )

    conn(:get, path) |> ImagePipe.Plug.call(config)
  end
end
