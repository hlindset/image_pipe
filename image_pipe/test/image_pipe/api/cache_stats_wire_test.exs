defmodule ImagePipe.API.CacheStatsWireTest do
  use ExUnit.Case, async: true

  import Plug.Test

  alias ImagePipe.Cache.FileSystem.Admission
  alias ImagePipe.Cache.FileSystem.Owner
  alias ImagePipe.Cache.FileSystem.Store
  alias ImagePipe.Test.Caches

  setup context do
    root =
      Path.join(System.tmp_dir!(), "image-pipe-cache-stats-#{System.unique_integer([:positive])}")

    on_exit(fn -> File.rm_rf!(root) end)
    body = Image.new!(24, 16, color: :red) |> Image.write!(:memory, suffix: ".png")

    cache_control = Map.get(context, :cache_control, "public, max-age=3600")
    test = self()

    origin = fn conn ->
      conn = Plug.Conn.put_resp_header(conn, "cache-control", cache_control)

      case Plug.Conn.get_req_header(conn, "if-none-match") do
        [~s("a")] ->
          send(test, {:revalidated, self()})
          Plug.Conn.send_resp(conn, 304, "")

        _none ->
          conn
          |> Plug.Conn.put_resp_header("etag", ~s("a"))
          |> Plug.Conn.put_resp_content_type("image/png")
          |> Plug.Conn.send_resp(200, body)
      end
    end

    opts =
      Caches.start!(
        sources: [
          url: [
            adapter: ImagePipe.Source.HTTP,
            match: [scheme: ["http", "https"]],
            options: [
              allowed_hosts: ["origin.test"],
              address_resolver: fn _ -> {:ok, [{93, 184, 216, 34}]} end,
              req_options: [plug: origin]
            ]
          ]
        ],
        cache: [root: Path.join(root, "output"), max_size_bytes: 50_000_000]
      )

    await_scan(opts[:cache])

    %{opts: opts}
  end

  test "reports the cache's usage and its lookups since start", %{opts: opts} do
    assert get("/w=12/format=png/src/https://origin.test/a.png", opts) == 200
    assert get("/w=12/format=png/src/https://origin.test/a.png", opts) == 200
    assert get("/w=16/format=png/src/https://origin.test/a.png", opts) == 200

    assert %{output: output, originals: originals} = ImagePipe.cache_stats(Caches.instance(opts))

    assert %{
             hits: 1,
             misses: 2,
             read_errors: 0,
             write_errors: 0,
             max_bytes: 50_000_000,
             counting?: false,
             available: true,
             remembered_entries: 1,
             max_remembered_entries: 1_000
           } = output

    assert output.entries >= 2
    assert output.bytes > 0
    assert originals == %{entries: 1, max_entries: 10_000}
  end

  @tag cache_control: "public, max-age=0, stale-while-revalidate=60"
  test "counts a miss once when the original's record is stale", %{opts: opts} do
    assert get("/w=12/format=png/src/https://origin.test/a.png", opts) == 200
    assert get("/w=16/format=png/src/https://origin.test/a.png", opts) == 200
    assert_received {:revalidated, _request}

    assert %{output: %{hits: 0, misses: 2}} = ImagePipe.cache_stats(Caches.instance(opts))
  end

  @tag cache_control: "public, max-age=0, stale-while-revalidate=60"
  test "counts a hit once when the original's record is stale", %{opts: opts} do
    assert get("/w=12/format=png/src/https://origin.test/a.png", opts) == 200
    assert get("/w=12/format=png/src/https://origin.test/a.png", opts) == 200

    # The hit refreshes the image in the background.
    assert_receive {:revalidated, refresh}
    ref = Process.monitor(refresh)
    assert_receive {:DOWN, ^ref, :process, ^refresh, _reason}
    Caches.await_writes(opts)

    assert %{output: %{hits: 1, misses: 1}} = ImagePipe.cache_stats(Caches.instance(opts))
  end

  @tag capture_log: true
  test "counts an entry it can't read as a read error and a miss", %{opts: opts} do
    assert get("/w=12/format=png/src/https://origin.test/a.png", opts) == 200

    for meta <- Path.wildcard(Path.join(opts[:cache][:root], "**/*.meta")),
        do: File.write!(meta, "not metadata")

    assert get("/w=12/format=png/src/https://origin.test/a.png", opts) == 200

    assert %{output: %{hits: 0, misses: 2, read_errors: 1}} =
             ImagePipe.cache_stats(Caches.instance(opts))
  end

  @tag :file_permissions
  @tag capture_log: true
  test "counts an image the cache can't store as a write error", %{opts: opts} do
    root = Keyword.fetch!(opts[:cache], :root)
    File.chmod!(root, 0o500)
    on_exit(fn -> File.chmod(root, 0o700) end)

    assert get("/w=12/format=png/src/https://origin.test/a.png", opts) == 200
    assert get("/w=12/format=png/src/https://origin.test/a.png", opts) == 200

    assert %{output: %{hits: 0, misses: 2, write_errors: 2}} =
             ImagePipe.cache_stats(Caches.instance(opts))
  end

  @tag :file_permissions
  test "logs an error when the cache root can't be created", %{opts: opts} do
    parent = Path.dirname(Keyword.fetch!(opts[:cache], :root))
    locked = Path.join(parent, "locked")
    File.mkdir_p!(locked)
    File.chmod!(locked, 0o500)
    on_exit(fn -> File.chmod(locked, 0o700) end)
    root = Path.join(locked, "cache")

    log =
      ExUnit.CaptureLog.capture_log(fn ->
        Caches.start!(cache: [root: root, max_size_bytes: 1_000_000])
      end)

    assert log =~ "[error]"

    assert log =~
             "cache: can't use cache root #{root}: permission denied. " <>
               "Images are served without being stored until the root can be written."
  end

  test "reports a cache whose process exits while it's asked as unavailable", %{opts: opts} do
    admission = admission(opts[:cache])
    :sys.suspend(admission)
    stats = Task.async(fn -> ImagePipe.cache_stats(Caches.instance(opts)) end)
    await_queued(admission)
    Process.exit(admission, :kill)

    assert %{output: output} = Task.await(stats)
    assert_unavailable(output)
  end

  test "reports a busy cache as unavailable before the default call timeout", %{opts: opts} do
    admission = admission(opts[:cache])
    :sys.suspend(admission)

    {elapsed, stats} =
      :timer.tc(fn -> ImagePipe.cache_stats(Caches.instance(opts)) end, :millisecond)

    :sys.resume(admission)
    assert %{output: output} = stats
    assert_unavailable(output)
    assert elapsed < 5_000
  end

  test "reports a cache whose process is restarting as unavailable", %{opts: opts} do
    admission = admission(opts[:cache])
    {:dictionary, dictionary} = Process.info(admission, :dictionary)
    [supervisor | _ancestors] = Keyword.fetch!(dictionary, :"$ancestors")

    [id] =
      for {id, ^admission, _type, _modules} <- Supervisor.which_children(supervisor), do: id

    :ok = Supervisor.terminate_child(supervisor, id)

    assert %{output: output} = ImagePipe.cache_stats(Caches.instance(opts))
    assert_unavailable(output)
    {:ok, _pid} = Supervisor.restart_child(supervisor, id)
  end

  # Without usage, it keeps the size cap and the lookups.
  defp assert_unavailable(stats) do
    assert stats == %{
             available: false,
             refused: false,
             max_bytes: 50_000_000,
             hits: 0,
             misses: 0,
             read_errors: 0,
             write_errors: 0
           }
  end

  defp admission(cache_opts) do
    root = Keyword.fetch!(cache_opts, :root)
    [{pid, _value}] = Registry.lookup(Store.registry_name(root), root)
    pid
  end

  # Until the stats call itself is queued: other messages, such as the
  # startup scan's, can arrive first.
  defp await_queued(pid) do
    {:messages, messages} = Process.info(pid, :messages)

    unless Enum.any?(messages, &match?({:"$gen_call", _from, :usage}, &1)) do
      :erlang.yield()
      await_queued(pid)
    end
  end

  test "reports a cache whose root another node owns as refused", %{opts: opts} do
    root = Store.root_dir(opts[:cache])
    Owner.refuse(root)
    on_exit(fn -> Owner.accept(root) end)

    assert %{output: %{refused: true, max_bytes: 50_000_000} = output} =
             ImagePipe.cache_stats(Caches.instance(opts))

    assert map_size(output) == 2
  end

  test "leaves out a cache that isn't configured, but reports originals" do
    name = Module.concat(__MODULE__, NoCaches)
    start_supervised!({ImagePipe, name: name})

    assert ImagePipe.cache_stats(name) == %{originals: %{entries: 0, max_entries: 10_000}}
  end

  defp get(path, opts) do
    response = ImagePipe.Plug.call(conn(:get, path), Caches.plug(opts))
    Caches.await_writes(opts)
    response.status
  end

  defp await_scan(cache_opts) do
    root = Keyword.fetch!(cache_opts, :root)
    [{pid, _value}] = Registry.lookup(Store.registry_name(root), root)
    Admission.await_scan(pid)
  end
end
