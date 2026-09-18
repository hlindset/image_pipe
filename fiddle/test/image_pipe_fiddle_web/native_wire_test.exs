defmodule ImagePipeFiddleWeb.NativeWireTest do
  use ImagePipeFiddleWeb.ConnCase, async: true

  test "native endpoint processes images through the default mount", %{conn: conn} do
    conn = get(conn, "/native-image/w=64/format=png/src/images/dog.jpg")

    assert conn.status == 200
    assert get_resp_header(conn, "content-type") == ["image/png"]
    {:ok, image} = Image.from_binary(conn.resp_body)
    assert Image.width(image) == 64
  end

  test "native endpoint returns native validation errors", %{conn: conn} do
    conn = get(conn, "/native-image/w=invalid/src/images/dog.jpg")
    assert conn.status == 400
  end

  test "native preset example expands nested transforms and the frame group", %{conn: conn} do
    conn = get(conn, "/native-image/preset=framed/src/images/dog.jpg")

    assert conn.status == 200
    assert get_resp_header(conn, "content-type") == ["image/webp"]
    {:ok, image} = Image.from_binary(conn.resp_body)
    assert {Image.width(image), Image.height(image)} == {440, 440}
  end
end
