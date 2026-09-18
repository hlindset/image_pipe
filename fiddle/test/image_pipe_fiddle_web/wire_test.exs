defmodule ImagePipeFiddleWeb.WireTest do
  use ImagePipeFiddleWeb.ConnCase, async: true

  test "GET / serves the SPA shell", %{conn: conn} do
    conn = get(conn, "/")
    assert html_response(conn, 200) =~ ~s(id="fiddle-app")
  end

  test "deep-link path also serves the shell", %{conn: conn} do
    conn = get(conn, "/native/w=640/h=360/fit=cover/src/images/dog.jpg")
    assert html_response(conn, 200) =~ ~s(id="fiddle-app")
  end

  test "GET /images/:file serves a raw static image", %{conn: conn} do
    conn = get(conn, "/images/dog.jpg")
    assert conn.status == 200
    assert get_resp_header(conn, "content-type") |> hd() =~ "image/"
  end

  test "native region and resize controls work through the demo mount", %{conn: conn} do
    conn = get(conn, "/native-image/region=0,0,100,100/w=50/src/images/dog.jpg")
    assert conn.status == 200
    image = Image.from_binary!(conn.resp_body)
    assert {Image.width(image), Image.height(image)} == {50, 50}
  end

  test "native rotation validates request input", %{conn: conn} do
    conn = get(conn, "/native-image/rotate=abc/src/images/dog.jpg")
    assert conn.status == 400
  end

  test "native OPTIONS answers CORS preflight", %{conn: conn} do
    conn = options(conn, "/native-image/src/images/dog.jpg")
    assert conn.status == 204
    assert get_resp_header(conn, "access-control-allow-methods") |> hd() =~ "GET"
    assert get_resp_header(conn, "access-control-allow-origin") == ["*"]
  end

  test "native browser deep-link serves the SPA shell", %{conn: conn} do
    conn = get(conn, "/native/w=300/src/images/dog.jpg")
    assert html_response(conn, 200) =~ ~s(id="fiddle-app")
  end
end
