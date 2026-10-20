defmodule ImagePipeServer.StatsTest do
  use ExUnit.Case, async: true

  import Plug.Conn
  import Plug.Test

  alias ImagePipeServer.Health
  alias ImagePipeServer.Router

  @moduletag :tmp_dir

  setup %{tmp_dir: root} do
    Image.new!(4, 4, color: :red) |> Image.write!(Path.join(root, "pic.png"))
    instance = Module.concat(__MODULE__, "I#{System.unique_integer([:positive])}")
    cache_root = Path.join(root, "output")

    start_supervised!(
      {ImagePipe,
       name: instance,
       sources: [
         static: [
           adapter: ImagePipe.Source.File,
           match: :path,
           options: [root: root, root_id: "static"]
         ]
       ],
       cache: [root: cache_root, max_size_bytes: 10_000_000]}
    )

    stats = %{
      token_hash: :crypto.hash(:sha256, "stats-token"),
      instance: instance,
      roots: %{output: cache_root}
    }

    opts = [
      mount_path: "/",
      image_pipe: ImagePipe.Plug.init(instance: instance),
      drain: Health.new(),
      stats: stats
    ]

    %{opts: opts, stats: stats}
  end

  test "/stats reports disk space for a cache root whose path has a space", %{
    opts: opts,
    stats: stats,
    tmp_dir: root
  } do
    spaced = Path.join(root, "cache root")
    File.mkdir_p!(spaced)
    opts = Keyword.put(opts, :stats, %{stats | roots: %{output: spaced}})

    conn = call(:get, "/stats", opts, "stats-token")

    assert %{"output" => output} = JSON.decode!(conn.resp_body)
    assert output["disk_total_bytes"] > 0
    assert output["disk_free_bytes"] > 0
  end

  test "/stats reports each cache as JSON", %{opts: opts} do
    assert %{status: 200} = call(:get, "/w=2/format=png/src/pic.png", opts)

    conn = call(:get, "/stats", opts, "stats-token")

    assert conn.status == 200
    assert ["application/json" <> _] = get_resp_header(conn, "content-type")

    assert %{"output" => output} = body = JSON.decode!(conn.resp_body)
    refute Map.has_key?(body, "input")

    assert %{"max_bytes" => 10_000_000, "hits" => 0, "misses" => 1, "read_errors" => 0} =
             output

    assert is_integer(output["bytes"]) and is_integer(output["entries"])
    assert is_boolean(output["counting"])
    assert output["disk_total_bytes"] > 0
    assert output["disk_free_bytes"] > 0
  end

  test "/metrics reports the same numbers as Prometheus text", %{opts: opts} do
    conn = call(:get, "/metrics", opts, "stats-token")

    assert conn.status == 200
    assert ["text/plain; version=0.0.4" <> _] = get_resp_header(conn, "content-type")
    assert conn.resp_body =~ ~s(# TYPE image_pipe_cache_lookups_total counter\n)
    assert conn.resp_body =~ ~s(image_pipe_cache_lookups_total{cache="output",result="hit"} 0\n)
    assert conn.resp_body =~ ~s(image_pipe_cache_max_bytes{cache="output"} 10000000\n)
    assert conn.resp_body =~ ~r/image_pipe_cache_disk_free_bytes\{cache="output"\} \d+\n/
  end

  test "needs the stats token, even with the image auth token", %{opts: opts} do
    opts = Keyword.put(opts, :auth_token_hash, :crypto.hash(:sha256, "image-token"))

    for token <- [nil, "wrong", "image-token"], path <- ["/stats", "/metrics"] do
      conn = call(:get, path, opts, token)

      assert conn.status == 401
      assert get_resp_header(conn, "www-authenticate") == ["Bearer"]
    end

    assert call(:get, "/stats", opts, "stats-token").status == 200
  end

  test "aren't served when stats are off", %{opts: opts} do
    opts = Keyword.merge(opts, stats: nil, mount_path: "/images")

    assert call(:get, "/stats", opts, "stats-token").status == 404
  end

  test "the health listener serves them too", %{stats: stats} do
    plug_opts = Health.init(drain: Health.new(), stats: stats)

    conn =
      conn(:get, "/stats")
      |> put_req_header("authorization", "Bearer stats-token")
      |> Health.call(plug_opts)

    assert conn.status == 200
    assert conn(:get, "/stats") |> Health.call(plug_opts) |> Map.fetch!(:status) == 401
    assert conn(:get, "/w=2/src/pic.png") |> Health.call(plug_opts) |> Map.fetch!(:status) == 404
  end

  defp call(method, path, opts, token \\ nil) do
    conn = conn(method, path)
    conn = if token, do: put_req_header(conn, "authorization", "Bearer " <> token), else: conn
    Router.call(conn, Router.init(opts))
  end
end
