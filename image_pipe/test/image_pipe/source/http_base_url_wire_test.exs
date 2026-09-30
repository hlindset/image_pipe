defmodule ImagePipe.Source.HTTPBaseURLWireTest do
  use ExUnit.Case, async: true

  import Plug.Test

  alias ImagePipe.Source.HTTP

  @public_ip {93, 184, 216, 34}

  setup do
    body = Image.new!(40, 30, color: :red) |> Image.write!(:memory, suffix: ".png")
    test_pid = self()

    origin = fn conn ->
      send(test_pid, {:origin, conn.host, conn.request_path})

      conn
      |> Plug.Conn.put_resp_content_type("image/png")
      |> Plug.Conn.send_resp(200, body)
    end

    mount =
      ImagePipe.Plug.init(
        sources: [
          path: [
            adapter: HTTP,
            match: :path,
            options: [
              base_url: "https://images.example.com/t/p/original",
              path_pattern: ~r/[a-z_]+\.png/,
              address_resolver: fn _host -> {:ok, [@public_ip]} end,
              req_options: [plug: origin]
            ]
          ]
        ]
      )

    %{mount: mount}
  end

  test "a path source is fetched from the base URL and processed", %{mount: mount} do
    conn = conn(:get, "/w=20/format=png/src/beach_day.png") |> ImagePipe.Plug.call(mount)

    assert conn.status == 200
    assert_received {:origin, "images.example.com", "/t/p/original/beach_day.png"}
    assert Image.width(Image.from_binary!(conn.resp_body)) == 20
  end

  test "paths outside the pattern or with dot segments are rejected before any fetch", %{
    mount: mount
  } do
    for path <- ["/src/Beach.png", "/src/dir/beach.png", "/src/../beach.png"] do
      conn = conn(:get, path) |> ImagePipe.Plug.call(mount)

      assert conn.status == 422, path
      refute_received {:origin, _host, _path}
    end
  end
end
