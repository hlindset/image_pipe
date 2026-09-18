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

  test "native debug example exposes processing facts", %{conn: conn} do
    conn = get(conn, "/native-image/w=64/debug/src/images/dog.jpg")

    assert conn.status == 200
    assert get_resp_header(conn, "x-imagepipe-output-width") == ["64"]
    assert [_timings] = get_resp_header(conn, "server-timing")
  end

  test "native preset example expands nested transforms and the frame group", %{conn: conn} do
    conn = get(conn, "/native-image/preset=framed/src/images/dog.jpg")

    assert conn.status == 200
    assert get_resp_header(conn, "content-type") == ["image/webp"]
    {:ok, image} = Image.from_binary(conn.resp_body)
    assert {Image.width(image), Image.height(image)} == {440, 440}
  end

  test "native orientation example distinguishes display and stored dimensions", %{conn: conn} do
    auto = get(conn, "/native-image/format=png/src/images/orientation-6.jpg")
    none = get(conn, "/native-image/orient=none/format=png/src/images/orientation-6.jpg")

    assert auto.status == 200
    assert none.status == 200

    {:ok, auto_image} = Image.from_binary(auto.resp_body)
    {:ok, none_image} = Image.from_binary(none.resp_body)

    assert {Image.width(auto_image), Image.height(auto_image)} == {64, 96}
    assert {Image.width(none_image), Image.height(none_image)} == {96, 64}
  end
end
