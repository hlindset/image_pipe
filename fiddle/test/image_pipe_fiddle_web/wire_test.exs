defmodule ImagePipeFiddleWeb.WireTest do
  use ImagePipeFiddleWeb.ConnCase, async: true

  test "GET / serves the SPA shell", %{conn: conn} do
    conn = get(conn, "/")
    assert html_response(conn, 200) =~ ~s(id="fiddle-app")
  end

  test "deep-link path also serves the shell", %{conn: conn} do
    conn = get(conn, "/edit/w=640/h=360/fit=cover/src/images/dog.jpg")
    assert html_response(conn, 200) =~ ~s(id="fiddle-app")
  end

  test "GET /images/:file serves a raw static image", %{conn: conn} do
    conn = get(conn, "/images/dog.jpg")
    assert conn.status == 200
    assert get_resp_header(conn, "content-type") |> hd() =~ "image/"
  end

  test "API region and resize controls work through the demo mount", %{conn: conn} do
    conn = get(conn, "/image/region=0,0,100,100/w=50/src/images/dog.jpg")
    assert conn.status == 200
    image = Image.from_binary!(conn.resp_body)
    assert {Image.width(image), Image.height(image)} == {50, 50}
  end

  test "API watermarks composite each demo asset through the demo mount", %{conn: conn} do
    plain = get(conn, "/image/w=400/format=png/src/images/dog.jpg")
    assert plain.status == 200

    for asset <- ["logo", "mark", "badge"] do
      marked = get(conn, "/image/w=400/wm=#{asset}/wm-tile/format=png/src/images/dog.jpg")
      assert marked.status == 200, asset
      refute marked.resp_body == plain.resp_body, asset
    end
  end

  test "API rotation validates request input", %{conn: conn} do
    conn = get(conn, "/image/rotate=abc/src/images/dog.jpg")
    assert conn.status == 400
  end

  test "API OPTIONS answers CORS preflight", %{conn: conn} do
    conn = options(conn, "/image/src/images/dog.jpg")
    assert conn.status == 204
    assert get_resp_header(conn, "access-control-allow-methods") |> hd() =~ "GET"
    assert get_resp_header(conn, "access-control-allow-origin") == ["*"]
  end

  test "API browser deep-link serves the SPA shell", %{conn: conn} do
    conn = get(conn, "/edit/w=300/src/images/dog.jpg")
    assert html_response(conn, 200) =~ ~s(id="fiddle-app")
  end
end
