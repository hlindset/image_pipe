# Run from image_pipe: mise exec -- mix run bench/source_coordination.exs file head
# HTTP uses an actual loopback origin with 10 ms latency. Optional third argument:
# public (default) or no-cache. Results are JSON lines from five warm rounds.
# SOURCE_COORDINATION_BASELINE_DIR can contain source_cache.ex and work.ex from
# the comparison revision. Both modes preload the same modules before timing.
# SOURCE_COORDINATION_ORIGIN_DELAY_MS and SOURCE_COORDINATION_REQUESTS override
# the origin delay and requests per round for a CPU-focused comparison.

defmodule SourceCoordinationBench do
  @prefix [:source_coordination_bench]

  def run([source, method | rest])
      when source in ["file", "http"] and method in ["head", "get"] do
    preload()

    root =
      Path.join(System.tmp_dir!(), "source-coordination-#{System.unique_integer([:positive])}")

    File.mkdir_p!(root)
    body = Image.new!(40, 24, color: :red) |> Image.write!(:memory, suffix: ".png")
    for n <- 0..7, do: File.write!(Path.join(root, "#{n}.png"), body)
    counts = :ets.new(:counts, [:set, :public])

    :telemetry.attach_many(
      __MODULE__,
      [@prefix ++ [:source, :fetch, :stop], @prefix ++ [:cache, :coordination]],
      &__MODULE__.event/4,
      counts
    )

    control = List.first(rest) || "public"
    {sources, paths, origin} = sources(source, root, body, control)

    {:ok, instance} =
      Supervisor.start_link(
        [
          {ImagePipe,
           [
             name: __MODULE__.Instance,
             sources: sources,
             cache:
               [
                root: Path.join(root, "output"), max_size_bytes: 100_000_000, node_id: "bench"],
             input_cache: [root: Path.join(root, "input")],
             telemetry_prefix: @prefix,
             clock: fn -> System.os_time(:second) + 10 end
           ]}
        ],
        strategy: :one_for_one
      )

    mount = ImagePipe.Plug.init(instance: __MODULE__.Instance)
    method = method(method)

    try do
      for path <- paths, do: request(:get, path, mount)
      for _ <- 1..20, do: request(method, hd(paths), mount)

      for round <- 1..5, distribution <- ["hot", "eight"] do
        :ets.delete_all_objects(counts)
        total = requests(source)
        :erlang.garbage_collect()

        {elapsed, results} =
          :timer.tc(fn ->
            0..7
            |> Task.async_stream(
              fn client ->
                path = Enum.at(paths, source_index(distribution, client))
                for _ <- 1..div(total, 8), do: request(method, path, mount)
                :ok
              end,
              max_concurrency: 8,
              timeout: :infinity
            )
            |> Enum.to_list()
          end)

        true = Enum.all?(results, &(&1 == {:ok, :ok}))

        IO.puts(
          JSON.encode!(%{
            source: source,
            method: method,
            control: control,
            round: round,
            distribution: distribution,
            requests: total,
            req_per_s: total * 1_000_000 / elapsed,
            counts:
              Map.new(:ets.tab2list(counts), fn {{stage, result}, n} ->
                {"#{stage}.#{result}", n}
              end),
            native_peak_bytes: Vix.Vips.tracked_get_mem_highwater(),
            beam_bytes: :erlang.memory(:total)
          })
        )
      end
    after
      Supervisor.stop(instance)
      stop_origin(origin)
      :telemetry.detach(__MODULE__)
      File.rm_rf!(root)
    end
  end

  def event(event, _measurements, metadata, counts) do
    stage = event |> Enum.drop(length(@prefix)) |> Enum.reject(&(&1 == :stop)) |> Enum.join(".")
    key = {stage, metadata.result}
    :ets.update_counter(counts, key, {2, 1}, {key, 0})
  end

  defp preload do
    for {name, current} <- [
          {"work.ex", "lib/image_pipe/cache/work.ex"},
          {"source_cache.ex", "lib/image_pipe/execution/source_cache.ex"}
        ] do
      path = preload_path(System.get_env("SOURCE_COORDINATION_BASELINE_DIR"), name, current)
      path |> File.read!() |> Code.compile_string()
    end
  end

  defp preload_path(nil, _name, current), do: current
  defp preload_path(dir, name, _current), do: Path.join(dir, name)
  defp method("head"), do: :head
  defp method("get"), do: :get

  defp requests(source) do
    default =
      case source do
        "file" -> 1600
        "http" -> 160
      end

    env_integer("SOURCE_COORDINATION_REQUESTS", default)
  end

  defp env_integer(name, default) do
    case System.get_env(name) do
      nil -> default
      value -> String.to_integer(value)
    end
  end

  defp source_index("hot", _client), do: 0
  defp source_index("eight", client), do: client
  defp stop_origin(nil), do: :ok
  defp stop_origin(origin), do: Supervisor.stop(origin)

  defp sources("file", root, _body, _control) do
    sources = [
      path: [
        adapter: ImagePipe.Source.File,
        match: :path,
        options: [root: root, root_id: "bench"]
      ]
    ]

    {sources, for(n <- 0..7, do: "/w=30/format=png/src/#{n}.png"), nil}
  end

  defp sources("http", _root, body, control) do
    delay = env_integer("SOURCE_COORDINATION_ORIGIN_DELAY_MS", 10)

    plug = fn conn, _opts ->
      Process.sleep(delay)
      conditional = Plug.Conn.get_req_header(conn, "if-none-match") == [~s("v1")]

      conn =
        conn
        |> Plug.Conn.put_resp_header("cache-control", control)
        |> Plug.Conn.put_resp_header("etag", ~s("v1"))
        |> Plug.Conn.put_resp_content_type("image/png")

      send_origin_response(conn, conditional, body)
    end

    {:ok, origin} = Bandit.start_link(plug: plug, port: 0, ip: :loopback, startup_log: false)
    {:ok, {_ip, port}} = ThousandIsland.listener_info(origin)

    sources = [
      url: [
        adapter: ImagePipe.Source.HTTP,
        match: [scheme: ["http"]],
        options: [
          allowed_hosts: ["127.0.0.1"],
          address_policy: [allow_loopback: true],
          address_resolver: fn _ -> {:ok, [{127, 0, 0, 1}]} end
        ]
      ]
    ]

    paths = for n <- 0..7, do: "/w=30/format=png/src/http://127.0.0.1:#{port}/#{n}.png"
    {sources, paths, origin}
  end

  defp send_origin_response(conn, true, _body), do: Plug.Conn.send_resp(conn, 304, "")
  defp send_origin_response(conn, false, body), do: Plug.Conn.send_resp(conn, 200, body)

  defp request(method, path, mount) do
    %{status: 200} = Plug.Test.conn(method, path) |> ImagePipe.Plug.call(mount)
    drain()
  end

  defp drain do
    receive do
      {:plug_conn, :sent} -> drain()
      {ref, _response} when is_reference(ref) -> drain()
    after
      0 -> :ok
    end
  end
end

SourceCoordinationBench.run(System.argv())
