# Run each mode in a fresh VM:
# mise exec -- mix run bench/coordinated_cache.exs two-pool
# mise exec -- mix run bench/coordinated_cache.exs output-only
# mise exec -- mix run bench/coordinated_cache.exs binary-source
Code.require_file("support/buffered_http.exs", __DIR__)

defmodule CoordinatedCacheBench do
  def run(mode) do
    root =
      Path.join(System.tmp_dir!(), "image-pipe-cache-bench-#{System.unique_integer([:positive])}")

    body = File.read!("priv/static/images/waterfall.jpg")
    fetched = :counters.new(1, [:atomics])
    events = :ets.new(:cache_bench, [:public, :bag])
    prefix = [:image_pipe_cache_bench]

    :telemetry.attach(
      {__MODULE__, self()},
      prefix ++ [:source, :fetch_decode, :stop],
      fn _event, _measure, meta, table -> :ets.insert(table, {:shrink, meta[:load_option]}) end,
      events
    )

    origin = fn conn, _opts ->
      :counters.add(fetched, 1, byte_size(body))

      conn
      |> Plug.Conn.put_resp_header("cache-control", "public, max-age=3600")
      |> Plug.Conn.put_resp_header("etag", ~s("original"))
      |> Plug.Conn.send_resp(200, body)
    end

    {:ok, supervisor} =
      Supervisor.start_link(
        [
          Supervisor.child_spec({Bandit, plug: origin, ip: {127, 0, 0, 1}, port: 0}, id: :origin),
          {Task.Supervisor, name: __MODULE__.Tasks}
        ],
        strategy: :one_for_one
      )

    {_, server, _, _} =
      Enum.find(Supervisor.which_children(supervisor), fn {id, _, _, _} -> id == :origin end)

    {:ok, {_, port}} = ThousandIsland.listener_info(server)

    config =
      ImagePipe.Plug.init(
        [
          sources: [
            url:
              {source_adapter(mode),
               allowed_hosts: ["127.0.0.1"], address_policy: [allow_loopback: true]}
          ],
          cache: {ImagePipe.Cache.FileSystem, root: Path.join(root, "output")},
          telemetry_prefix: prefix,
          max_body_bytes: 100_000_000,
          max_input_pixels: 100_000_000
        ] ++ input_options(mode, root)
      )

    paths =
      for {x, y} <- [{0.0, 0.0}, {0.5, 0.5}, {1.0, 1.0}], width <- [127, 256, 511, 801] do
        "/crop=1001,777/focus=#{x},#{y}/w=#{width}/format=jpeg/src/http://127.0.0.1:#{port}/image.jpg"
      end

    Vix.Vips.cache_set_max(0)
    sampler = Task.Supervisor.async_nolink(__MODULE__.Tasks, fn -> sample_rss(0) end)

    try do
      {cold_us, cold} = :timer.tc(fn -> traverse(paths, config) end)
      cold_bytes = :counters.get(fetched, 1)
      {warm_us, warm} = :timer.tc(fn -> traverse(paths, config) end)
      if cold != warm, do: raise("warm responses differ from cold responses")
      send(sampler.pid, :stop)
      rss = Task.await(sampler)

      report = %{
        mode: mode,
        variants: length(paths),
        concurrency: 4,
        cold_ms: cold_us / 1000,
        warm_ms: warm_us / 1000,
        cold_origin_bytes: cold_bytes,
        warm_origin_bytes: :counters.get(fetched, 1) - cold_bytes,
        input_stored_bytes: stored_bytes(Path.join(root, "input")),
        output_stored_bytes: stored_bytes(Path.join(root, "output")),
        rss_peak_bytes: rss,
        libvips_peak_bytes: Vix.Vips.tracked_get_mem_highwater(),
        decode_load_options:
          events
          |> :ets.tab2list()
          |> Enum.map(fn {_, value} -> inspect(value) end)
          |> Enum.uniq(),
        response_digests: cold
      }

      IO.puts(JSON.encode!(report))
    after
      Supervisor.stop(supervisor)
      File.rm_rf!(root)
      :telemetry.detach({__MODULE__, self()})
      :ets.delete(events)
    end
  end

  defp input_options("two-pool", root),
    do: [input_cache: {ImagePipe.Cache.FileSystem, root: Path.join(root, "input")}]

  defp input_options("output-only", _root), do: []
  defp input_options("binary-source", _root), do: []
  defp source_adapter("binary-source"), do: CoordinatedCacheBench.BufferedHTTP
  defp source_adapter(_mode), do: ImagePipe.Source.HTTP

  defp traverse(paths, config) do
    Task.Supervisor.async_stream_nolink(
      __MODULE__.Tasks,
      paths,
      fn path ->
        conn = Plug.Test.conn(:get, path) |> ImagePipe.Plug.call(config)
        if conn.status != 200, do: raise("request failed: #{conn.status}: #{conn.resp_body}")
        :crypto.hash(:sha256, conn.resp_body) |> Base.encode16(case: :lower)
      end,
      max_concurrency: 4,
      timeout: 60_000
    )
    |> Enum.map(fn {:ok, hash} -> hash end)
  end

  defp stored_bytes(root),
    do:
      Path.wildcard(Path.join(root, "**/*.body"))
      |> Enum.reduce(0, fn path, n -> n + File.stat!(path).size end)

  defp sample_rss(peak) do
    {rss, 0} = System.cmd("ps", ["-o", "rss=", "-p", System.pid()])
    peak = max(peak, String.to_integer(String.trim(rss)) * 1024)

    receive do
      :stop -> peak
    after
      10 -> sample_rss(peak)
    end
  end
end

CoordinatedCacheBench.run(List.first(System.argv()) || "two-pool")
