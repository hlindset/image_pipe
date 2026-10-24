# Measures the FileSystem cache's startup scan. Generate a cache once, then
# measure it in a fresh VM per run, from `image_pipe/`:
#
#   mise exec -- mix run bench/startup_scan.exs generate DIR ENTRIES
#   mise exec -- mix run bench/startup_scan.exs measure DIR [--cold] [--unmarked]
#
# `generate` writes ENTRIES entries under DIR, and the cap to measure them
# with to `DIR.max_bytes`. Each entry has a real metadata file, copied from
# one entry this script commits, and an empty body whose filename carries a
# size of 2 KiB to 200 KiB and a cost of 1 to 200 ms, since the scan reads
# only filenames. Each metadata file still takes a 4 KiB block: 1M entries
# take about 4.3 GB and 2M inodes.
#
# `measure` starts an ImagePipe instance on DIR and reports how long the scan
# took to count the entries and to finish its sweep, the process RSS peak, the
# index's memory, and what a snapshot of the index would cost: its file size
# and the time to write it and load it back. `--cold` drops the page cache
# first, which needs root. `--unmarked` removes `.metadata-version`, so the
# sweep decodes every metadata file, as after an upgrade that bumps it.
defmodule StartupScanBench do
  alias ImagePipe.Cache.Entry
  alias ImagePipe.Cache.FileSystem
  alias ImagePipe.Cache.FileSystem.Admission
  alias ImagePipe.Cache.Key

  @prefix [:startup_scan_bench]
  # Generated entries average about 106 KiB charged, so a cap of 128 KiB an
  # entry holds them all and the scan evicts nothing. The sketch and the
  # doorkeeper are sized from the cap, as in production.
  @cap_per_entry 131_072

  def main(["generate", dir, entries]), do: generate(Path.expand(dir), String.to_integer(entries))

  def main(["measure", dir | flags]) do
    measure(Path.expand(dir), cold?: "--cold" in flags, unmarked?: "--unmarked" in flags)
  end

  defp generate(dir, entries) do
    File.mkdir_p!(dir)
    File.write!(cap_file(dir), Integer.to_string(entries * @cap_per_entry))
    template = template_meta(dir)
    :rand.seed(:exsss, {7, 11, 13})
    seeds = for _ <- 1..System.schedulers_online(), do: :rand.uniform(1_000_000_000)

    {elapsed, :ok} =
      :timer.tc(fn ->
        seeds
        |> Enum.with_index()
        |> Task.async_stream(
          fn {seed, worker} ->
            :rand.seed(:exsss, {seed, worker, 1})

            count =
              div(entries, length(seeds)) +
                if(worker < rem(entries, length(seeds)), do: 1, else: 0)

            for _ <- 1..count//1, do: write_entry(dir, template)
            :ok
          end,
          timeout: :infinity
        )
        |> Stream.run()
      end)

    IO.puts(JSON.encode!(%{generated: entries, dir: dir, elapsed_s: elapsed / 1_000_000}))
  end

  # One entry committed through the cache, so every generated metadata file
  # decodes as the cache's own would.
  defp template_meta(dir) do
    instance = start_instance(dir)
    key = %Key{hash: hex(32), data: []}
    opts = [root: dir, max_size_bytes: cap(dir)]

    metadata = %Entry.Metadata{
      content_type: "image/webp",
      headers: [{"vary", "accept"}],
      created_at: DateTime.utc_now(),
      output_format: :webp,
      cost_us: 25_000
    }

    payload = metadata |> Map.from_struct() |> Map.update!(:created_at, &DateTime.to_iso8601/1)
    {:ok, sink} = FileSystem.Store.open_sink(key, payload, opts)
    {:ok, sink} = FileSystem.Store.write_chunk(sink, :crypto.strong_rand_bytes(20_000), opts)
    :ok = FileSystem.Store.commit_sink(sink, opts)
    {:ok, %{meta_path: meta_path}} = FileSystem.Store.paths(key, opts)
    template = File.read!(meta_path)
    Supervisor.stop(instance)
    template
  end

  defp write_entry(dir, template) do
    <<a::binary-size(2), b::binary-size(2), _::binary>> = hash = hex(32)
    partition = Path.join([dir, a, b])
    size = 2_048 + :rand.uniform(202_752)
    cost = 1_000 + :rand.uniform(199_000)

    with {:error, :enoent} <-
           :prim_file.write_file(Path.join(partition, hash <> ".meta"), template) do
      File.mkdir_p!(partition)
      :ok = :prim_file.write_file(Path.join(partition, hash <> ".meta"), template)
    end

    body = FileSystem.Store.body_filename(hash, hex(32), size, cost)
    :ok = :prim_file.write_file(Path.join(partition, body), "")
  end

  defp measure(dir, cold?: cold?, unmarked?: unmarked?) do
    if unmarked?, do: File.rm(Path.join(dir, ".metadata-version"))
    if cold?, do: drop_caches()

    parent = self()
    handler = "startup-scan-bench-#{System.unique_integer([:positive])}"

    :telemetry.attach(
      handler,
      @prefix ++ [:cache, :sweep, :stop],
      fn _event, m, meta, _ ->
        send(parent, {:swept, m.duration, meta})
      end,
      nil
    )

    baseline = rss()
    sampler = spawn_link(fn -> sample_rss(baseline) end)
    started = System.monotonic_time()
    instance = start_instance(dir)
    [{admission, _value}] = Registry.lookup(FileSystem.registry_name(dir), dir)
    counted_ms = await_counted(admission, started)
    :ok = Admission.await_scan(admission, :infinity)
    complete_ms = ms_since(started)
    send(sampler, {:stop, self()})
    rss_peak = receive do: ({:rss, peak} -> peak)

    {sweep_us, sweep_meta} =
      receive do
        {:swept, duration, meta} ->
          {System.convert_time_unit(duration, :native, :microsecond), meta}
      after
        0 -> {nil, %{}}
      end

    usage = Admission.usage(admission, :infinity)
    entries = :sys.get_state(admission).entries
    index_bytes = :ets.info(entries, :memory) * :erlang.system_info(:wordsize)
    snapshot = snapshot(entries, dir, cold?)

    Supervisor.stop(instance)

    IO.puts(
      JSON.encode!(%{
        entries: usage.entries,
        cold: cold?,
        unmarked: unmarked?,
        counted_ms: counted_ms,
        scan_complete_ms: complete_ms,
        sweep_ms: sweep_us && sweep_us / 1_000,
        sweep_removed: Map.take(sweep_meta, [:temps, :bodies, :unreadable]),
        rss_baseline_bytes: baseline,
        rss_peak_bytes: rss_peak,
        index_ets_bytes: index_bytes,
        snapshot: snapshot
      })
    )
  end

  # The alternative to scanning after a clean stop: write the index on stop,
  # load it on start.
  defp snapshot(entries, dir, cold?) do
    path = Path.join(Path.dirname(dir), Path.basename(dir) <> ".snapshot")
    {write_us, :ok} = :timer.tc(fn -> :ets.tab2file(entries, String.to_charlist(path)) end)
    if cold?, do: drop_caches()
    {load_us, {:ok, table}} = :timer.tc(fn -> :ets.file2tab(String.to_charlist(path)) end)
    loaded = :ets.info(table, :size)
    size = File.stat!(path).size
    File.rm!(path)
    %{bytes: size, write_ms: write_us / 1_000, load_ms: load_us / 1_000, loaded_entries: loaded}
  end

  # Polls rather than waits: Admission marks the entries counted before the
  # sweep runs, and only the scan's completion has a waiter.
  defp await_counted(admission, started) do
    if Admission.usage(admission, :infinity).counting? do
      Process.sleep(10)
      await_counted(admission, started)
    else
      ms_since(started)
    end
  end

  defp start_instance(dir) do
    {:ok, instance} =
      Supervisor.start_link(
        [
          {ImagePipe,
           name: __MODULE__.Instance,
           allow_unsigned: true,
           sources: [
             files: [
               adapter: ImagePipe.Source.File,
               match: :path,
               options: [root: System.tmp_dir!(), root_id: "startup-scan-bench"]
             ]
           ],
           cache: [root: dir, max_size_bytes: cap(dir)],
           telemetry_prefix: @prefix}
        ],
        strategy: :one_for_one
      )

    instance
  end

  defp cap_file(dir), do: dir <> ".max_bytes"
  defp cap(dir), do: dir |> cap_file() |> File.read!() |> String.to_integer()

  defp drop_caches do
    {_, 0} = System.cmd("sync", [])
    File.write!("/proc/sys/vm/drop_caches", "3")
  end

  defp sample_rss(peak) do
    receive do
      {:stop, from} -> send(from, {:rss, max(peak, rss())})
    after
      20 -> sample_rss(max(peak, rss()))
    end
  end

  defp rss do
    {bytes, 0} = System.cmd("ps", ["-o", "rss=", "-p", System.pid()])
    String.to_integer(String.trim(bytes)) * 1024
  end

  defp ms_since(started),
    do: System.convert_time_unit(System.monotonic_time() - started, :native, :microsecond) / 1_000

  defp hex(bytes), do: bytes |> :crypto.strong_rand_bytes() |> Base.encode16(case: :lower)
end

StartupScanBench.main(System.argv())
