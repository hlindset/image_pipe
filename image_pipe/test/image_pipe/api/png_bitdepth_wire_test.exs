defmodule ImagePipe.API.PngBitdepthWireTest do
  use ExUnit.Case, async: true

  import Plug.Conn
  import Plug.Test

  alias ImagePipe.SourceTest.RootHTTPAdapter

  test "a gray result at 2 or 4 bits keeps its gray levels" do
    body = 16 |> Image.new!(16, color: [150]) |> Image.write!(:memory, suffix: ".png")

    for {bitdepth, expected} <- [{4, 153}, {2, 170}] do
      response = response("format=png/png-options=bitdepth:#{bitdepth}", body)
      assert response.status == 200, "bitdepth #{bitdepth}"

      image = Image.from_binary!(response.resp_body)
      assert [^expected] = Image.get_pixel!(image, 8, 8), "bitdepth #{bitdepth}"
    end
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
