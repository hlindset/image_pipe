defmodule ImagePipeServer.RouterTest do
  use ExUnit.Case, async: true

  import Plug.Conn
  import Plug.Test

  alias ImagePipeServer.Health
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

  describe "health checks" do
    test "answer 200 while serving", %{image_pipe: image_pipe} do
      for path <- ["/health/live", "/health/ready"] do
        conn = call(:get, path, mount_path: "/", image_pipe: image_pipe, drain: serving())

        assert conn.status == 200
        assert conn.resp_body == "ok"
      end
    end

    test "answer not ready before the server is serving", %{image_pipe: image_pipe} do
      opts = [mount_path: "/", image_pipe: image_pipe, drain: Health.new()]

      assert %{status: 503, resp_body: "starting"} = call(:get, "/health/ready", opts)
      assert %{status: 200} = call(:get, "/health/live", opts)
    end

    test "answer not ready while draining, and close connections", %{image_pipe: image_pipe} do
      drain = Health.new()
      Health.drain(drain)
      opts = [mount_path: "/", image_pipe: image_pipe, drain: drain]

      assert %{status: 503} = ready = call(:get, "/health/ready", opts)
      assert %{status: 200} = live = call(:get, "/health/live", opts)
      assert %{status: 200} = image = call(:get, "/w=2/format=png/src/pic.png", opts)

      for conn <- [ready, live, image] do
        assert get_resp_header(conn, "connection") == ["close"]
      end
    end

    test "send no connection header over HTTP/2 while draining", %{image_pipe: image_pipe} do
      drain = Health.new()
      Health.drain(drain)
      opts = Router.init(mount_path: "/", image_pipe: image_pipe, drain: drain)

      for path <- ["/health/ready", "/health/live", "/w=2/format=png/src/pic.png"] do
        conn = conn(:get, path) |> put_http_protocol(:"HTTP/2") |> Router.call(opts)
        assert get_resp_header(conn, "connection") == [], path
      end
    end

    test "keep connections open while serving", %{image_pipe: image_pipe} do
      conn = call(:get, "/health/ready", mount_path: "/", image_pipe: image_pipe)
      assert get_resp_header(conn, "connection") == []
    end
  end

  test "serves images from the mount at the root", %{image_pipe: image_pipe} do
    conn = call(:get, "/w=2/format=png/src/pic.png", mount_path: "/", image_pipe: image_pipe)

    assert conn.status == 200
    assert ["image/png"] = Plug.Conn.get_resp_header(conn, "content-type")
    assert {:ok, image} = Image.from_binary(conn.resp_body)
    assert Image.width(image) == 2
  end

  describe "request IDs" do
    test "every response carries one", %{image_pipe: image_pipe} do
      opts = [mount_path: "/images", image_pipe: image_pipe]
      locked = Keyword.put(opts, :auth_token_hash, :crypto.hash(:sha256, "t0k"))

      for {path, opts, status} <- [
            {"/health/live", opts, 200},
            {"/images/w=2/format=png/src/pic.png", opts, 200},
            {"/elsewhere", opts, 404},
            {"/images/w=2/format=png/src/pic.png", locked, 401}
          ] do
        conn = call(:get, path, opts)
        assert conn.status == status
        assert [_id] = get_resp_header(conn, "x-request-id")
      end
    end

    defp request_id(incoming, opts) do
      conn(:get, "/health/live")
      |> put_req_header("x-request-id", incoming)
      |> Router.call(Router.init([mount_path: "/"] ++ opts))
      |> get_resp_header("x-request-id")
    end

    test "replaces an incoming one by default", %{image_pipe: image_pipe} do
      assert [id] = request_id("edge-request-0123456789", image_pipe: image_pipe)
      assert id != "edge-request-0123456789"
    end

    test "keeps an incoming one with trust_request_id", %{image_pipe: image_pipe} do
      opts = [image_pipe: image_pipe, trust_request_id: true]

      for id <- ["a", "edge-req_1.2:3", "Root=1-5759e988-bd862e3fe1be46a994272793", "YWJj+/=="] do
        assert request_id(id, opts) == [id]
      end
    end

    test "replaces a trusted one with other characters or over 200 long", %{
      image_pipe: image_pipe
    } do
      opts = [image_pipe: image_pipe, trust_request_id: true]

      for id <- ["edge request level=error", ~s(say"hi"), String.duplicate("a", 201)] do
        assert [generated] = request_id(id, opts)
        assert generated != id
      end
    end
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

    test "keeps the health checks at the root", %{image_pipe: image_pipe} do
      for path <- ["/health/live", "/health/ready"] do
        conn = call(:get, path, mount_path: "/images", image_pipe: image_pipe, drain: serving())
        assert conn.status == 200
      end
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
          auth_token_hash: :crypto.hash(:sha256, "t0k"),
          drain: serving()
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

    test "matches the scheme case-insensitively", %{opts: opts} do
      for header <- ["bearer t0k", "BEARER t0k"] do
        conn =
          conn(:get, "/w=2/format=png/src/pic.png")
          |> put_req_header("authorization", header)
          |> Router.call(Router.init(opts))

        assert conn.status == 200
      end
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

    test "leaves the health checks open", %{opts: opts} do
      for path <- ["/health/live", "/health/ready"] do
        assert conn(:get, path) |> Router.call(Router.init(opts)) |> Map.fetch!(:status) == 200
      end
    end
  end

  defp serving do
    drain = Health.new()
    Health.serve(drain)
    drain
  end

  defp call(method, path, opts) do
    conn(method, path) |> Router.call(Router.init(opts))
  end
end
