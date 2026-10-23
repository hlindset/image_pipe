defmodule ImagePipeServer.StatsTest do
  use ExUnit.Case, async: true

  import Plug.Conn
  import Plug.Test

  alias ImagePipeServer.Health
  alias ImagePipeServer.Router
  alias ImagePipeServer.Stats.Disk

  @moduletag :tmp_dir

  setup %{tmp_dir: root} do
    Image.new!(4, 4, color: :red) |> Image.write!(Path.join(root, "pic.png"))
    instance = Module.concat(__MODULE__, "I#{System.unique_integer([:positive])}")
    cache_root = Path.join(root, "output")

    start_supervised!(
      {ImagePipe,
       allow_unsigned: true,
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

    disk = start_disk(instance, [cache_root, Path.join(root, "cache root")])

    stats = %{
      token_hash: :crypto.hash(:sha256, "stats-token"),
      instance: instance,
      disk: disk,
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
    opts = Keyword.put(opts, :stats, %{stats | roots: %{output: spaced}})

    conn = call(:get, "/stats", opts, "stats-token")

    assert %{"output" => output} = JSON.decode!(conn.resp_body)
    assert output["disk_total_bytes"] > 0
    assert output["disk_free_bytes"] > 0
  end

  test "overlapping scrapes all get the disk sizes", %{opts: opts} do
    for {path, conn} <-
          ["/stats", "/metrics"]
          |> Stream.cycle()
          |> Enum.take(8)
          |> Task.async_stream(&{&1, call(:get, &1, opts, "stats-token")}, max_concurrency: 8)
          |> Enum.map(fn {:ok, result} -> result end) do
      case path do
        "/stats" ->
          assert %{"output" => %{"disk_free_bytes" => free, "disk_age_seconds" => age}} =
                   JSON.decode!(conn.resp_body)

          assert free > 0 and is_integer(age)

        "/metrics" ->
          assert conn.resp_body =~ ~r/image_pipe_cache_disk_free_bytes\{cache="output"\} \d+\n/
          assert conn.resp_body =~ ~r/image_pipe_cache_disk_age_seconds\{cache="output"\} \d+\n/
      end
    end
  end

  test "a cache root whose df hasn't succeeded has no disk sizes", %{
    opts: opts,
    stats: stats
  } do
    disk = start_disk(stats.instance, [stats.roots.output], command: "false", id: :failing)
    opts = Keyword.put(opts, :stats, %{stats | disk: disk})

    assert %{"output" => %{"disk_free_bytes" => nil, "disk_age_seconds" => nil}} =
             JSON.decode!(call(:get, "/stats", opts, "stats-token").resp_body)

    refute call(:get, "/metrics", opts, "stats-token").resp_body =~ ~r/^image_pipe_cache_disk/m
  end

  test "/stats answers 503 while the ImagePipe instance isn't running", %{
    opts: opts,
    stats: stats
  } do
    :ok = stop_supervised(stats.instance)

    for path <- ["/stats", "/metrics"] do
      assert call(:get, path, opts, "stats-token").status == 503
    end
  end

  test "a cache whose root another node owns is reported as refused", %{
    opts: opts,
    stats: stats
  } do
    root = stats.roots.output
    ImagePipe.Cache.FileSystem.Owner.refuse(root)
    on_exit(fn -> ImagePipe.Cache.FileSystem.Owner.accept(root) end)

    conn = call(:get, "/stats", opts, "stats-token")

    assert %{"output" => %{"refused" => true, "max_bytes" => 10_000_000} = output} =
             JSON.decode!(conn.resp_body)

    refute Map.has_key?(output, "hits")

    metrics = call(:get, "/metrics", opts, "stats-token").resp_body
    assert metrics =~ ~s(image_pipe_cache_refused{cache="output"} 1)
    refute metrics =~ ~s(image_pipe_cache_lookups_total{cache="output")
  end

  test "a cache whose process doesn't answer is reported as unavailable", %{
    opts: opts,
    stats: stats
  } do
    root = stats.roots.output

    [{admission, _value}] =
      Registry.lookup(ImagePipe.Cache.FileSystem.Store.registry_name(root), root)

    :sys.suspend(admission)
    json = call(:get, "/stats", opts, "stats-token").resp_body
    metrics = call(:get, "/metrics", opts, "stats-token").resp_body
    :sys.resume(admission)

    assert %{"output" => %{"available" => false, "max_bytes" => 10_000_000, "hits" => 0} = output} =
             JSON.decode!(json)

    refute Map.has_key?(output, "entries")

    assert metrics =~ ~s(image_pipe_cache_available{cache="output"} 0\n)
    assert metrics =~ ~s(image_pipe_cache_max_bytes{cache="output"} 10000000\n)
    assert metrics =~ ~s(image_pipe_cache_lookups_total{cache="output",result="hit"} 0\n)
    refute metrics =~ ~s(image_pipe_cache_entries{cache="output"})
  end

  test "/stats reports each cache as JSON", %{opts: opts} do
    assert %{status: 200} = call(:get, "/w=2/format=png/src/pic.png", opts)

    conn = call(:get, "/stats", opts, "stats-token")

    assert conn.status == 200
    assert ["application/json" <> _] = get_resp_header(conn, "content-type")

    assert %{"output" => output, "originals" => originals} = JSON.decode!(conn.resp_body)

    assert %{
             "max_bytes" => 10_000_000,
             "hits" => 0,
             "misses" => 1,
             "read_errors" => 0,
             "write_errors" => 0
           } = output

    assert %{"remembered_entries" => 0, "max_remembered_entries" => 1_000} = output
    assert %{"entries" => 1, "max_entries" => 10_000} = originals

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
    assert conn.resp_body =~ ~s(# TYPE image_pipe_cache_write_errors_total counter\n)
    assert conn.resp_body =~ ~s(image_pipe_cache_write_errors_total{cache="output"} 0\n)
    assert conn.resp_body =~ ~s(image_pipe_cache_max_bytes{cache="output"} 10000000\n)
    assert conn.resp_body =~ ~s(image_pipe_cache_refused{cache="output"} 0\n)
    assert conn.resp_body =~ ~s(image_pipe_cache_available{cache="output"} 1\n)
    assert conn.resp_body =~ ~r/image_pipe_cache_disk_free_bytes\{cache="output"\} \d+\n/
    assert conn.resp_body =~ ~s(image_pipe_cache_max_remembered_entries{cache="output"} 1000\n)
    assert conn.resp_body =~ ~s(image_pipe_remembered_originals 0\n)
    assert conn.resp_body =~ ~s(image_pipe_max_remembered_originals 10000\n)
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

  # A disk stats process with its first `df` for each root done.
  defp start_disk(instance, roots, opts \\ []) do
    Enum.each(roots, &File.mkdir_p!/1)
    {id, opts} = Keyword.pop(opts, :id, Disk)
    name = Module.concat(instance, id)

    pid =
      start_supervised!(
        {Disk, [name: name, roots: roots, interval: :infinity] ++ opts},
        id: id
      )

    for {_root, worker} <- :sys.get_state(pid).running do
      ref = Process.monitor(worker)
      assert_receive {:DOWN, ^ref, :process, ^worker, _reason}, 5_000
    end

    _ = :sys.get_state(pid)
    name
  end

  defp call(method, path, opts, token \\ nil) do
    conn = conn(method, path)
    conn = if token, do: put_req_header(conn, "authorization", "Bearer " <> token), else: conn
    Router.call(conn, Router.init(opts))
  end
end
