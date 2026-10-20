# Run from image_pipe: mise exec -- mix run bench/full_cache.exs
# Requests 200 sizes of one file source, some far more often than others,
# through a processed-image cache too small to hold them all. Each round
# prints a JSON line with the renders, cache lookups, writes, dropped writes,
# admission results and evictions it caused, so a change to admission or
# eviction shows as fewer renders for the same requests.
#
# A cache drops a write when its unfinished writes would hold more than a
# twentieth of its size, so each output stays small and two clients (by
# default) send the requests. FULL_CACHE_REQUESTS, FULL_CACHE_MAX_BYTES, FULL_CACHE_SKEW and
# FULL_CACHE_CLIENTS override the requests per round, the cache size, the
# Zipf exponent and the number of clients. The requests are the same in every
# run; admission samples at random, so counts vary a little between runs.
#
# Each round also reports the time and bytes of cache writes by what happened
# to them, including the wait for admission's decision (a rejected write was
# written and synced before admission turned it away), the total and longest
# admission decision, and the deepest the admission process's message queue
# got, sampled every millisecond.

defmodule FullCacheBench do
  alias ImagePipe.Cache.FileSystem
  alias ImagePipe.Cache.FileSystem.Writers
  alias Vix.Vips.Operation

  @prefix [:full_cache_bench]
  @sizes 200

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
    [{admission, _value}] = Registry.lookup(FileSystem.registry_name(output), output)
    clients = env_integer("FULL_CACHE_CLIENTS", 2)
    requests = env_integer("FULL_CACHE_REQUESTS", 2000)
    weights = zipf(@sizes, env_float("FULL_CACHE_SKEW", 1.0))
    :rand.seed(:exsss, {1, 2, 3})

    try do
      for round <- 1..3 do
        :ets.delete_all_objects(counts)
        paths = for _ <- 1..requests, do: path(pick(weights, :rand.uniform()))

        sampler = spawn_link(fn -> sample_queue(admission, counts) end)

        {elapsed, :ok} =
          :timer.tc(fn ->
            paths
            |> Enum.chunk_every(max(div(requests + clients - 1, clients), 1))
            |> Task.async_stream(fn chunk -> Enum.each(chunk, &request(&1, mount)) end,
              max_concurrency: clients,
              timeout: :infinity
            )
            |> Stream.run()
          end)

        await_writes(output)
        stop(sampler)

        IO.puts(
          JSON.encode!(%{
            round: round,
            requests: requests,
            clients: clients,
            req_per_s: requests * 1_000_000 / elapsed,
            counts:
              Map.new(:ets.tab2list(counts), fn {{stage, outcome}, n} ->
                {"#{stage}.#{outcome}", printed(stage, n)}
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

  # Evictions count the entries and bytes they remove. Writes add up their
  # time and bytes, and admission decisions their time, kept in microseconds
  # and printed in milliseconds.
  def event(event, measurements, metadata, counts) do
    case stage(event) do
      [:cache, :eviction] = stage ->
        count(counts, {Enum.join(stage, "."), :entries}, measurements.count)
        count(counts, {Enum.join(stage, "."), :bytes}, measurements.bytes)

      [:cache, :write] = stage ->
        count(counts, {Enum.join(stage, "."), metadata.cache}, 1)
        count(counts, {"write_ms", metadata.cache}, micros(measurements.duration))
        count(counts, {"write_bytes", metadata.cache}, Map.get(metadata, :bytes, 0))

      [:cache, :admission] = stage ->
        us = micros(measurements.duration)
        count(counts, {Enum.join(stage, "."), metadata.result}, 1)
        count(counts, {"admission_ms", :total}, us)
        top(counts, {"admission_ms", :max}, us)

      stage ->
        count(counts, {Enum.join(stage, "."), outcome(stage, metadata)}, 1)
    end
  end

  defp count(counts, key, n), do: :ets.update_counter(counts, key, {2, n}, {key, 0})

  defp top(counts, key, n) do
    case :ets.lookup(counts, key) do
      [{^key, max}] when max >= n -> :ok
      _smaller -> :ets.insert(counts, {key, n})
    end
  end

  defp micros(native), do: System.convert_time_unit(native, :native, :microsecond)

  defp printed(stage, us) when stage in ["write_ms", "admission_ms"],
    do: Float.round(us / 1000, 1)

  defp printed(_stage, n), do: n

  # The deepest the admission process's mailbox gets during a round. A
  # restarted admission process ends the sampling.
  defp sample_queue(admission, counts) do
    case Process.info(admission, :message_queue_len) do
      {:message_queue_len, len} ->
        top(counts, {"admission_queue", :max}, len)
        Process.sleep(1)
        sample_queue(admission, counts)

      nil ->
        :ok
    end
  end

  # The sampler is gone before the next round clears the counts.
  defp stop(sampler) do
    Process.unlink(sampler)
    ref = Process.monitor(sampler)
    Process.exit(sampler, :kill)
    receive do: ({:DOWN, ^ref, :process, _pid, _reason} -> :ok)
  end

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
