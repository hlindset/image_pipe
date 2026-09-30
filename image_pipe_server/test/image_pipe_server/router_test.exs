defmodule ImagePipeServer.RouterTest do
  use ExUnit.Case, async: true

  import Plug.Test

  alias ImagePipeServer.Router

  @moduletag :tmp_dir

  setup %{tmp_dir: root} do
    Image.new!(4, 4, color: :red) |> Image.write!(Path.join(root, "pic.png"))

    image_pipe = [
      sources: [
        static: [
          adapter: ImagePipe.Source.File,
          match: :path,
          options: [root: root, root_id: "static"]
        ]
      ]
    ]

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

  defp call(method, path, opts) do
    conn(method, path) |> Router.call(Router.init(opts))
  end
end
