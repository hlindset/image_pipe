# Run each mode in a fresh VM:
# mise exec -- mix run bench/cache_reads.exs streamed
# mise exec -- mix run bench/cache_reads.exs binary
defmodule CacheReadsBench do
  alias ImagePipe.Cache
  alias ImagePipe.Cache.Entry
  alias ImagePipe.Cache.File, as: CacheFile
  alias ImagePipe.Cache.FileSystem
  alias ImagePipe.Cache.Key

  def run(mode) do
    root = Path.join(System.tmp_dir!(), "cache-read-bench-#{System.unique_integer([:positive])}")
    opts = [root: root]
    config = [cache: {FileSystem, opts}]
    key = %Key{hash: String.duplicate("a", 64), data: []}
    chunk = String.duplicate("x", 1_048_576)
    sink = Cache.open_sink(key, {:complete_body, "application/json"}, config)
    sink = Cache.write_chunk(sink, "\"", config)
    sink = Enum.reduce(1..64, sink, fn _, sink -> Cache.write_chunk(sink, chunk, config) end)
    sink = Cache.write_chunk(sink, "\"", config)
    Cache.commit_sink(sink, config)
    :erlang.garbage_collect()
    baseline = rss()
    {:ok, supervisor} = Task.Supervisor.start_link()
    sampler = Task.Supervisor.async_nolink(supervisor, fn -> sample(baseline) end)

    try do
      {elapsed, {bytes, digest, largest}} = :timer.tc(fn -> read(mode, key, opts) end)
      send(sampler.pid, :stop)
      peak = Task.await(sampler)

      IO.puts(
        JSON.encode!(%{
          mode: mode,
          bytes: bytes,
          sha256: digest,
          largest_chunk: largest,
          elapsed_ms: elapsed / 1_000,
          rss_baseline_bytes: baseline,
          rss_peak_bytes: peak,
          rss_increase_bytes: max(0, peak - baseline)
        })
      )
    after
      Supervisor.stop(supervisor)
      File.rm_rf!(root)
    end
  end

  defp read("binary", key, opts) do
    {:hit, entry} = FileSystem.get(key, opts)
    {byte_size(entry.body), digest(:crypto.hash(:sha256, entry.body)), byte_size(entry.body)}
  end

  defp read("streamed", key, opts) do
    {:hit, entry} = FileSystem.open(key, opts)

    try do
      {size, hash, largest} =
        Enum.reduce(CacheFile.stream(entry.body), {0, :crypto.hash_init(:sha256), 0}, fn chunk,
                                                                                         {size,
                                                                                          hash,
                                                                                          largest} ->
          {size + byte_size(chunk), :crypto.hash_update(hash, chunk),
           max(largest, byte_size(chunk))}
        end)

      {size, digest(:crypto.hash_final(hash)), largest}
    after
      Entry.close(entry)
    end
  end

  defp digest(hash), do: Base.encode16(hash, case: :lower)

  defp rss do
    {bytes, 0} = System.cmd("ps", ["-o", "rss=", "-p", System.pid()])
    String.to_integer(String.trim(bytes)) * 1024
  end

  defp sample(peak) do
    peak = max(peak, rss())

    receive do
      :stop -> peak
    after
      1 -> sample(peak)
    end
  end
end

CacheReadsBench.run(List.first(System.argv()) || "streamed")
