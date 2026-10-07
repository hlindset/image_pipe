defmodule ImagePipe.ForwardRouterTest do
  use ExUnit.Case, async: true

  alias ImagePipe.Test.ForwardRouter

  test "a compiled router forwards image requests with the default configuration" do
    conn =
      :get
      |> Plug.Test.conn("/images/w=4/format=png/src/small.png")
      |> ForwardRouter.call(ForwardRouter.init([]))

    assert conn.status == 200
    assert Plug.Conn.get_resp_header(conn, "content-type") == ["image/png"]
    assert {:ok, image} = Image.from_binary(conn.resp_body)
    assert Image.width(image) == 4
  end

  test "a percent-encoded mount prefix still reaches the forwarded plug" do
    conn =
      :get
      |> Plug.Test.conn("/%69mages/w=4/format=png/src/small.png")
      |> ForwardRouter.call(ForwardRouter.init([]))

    assert conn.status == 200
    assert {:ok, image} = Image.from_binary(conn.resp_body)
    assert Image.width(image) == 4
  end

  test "the default clock rejects expired requests through a compiled forward" do
    conn =
      :get
      |> Plug.Test.conn("/images/expires=1/src/small.png")
      |> ForwardRouter.call(ForwardRouter.init([]))

    assert conn.status == 410
  end
end
