defmodule ImagePipeFiddleWeb.APIWireTest do
  use ImagePipeFiddleWeb.ConnCase, async: true

  test "API endpoint processes images through the default mount", %{conn: conn} do
    conn = get(conn, "/image/w=64/format=png/src/images/dog.jpg")

    assert conn.status == 200
    assert get_resp_header(conn, "content-type") == ["image/png"]
    {:ok, image} = Image.from_binary(conn.resp_body)
    assert Image.width(image) == 64
  end

  test "API endpoint returns API validation errors", %{conn: conn} do
    conn = get(conn, "/image/w=invalid/src/images/dog.jpg")
    assert conn.status == 400
  end

  test "API info download example returns source facts", %{conn: conn} do
    response =
      get(
        conn,
        "/image/output=info/filename=source-info/attachment/src/images/orientation-6.jpg"
      )

    assert response.status == 200
    assert get_resp_header(response, "content-type") == ["application/json; charset=utf-8"]

    assert get_resp_header(response, "content-disposition") == [
             ~s(attachment; filename="source-info.json")
           ]

    assert %{"width" => 64, "height" => 96, "orientation" => 6} = JSON.decode!(response.resp_body)
  end

  test "API BlurHash example returns text", %{conn: conn} do
    response = get(conn, "/image/w=100/output=blurhash/src/images/dog.jpg")

    assert response.status == 200
    assert get_resp_header(response, "content-type") == ["text/plain; charset=utf-8"]
    assert byte_size(response.resp_body) > 0
  end

  test "API debug example exposes processing facts", %{conn: conn} do
    conn = get(conn, "/image/w=64/debug/src/images/dog.jpg")

    assert conn.status == 200
    assert get_resp_header(conn, "x-imagepipe-output-width") == ["64"]
    assert [_timings] = get_resp_header(conn, "server-timing")
  end

  test "API preset example expands nested transforms and the frame group", %{conn: conn} do
    conn = get(conn, "/image/preset=framed/src/images/dog.jpg")

    assert conn.status == 200
    assert get_resp_header(conn, "content-type") == ["image/webp"]
    {:ok, image} = Image.from_binary(conn.resp_body)
    assert {Image.width(image), Image.height(image)} == {440, 440}
  end

  test "API orientation example distinguishes display and stored dimensions", %{conn: conn} do
    auto = get(conn, "/image/format=png/src/images/orientation-6.jpg")
    none = get(conn, "/image/orient=none/format=png/src/images/orientation-6.jpg")

    assert auto.status == 200
    assert none.status == 200

    {:ok, auto_image} = Image.from_binary(auto.resp_body)
    {:ok, none_image} = Image.from_binary(none.resp_body)

    assert {Image.width(auto_image), Image.height(auto_image)} == {64, 96}
    assert {Image.width(none_image), Image.height(none_image)} == {96, 64}
  end

  test "signing helper produces a request bound to its options", %{conn: conn} do
    response =
      post(conn, "/api/image-path", %{
        "tail" => "w=64/format=png/src/images/dog.jpg",
        "protection" => "signed"
      })

    assert response.status == 200
    assert %{"path" => path} = JSON.decode!(response.resp_body)
    assert String.starts_with?(path, "/image-signed/sig=")
    assert get(build_conn(), path).status == 200

    tampered = String.replace(path, "/w=64/", "/w=65/")
    assert get(build_conn(), tampered).status == 403
  end

  test "concealed helper paths hide the source and refresh after an option edit", %{conn: conn} do
    path_64 = protected_path(conn, "w=64/format=png/src/images/dog.jpg")
    path_65 = protected_path(build_conn(), "w=65/format=png/src/images/dog.jpg")

    for {path, width} <- [{path_64, 64}, {path_65, 65}] do
      assert String.starts_with?(path, "/image-signed/sig=")
      assert String.contains?(path, "/enc/")
      refute String.contains?(path, "images/dog.jpg")
      response = get(build_conn(), path)
      assert response.status == 200
      {:ok, image} = Image.from_binary(response.resp_body)
      assert Image.width(image) == width
    end

    refute path_64 == path_65
  end

  defp protected_path(conn, tail) do
    response =
      post(conn, "/api/image-path", %{
        "tail" => tail,
        "protection" => "signed-concealed"
      })

    assert response.status == 200
    assert %{"path" => path} = JSON.decode!(response.resp_body)
    path
  end
end
