defmodule ImagePipe.Native.TerminalFileSystemCacheWireTest do
  use ExUnit.Case, async: true

  import Plug.Conn
  import Plug.Test

  alias ImagePipe.Cache.FileSystem
  alias ImagePipe.SourceTest.RootHTTPAdapter

  @terminals [
    {"output=info", nil},
    {"w=12/output=blurhash", "resize"}
  ]

  setup context do
    root = Path.join(System.tmp_dir!(), "image_pipe_terminal_fs_#{context.test}")
    File.rm_rf!(root)
    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf!(root) end)

    body =
      24
      |> Image.new!(16, color: :red)
      |> Image.write!(:memory, suffix: ".jpg")

    %{body: body, root: root}
  end

  test "info and BlurHash replay complete bodies and debug facts from FileSystem", %{
    body: body,
    root: root
  } do
    config = mount(body, root)

    for {terminal, pipeline} <- @terminals do
      plain = request(terminal, config)
      assert plain.status == 200, terminal
      assert_received :origin_fetch

      debug = request("#{terminal}/debug", config)
      assert debug.status == 200, terminal
      assert debug.resp_body == plain.resp_body, terminal
      assert header(debug, "x-imagepipe-cache") == "hit", terminal
      assert header(debug, "x-imagepipe-pipeline") == pipeline, terminal
      assert header(debug, "server-timing") =~ "total;dur=", terminal
      assert header(debug, "server-timing") =~ "cache;dur=", terminal
      refute_received :origin_fetch
    end
  end

  defp request(options, config) do
    conn(:get, "/#{options}/src/source.jpg")
    |> ImagePipe.Plug.call(config)
  end

  test "BlurHash without source byte identity has no ETag and cannot be stored by HTTP caches", %{
    body: body,
    root: root
  } do
    config = mount(body, root, :none)
    response = request("output=blurhash", config)

    assert response.status == 200
    assert get_resp_header(response, "etag") == []
    assert header(response, "cache-control") =~ "no-store"
  end

  defp mount(body, root, byte_identity \\ :strong) do
    test_pid = self()

    origin = fn conn ->
      send(test_pid, :origin_fetch)
      conn |> put_resp_content_type("image/jpeg") |> send_resp(200, body)
    end

    ImagePipe.Plug.init(
      sources: [
        path:
          {RootHTTPAdapter,
           root_url: "http://origin.test",
           byte_identity: byte_identity,
           internal_cache: :enabled,
           req_options: [plug: origin]}
      ],
      cache: {FileSystem, root: root},
      http_cache: [mode: :enabled],
      allow_debug_headers: true
    )
  end

  defp header(conn, name), do: conn |> get_resp_header(name) |> List.first()
end
