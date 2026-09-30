defmodule ImagePipeServer.ApplicationTest do
  use ExUnit.Case, async: true

  test "the started application answers /health over HTTP" do
    {:ok, {_ip, port}} = ThousandIsland.listener_info(ImagePipeServer.Application.listener())

    assert {:ok, %{status: 200, body: "ok"}} =
             Req.get("http://127.0.0.1:#{port}/health", retry: false)
  end
end
