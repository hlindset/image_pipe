defmodule ImagePipe.Native.TerminalShrinkWireTest do
  use ExUnit.Case, async: false

  import Plug.Conn
  import Plug.Test

  alias ImagePipe.SourceTest.RootHTTPAdapter

  test "BlurHash terminal reduction does not change a later group's trim input" do
    jpeg =
      800
      |> Image.new!(600, color: :white)
      |> Image.Draw.rect!(11, 17, 515, 369, color: :blue)
      |> Image.Draw.rect!(220, 170, 120, 80, color: :red)
      |> Image.write!(:memory, suffix: ".jpg")

    full_pixels = jpeg |> Image.from_binary!() |> Image.write!(:memory, suffix: ".png")
    path = "/blur=1/then/trim=auto/output=blurhash/src/image"

    actual = request(path, jpeg, "image/jpeg")
    expected = request(path, full_pixels, "image/png")

    assert actual.status == 200
    assert expected.status == 200
    assert actual.resp_body == expected.resp_body
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
