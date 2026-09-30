defmodule ImagePipeServer.RouterTest do
  use ExUnit.Case, async: true

  import Plug.Conn
  import Plug.Test

  alias ImagePipeServer.Router

  @moduletag :tmp_dir

  setup %{tmp_dir: root} do
    Image.new!(4, 4, color: :red) |> Image.write!(Path.join(root, "pic.png"))

    image_pipe =
      ImagePipe.Plug.init(
        sources: [
          static: [
            adapter: ImagePipe.Source.File,
            match: :path,
            options: [root: root, root_id: "static"]
          ]
        ]
      )

    %{image_pipe: image_pipe}
  end

  test "GET /health answers 200", %{image_pipe: image_pipe} do
    conn = call(:get, "/health", mount_path: "/", image_pipe: image_pipe)

    assert conn.status == 200
    assert conn.resp_body == "ok"
  end

  test "serves images from the mount at the root", %{image_pipe: image_pipe} do
    conn = call(:get, "/w=2/format=png/src/pic.png", mount_path: "/", image_pipe: image_pipe)

    assert conn.status == 200
    assert ["image/png"] = Plug.Conn.get_resp_header(conn, "content-type")
    assert {:ok, image} = Image.from_binary(conn.resp_body)
    assert Image.width(image) == 2
  end

  describe "with a mount below the root" do
    test "serves images under the mount path", %{image_pipe: image_pipe} do
      conn =
        call(:get, "/images/w=2/format=png/src/pic.png",
          mount_path: "/images",
          image_pipe: image_pipe
        )

      assert conn.status == 200
      assert {:ok, image} = Image.from_binary(conn.resp_body)
      assert Image.width(image) == 2
    end

    test "keeps /health at the root", %{image_pipe: image_pipe} do
      conn = call(:get, "/health", mount_path: "/images", image_pipe: image_pipe)

      assert conn.status == 200
    end

    test "answers 404 outside the mount path", %{image_pipe: image_pipe} do
      conn =
        call(:get, "/w=2/format=png/src/pic.png", mount_path: "/images", image_pipe: image_pipe)

      assert conn.status == 404
    end
  end

  describe "with an auth token" do
    setup %{image_pipe: image_pipe} do
      %{
        opts: [
          mount_path: "/",
          image_pipe: image_pipe,
          auth_token_hash: :crypto.hash(:sha256, "t0k")
        ]
      }
    end

    test "serves requests with the bearer token", %{opts: opts} do
      conn =
        conn(:get, "/w=2/format=png/src/pic.png")
        |> put_req_header("authorization", "Bearer t0k")
        |> Router.call(Router.init(opts))

      assert conn.status == 200
    end

    test "rejects requests without it or with another token", %{opts: opts} do
      for header <- [nil, "Bearer other", "Basic dDBr", "Bearer"] do
        conn = conn(:get, "/w=2/format=png/src/pic.png")
        conn = if header, do: put_req_header(conn, "authorization", header), else: conn
        conn = Router.call(conn, Router.init(opts))

        assert conn.status == 401
        assert get_resp_header(conn, "www-authenticate") == ["Bearer"]
      end
    end

    test "leaves /health open", %{opts: opts} do
      assert conn(:get, "/health") |> Router.call(Router.init(opts)) |> Map.fetch!(:status) == 200
    end
  end

  defp call(method, path, opts) do
    conn(method, path) |> Router.call(Router.init(opts))
  end
end
