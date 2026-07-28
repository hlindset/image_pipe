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

  test "GET /iiif-image processes a IIIF full/max request", %{conn: conn} do
    conn = get(conn, "/iiif-image/dog/full/max/0/default.jpg")
    assert conn.status == 200
    assert get_resp_header(conn, "content-type") |> hd() =~ "image/"
    assert get_resp_header(conn, "access-control-allow-origin") == ["*"]
  end

  test "GET /iiif-image honors region + size geometry", %{conn: conn} do
    conn = get(conn, "/iiif-image/dog/0,0,100,100/50,/0/default.jpg")
    assert conn.status == 200
    image = Image.open!(conn.resp_body, access: :random, fail_on: :error)
    assert Image.width(image) == 50
    assert Image.height(image) == 50
  end

  test "GET /iiif-image rejects a malformed rotation with 400", %{conn: conn} do
    conn = get(conn, "/iiif-image/dog/full/max/abc/default.jpg")
    assert conn.status == 400
  end

  test "GET /iiif-image returns 404 for an unknown identifier", %{conn: conn} do
    conn = get(conn, "/iiif-image/nope/full/max/0/default.jpg")
    assert conn.status == 404
  end

  test "OPTIONS /iiif-image answers CORS preflight", %{conn: conn} do
    conn = options(conn, "/iiif-image/dog/full/max/0/default.jpg")
    assert conn.status == 204
    assert get_resp_header(conn, "access-control-allow-methods") |> hd() =~ "GET"
    assert get_resp_header(conn, "access-control-allow-origin") == ["*"]
  end

  test "IIIF browser deep-link still serves the SPA shell", %{conn: conn} do
    conn = get(conn, "/iiif/dog/full/max/0/default.jpg")
    assert html_response(conn, 200) =~ ~s(id="fiddle-app")
  end

  test "GET /twic processes a TwicPics cover request", %{conn: conn} do
    conn = get(conn, twic_path())

    assert conn.status == 200
    assert get_resp_header(conn, "content-type") |> hd() =~ "image/jpeg"

    image = Image.open!(conn.resp_body, access: :random, fail_on: :error)
    assert {Image.width(image), Image.height(image)} == {200, 200}
    assert get_resp_header(conn, "x-imagepipe-output-format") == []
  end

  test "GET /twic keeps debug headers opt-in on the TwicPics chain", %{conn: conn} do
    conn = get(conn, twic_path() <> "/debug=1")

    assert conn.status == 200
    assert get_resp_header(conn, "content-type") |> hd() =~ "image/jpeg"

    image = Image.open!(conn.resp_body, access: :random, fail_on: :error)
    assert {Image.width(image), Image.height(image)} == {200, 200}
    assert get_resp_header(conn, "x-imagepipe-output-format") == ["jpeg"]
    assert get_resp_header(conn, "x-imagepipe-output-width") == ["200"]
  end

  defp twic_path,
    do: "/twic/images/dog.jpg?twic=v1/cover=200x200/output=jpeg"

  defp sign(signed_path, key_hex, salt_hex) do
    key = Base.decode16!(key_hex, case: :lower)
    salt = Base.decode16!(salt_hex, case: :lower)

    :crypto.mac(:hmac, :sha256, key, salt <> signed_path)
    |> binary_part(0, 32)
    |> Base.url_encode64(padding: false)
  end
end
