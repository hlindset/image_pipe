defmodule ImagePipe.API.ErrorStatusWireTest do
  use ExUnit.Case, async: true

  import Plug.Test

  alias ImagePipe.SourceTest.RootHTTPAdapter

  @moduletag :tmp_dir

  defmodule StatusOrigin do
    @moduledoc false
    def init(opts), do: opts

    def call(conn, opts),
      do: Plug.Conn.send_resp(conn, Keyword.fetch!(opts, :status), "origin says no")
  end

  describe "local file sources" do
    setup %{tmp_dir: dir} do
      File.mkdir_p!(Path.join(dir, "album"))

      File.write!(
        Path.join(dir, "locked.png"),
        Image.new!(4, 4) |> Image.write!(:memory, suffix: ".png")
      )

      config =
        ImagePipe.Plug.init(
          sources: [
            path: [
              adapter: ImagePipe.Source.File,
              match: :path,
              options: [root: dir, root_id: "error-status-wire"]
            ]
          ]
        )

      %{config: config, dir: dir}
    end

    test "a missing file or a directory reads as not found", %{config: config} do
      for path <- ["/format=png/src/missing.png", "/format=png/src/album"] do
        conn = conn(:get, path) |> ImagePipe.Plug.call(config)
        assert {conn.status, conn.resp_body} == {404, "source not found"}, path
      end
    end

    test "a URL whose built-in scheme no source matches is an invalid source", %{
      config: config
    } do
      for source <- [
            "https://example.com/cat.png",
            "http://example.com/cat.png",
            "s3://b/cat.png"
          ] do
        conn = conn(:get, "/format=png/src/" <> source) |> ImagePipe.Plug.call(config)
        assert {conn.status, conn.resp_body} == {400, "invalid source"}, source
      end
    end

    test "a file the server can't read is a server error", %{config: config, dir: dir} do
      locked = Path.join(dir, "locked.png")
      File.chmod!(locked, 0o000)
      on_exit(fn -> File.chmod!(locked, 0o644) end)

      conn = conn(:get, "/format=png/src/locked.png") |> ImagePipe.Plug.call(config)
      assert {conn.status, conn.resp_body} == {500, "source unavailable"}
    end
  end

  describe "origin statuses" do
    for {origin_status, status} <- [{403, 404}, {401, 404}, {410, 404}, {429, 502}] do
      test "origin #{origin_status} answers #{status} without revealing the origin status" do
        config =
          ImagePipe.Plug.init(
            sources: [
              path: [
                adapter: RootHTTPAdapter,
                match: :path,
                options: [
                  root_url: "http://origin.test",
                  req_options: [plug: {StatusOrigin, status: unquote(origin_status)}]
                ]
              ]
            ]
          )

        conn = conn(:get, "/format=png/src/images/cat.jpg") |> ImagePipe.Plug.call(config)

        assert conn.status == unquote(status)
        refute conn.resp_body =~ Integer.to_string(unquote(origin_status))
      end
    end
  end
end
