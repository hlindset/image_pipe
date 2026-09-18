defmodule ImagePipeFiddleWeb.WireTest do
  use ImagePipeFiddleWeb.ConnCase, async: true

  test "GET / serves the SPA shell", %{conn: conn} do
    conn = get(conn, "/")
    assert html_response(conn, 200) =~ ~s(id="fiddle-app")
  end

  test "deep-link path also serves the shell", %{conn: conn} do
    conn = get(conn, "/rs:fill:640:360/plain/local:///images/dog.jpg")
    assert html_response(conn, 200) =~ ~s(id="fiddle-app")
  end

  test "GET /images/:file serves a raw static image", %{conn: conn} do
    conn = get(conn, "/images/dog.jpg")
    assert conn.status == 200
    assert get_resp_header(conn, "content-type") |> hd() =~ "image/"
  end

  test "GET /img processes an unsigned request", %{conn: conn} do
    conn = get(conn, "/img/_/rs:fill:200:200/plain/local:///images/dog.jpg")
    assert conn.status == 200
    image = Image.open!(conn.resp_body, access: :random, fail_on: :error)
    assert Image.width(image) == 200
    assert Image.height(image) == 200
  end

  test "GET /img verifies a real HMAC-signed path under the mount", %{conn: conn} do
    signed_path = "/rs:fill:200:200/plain/local:///images/dog.jpg"
    signature = sign(signed_path, "736563726574", "68656c6c6f")
    conn = get(conn, "/img/#{signature}#{signed_path}")
    assert conn.status == 200
  end

  test "GET /img with a signed debug:1 option serves X-ImagePipe-* debug headers", %{conn: conn} do
    signed_path = "/debug:1/rs:fill:200:200/plain/local:///images/dog.jpg"
    signature = sign(signed_path, "736563726574", "68656c6c6f")
    conn = get(conn, "/img/#{signature}#{signed_path}")

    assert conn.status == 200
    assert get_resp_header(conn, "x-imagepipe-source-format") != []
    assert get_resp_header(conn, "x-imagepipe-output-format") == ["jpeg"]
    assert get_resp_header(conn, "x-imagepipe-output-width") == ["200"]
    assert get_resp_header(conn, "server-timing") != []
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

  defp sign(signed_path, key_hex, salt_hex) do
    key = Base.decode16!(key_hex, case: :lower)
    salt = Base.decode16!(salt_hex, case: :lower)

    :crypto.mac(:hmac, :sha256, key, salt <> signed_path)
    |> binary_part(0, 32)
    |> Base.url_encode64(padding: false)
  end
end
