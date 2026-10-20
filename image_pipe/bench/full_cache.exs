# Run from image_pipe: mise exec -- mix run bench/full_cache.exs
# Requests 200 sizes of one file source, some far more often than others,
# through a processed-image cache too small to hold them all. Each round
# prints a JSON line with the renders, cache lookups, writes, dropped writes,
# admission results and evictions it caused, so a change to admission or
# eviction shows as fewer renders for the same requests.
#
# A cache drops a write when its unfinished writes would hold more than a
# twentieth of its size, so each output stays small and two clients send the
# requests. FULL_CACHE_REQUESTS, FULL_CACHE_MAX_BYTES and FULL_CACHE_SKEW
# override the requests per round, the cache size and the Zipf exponent. The
# requests are the same in every run; admission samples at random, so counts
# vary a little between runs.

defmodule FullCacheBench do
  alias ImagePipe.Cache.FileSystem.Writers
  alias Vix.Vips.Operation

  @prefix [:full_cache_bench]
  @sizes 200
  @clients 2

  def run do
    root = Path.join(System.tmp_dir!(), "full-cache-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)

    # Noise keeps each output from compressing to almost nothing.
    {:ok, noise} = Operation.gaussnoise(800, 600, sigma: 30.0, mean: 128.0)
    noise |> Image.cast!({:u, 8}) |> Image.write!(Path.join(root, "photo.png"))

    counts = :ets.new(:counts, [:set, :public])

    # The cache's admission and eviction report under the default prefix
    # (image_plug-q2px), so they're attached under both.
    :telemetry.attach_many(
      __MODULE__,
      [
        @prefix ++ [:transform, :execute, :stop],
        @prefix ++ [:cache, :lookup, :stop],
        @prefix ++ [:cache, :write, :stop],
        @prefix ++ [:cache, :stage]
      ] ++
        for(
          prefix <- [@prefix, [:image_pipe]],
          event <- [[:cache, :admission, :stop], [:cache, :eviction, :stop]],
          do: prefix ++ event
        ),
      &__MODULE__.event/4,
      counts
    )

    output = Path.join(root, "output")

    {:ok, instance} =
      Supervisor.start_link(
        [
          {ImagePipe,
           name: __MODULE__.Instance,
           sources: [
             files: [
               adapter: ImagePipe.Source.File,
               match: :path,
               options: [root: root, root_id: "full-cache-bench"]
             ]
           ],
           cache: [root: output, max_size_bytes: env_integer("FULL_CACHE_MAX_BYTES", 250_000)],
           telemetry_prefix: @prefix}
        ],
        strategy: :one_for_one
      )

    mount = ImagePipe.Plug.init(instance: __MODULE__.Instance)
    requests = env_integer("FULL_CACHE_REQUESTS", 2000)
    weights = zipf(@sizes, env_float("FULL_CACHE_SKEW", 1.0))
    :rand.seed(:exsss, {1, 2, 3})

    try do
      for round <- 1..3 do
        :ets.delete_all_objects(counts)
        paths = for _ <- 1..requests, do: path(pick(weights, :rand.uniform()))

        {elapsed, :ok} =
          :timer.tc(fn ->
            paths
            |> Enum.chunk_every(max(div(requests + @clients - 1, @clients), 1))
            |> Task.async_stream(fn chunk -> Enum.each(chunk, &request(&1, mount)) end,
              max_concurrency: @clients,
              timeout: :infinity
            )
            |> Stream.run()
          end)

        await_writes(output)

        IO.puts(
          JSON.encode!(%{
            round: round,
            requests: requests,
            req_per_s: requests * 1_000_000 / elapsed,
            counts:
              Map.new(:ets.tab2list(counts), fn {{stage, outcome}, n} ->
                {"#{stage}.#{outcome}", n}
              end)
          })
        )
      end
    after
      Supervisor.stop(instance)
      :telemetry.detach(__MODULE__)
      File.rm_rf!(root)
    end
  end

  # Evictions count the entries and bytes they remove.
  def event(event, measurements, metadata, counts) do
    case stage(event) do
      [:cache, :eviction] = stage ->
        count(counts, {Enum.join(stage, "."), :entries}, measurements.count)
        count(counts, {Enum.join(stage, "."), :bytes}, measurements.bytes)

      stage ->
        count(counts, {Enum.join(stage, "."), outcome(stage, metadata)}, 1)
    end
  end

  defp count(counts, key, n), do: :ets.update_counter(counts, key, {2, n}, {key, 0})

  defp stage(event), do: event |> Enum.reject(&(&1 == :stop)) |> Enum.take(-2)

  # Lookups by entry kind and hit or miss, writes by what happened to them,
  # renders and admission by their result. A request that misses looks up
  # again around its render, and writes and admissions include the records
  # of originals, so neither adds up to the requests.
  defp outcome([:cache, :lookup], metadata), do: "#{metadata.entry}_#{metadata.cache}"
  defp outcome([:cache, :stage], metadata), do: "#{metadata.cache}_#{metadata[:reason]}"
  defp outcome([:cache, :write], metadata), do: metadata.cache
  defp outcome(_stage, metadata), do: metadata.result

  defp path(size), do: "/w=#{40 + size}/format=jpeg/q=60/src/photo.png"

  # Cache writes finish after their responses.
  defp await_writes(cache_root) do
    case Writers.writers(cache_root) do
      [] ->
        :ok

      writers ->
        Enum.each(writers, fn pid ->
          ref = Process.monitor(pid)
          receive do: ({:DOWN, ^ref, :process, ^pid, _reason} -> :ok)
        end)

        await_writes(cache_root)
    end
  end

  defp request(path, mount) do
    conn = Plug.Test.conn(:get, path) |> ImagePipe.Plug.call(mount)
    200 = conn.status
  end

  # Cumulative weights for sizes 0..n-1, the first most often.
  defp zipf(n, skew) do
    weights = for rank <- 1..n, do: 1 / :math.pow(rank, skew)
    total = Enum.sum(weights)
    weights |> Enum.scan(&(&1 + &2)) |> Enum.map(&(&1 / total))
  end

  defp pick(cumulative, roll), do: Enum.find_index(cumulative, &(roll <= &1)) || 0

  defp env_integer(name, default),
    do: if(value = System.get_env(name), do: String.to_integer(value), else: default)

  defp env_float(name, default),
    do: if(value = System.get_env(name), do: String.to_float(value), else: default)
end

FullCacheBench.run()
