defmodule ImagePipeServer.ApplicationTest do
  use ExUnit.Case, async: true

  # The test run boots the application from test/support/server.toml.
  setup do
    {:ok, {_ip, port}} = ThousandIsland.listener_info(ImagePipeServer.Application.listener())
    %{base: "http://127.0.0.1:#{port}"}
  end

  test "answers /health over HTTP", %{base: base} do
    assert {:ok, %{status: 200, body: "ok"}} = Req.get(base <> "/health", retry: false)
  end

  test "serves an image from the configured File mount", %{base: base} do
    assert {:ok, %{status: 200, body: body}} =
             Req.get(base <> "/w=4/format=png/src/pic.png", retry: false, decode_body: false)

    assert {:ok, image} = Image.from_binary(body)
    assert {Image.width(image), Image.height(image)} == {4, 3}
  end
end
