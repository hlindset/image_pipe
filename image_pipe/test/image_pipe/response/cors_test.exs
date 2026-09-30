defmodule ImagePipe.Response.CORSTest do
  use ExUnit.Case, async: true

  import Plug.Test
  import Plug.Conn, only: [get_resp_header: 2, send_resp: 3]

  alias ImagePipe.Response.CORS

  describe "maybe_register/2" do
    test "stamps Access-Control-Allow-Origin on send when allow_origin is set" do
      conn =
        conn(:get, "/x")
        |> CORS.maybe_register(allow_origin: "https://example.test")
        |> send_resp(200, "ok")

      assert get_resp_header(conn, "access-control-allow-origin") == ["https://example.test"]
    end

    test "no-op when allow_origin is absent" do
      conn =
        conn(:get, "/x")
        |> CORS.maybe_register([])
        |> send_resp(200, "ok")

      assert get_resp_header(conn, "access-control-allow-origin") == []
    end
  end

  describe "send_options/2" do
    test "204 + Allow always; Access-Control-Allow-Methods only when CORS on" do
      on =
        conn(:options, "/x")
        |> CORS.maybe_register(allow_origin: "*")
        |> CORS.send_options(allow_origin: "*")

      assert on.status == 204
      assert get_resp_header(on, "allow") == ["GET, HEAD"]
      assert get_resp_header(on, "access-control-allow-methods") == ["GET, HEAD, OPTIONS"]
      assert get_resp_header(on, "access-control-allow-origin") == ["*"]

      off =
        conn(:options, "/x")
        |> CORS.maybe_register([])
        |> CORS.send_options([])

      assert off.status == 204
      assert get_resp_header(off, "allow") == ["GET, HEAD"]
      assert get_resp_header(off, "access-control-allow-methods") == []
      assert get_resp_header(off, "access-control-allow-origin") == []
    end
  end
end
