defmodule ImagePipe.API.CacheStatsWireTest do
  use ExUnit.Case, async: true

  import Plug.Test

  alias ImagePipe.Cache.FileSystem.Admission
  alias ImagePipe.Cache.FileSystem.Store
  alias ImagePipe.Test.Caches

  setup do
    root =
      Path.join(System.tmp_dir!(), "image-pipe-cache-stats-#{System.unique_integer([:positive])}")

    on_exit(fn -> File.rm_rf!(root) end)
    body = Image.new!(24, 16, color: :red) |> Image.write!(:memory, suffix: ".png")

    origin = fn conn ->
      conn
      |> Plug.Conn.put_resp_header("cache-control", "public, max-age=3600")
      |> Plug.Conn.put_resp_content_type("image/png")
      |> Plug.Conn.send_resp(200, body)
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
        cache: [root: Path.join(root, "output"), max_size_bytes: 50_000_000],
        input_cache: [root: Path.join(root, "input"), max_size_bytes: 20_000_000]
      )

    for key <- [:cache, :input_cache], do: await_scan(opts[key])

    %{opts: opts, body: body}
  end

  test "reports each cache's usage and its lookups since start", %{opts: opts, body: body} do
    assert get("/w=12/format=png/src/https://origin.test/a.png", opts) == 200
    assert get("/w=12/format=png/src/https://origin.test/a.png", opts) == 200
    assert get("/w=16/format=png/src/https://origin.test/a.png", opts) == 200

    assert %{output: output, input: input} = ImagePipe.cache_stats(Caches.instance(opts))

    assert %{hits: 1, misses: 2, read_errors: 0, max_bytes: 50_000_000, counting?: false} =
             output

    assert output.entries >= 2
    assert output.bytes > 0

    assert %{hits: 1, misses: 1, read_errors: 0, max_bytes: 20_000_000, counting?: false} =
             input

    assert input.entries == 1
    assert input.bytes == byte_size(body)
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

  test "leaves out a cache whose process exits while it's asked", %{opts: opts} do
    admission = admission(opts[:input_cache])
    :sys.suspend(admission)
    stats = Task.async(fn -> ImagePipe.cache_stats(Caches.instance(opts)) end)
    await_queued(admission)
    Process.exit(admission, :kill)

    assert %{output: _output} = result = Task.await(stats)
    refute Map.has_key?(result, :input)
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

  test "leaves out a cache that isn't configured" do
    name = Module.concat(__MODULE__, NoCaches)
    start_supervised!({ImagePipe, name: name})

    assert ImagePipe.cache_stats(name) == %{}
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
