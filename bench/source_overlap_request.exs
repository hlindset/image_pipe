# Fresh-VM HTTP + input/output cache benchmark. Missing Content-Length forces spooling.
# mix run --no-compile --preload-modules bench/source_overlap_request.exs auto|spool IMAGE MIBPS
defmodule SourceOverlapRequestBench do
  def run([mode, path, rate]) do
    rate = String.to_integer(rate)
    body = File.read!(path)
    root = Path.join(System.tmp_dir!(), "overlap-request-#{System.unique_integer([:positive])}")
    {:ok, listener} = :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true])
    {:ok, {_, port}} = :inet.sockname(listener)
    events = :ets.new(:events, [:public])
    Vix.Vips.cache_set_max(0)
    Vix.Vips.cache_set_max_mem(0)

    :telemetry.attach(
      :overlap_bench,
      [:overlap_bench, :source, :fetch_decode, :stop],
      fn _, _, _, _ -> :ets.insert(events, {:decoded, System.monotonic_time(:microsecond)}) end,
      nil
    )

    server =
      Task.async(fn ->
        {:ok, socket} = :gen_tcp.accept(listener)
        {:ok, _} = :gen_tcp.recv(socket, 0)
        length = if mode == "auto", do: "content-length: #{byte_size(body)}\r\n", else: ""

        :ok =
          :gen_tcp.send(socket, [
            "HTTP/1.1 200 OK\r\nconnection: close\r\ncache-control: public, max-age=600\r\n",
            length,
            "\r\n"
          ])

        started = System.monotonic_time(:microsecond)
        send_body(socket, body, rate, started, 0)
        :ets.insert(events, {:downloaded, System.monotonic_time(:microsecond)})
        :gen_tcp.close(socket)
      end)

    config =
      ImagePipe.config(
        telemetry_prefix: [:overlap_bench],
        max_body_bytes: 100_000_000,
        max_input_pixels: 60_000_000,
        sources: [
          url:
            {ImagePipe.Source.HTTP,
             allowed_hosts: ["127.0.0.1"], address_policy: [allow_loopback: true]}
        ],
        cache: {ImagePipe.Cache.FileSystem, root: Path.join(root, "output")},
        input_cache: {ImagePipe.Cache.FileSystem, root: Path.join(root, "input")}
      )

    sampler = Task.async(fn -> sample_rss(0) end)

    try do
      started = System.monotonic_time(:microsecond)

      {:ok, result} =
        config
        |> ImagePipe.new()
        |> ImagePipe.group(resize: [width: 366])
        |> ImagePipe.output(format: :png)
        |> ImagePipe.run({:source, "http://127.0.0.1:#{port}/image"})

      elapsed = System.monotonic_time(:microsecond) - started
      Task.await(server)
      send(sampler.pid, :stop)
      rss = Task.await(sampler)
      [{:decoded, decoded}] = :ets.lookup(events, :decoded)
      [{:downloaded, downloaded}] = :ets.lookup(events, :downloaded)
      pixels = Image.from_binary!(result.data) |> Vix.Vips.Image.write_to_binary()
      {:ok, pixels} = pixels

      IO.puts(
        JSON.encode!(%{
          mode: mode,
          rate_mib_s: rate,
          total_ms: elapsed / 1000,
          opened_before_complete: decoded < downloaded,
          rss_peak_bytes: rss,
          libvips_peak_bytes: Vix.Vips.tracked_get_mem_highwater(),
          pixel_sha256: Base.encode16(:crypto.hash(:sha256, pixels), case: :lower)
        })
      )
    after
      :gen_tcp.close(listener)
      File.rm_rf!(root)
      :telemetry.detach(:overlap_bench)
    end
  end

  defp send_body(_socket, <<>>, _rate, _started, _sent), do: :ok

  defp send_body(socket, body, rate, started, sent) do
    size = min(byte_size(body), 65_536)
    <<chunk::binary-size(^size), rest::binary>> = body

    if rate > 0 do
      due = started + trunc((sent + size) * 1_000_000 / (rate * 1024 * 1024))
      Process.sleep(max(0, div(due - System.monotonic_time(:microsecond), 1000)))
    end

    :ok = :gen_tcp.send(socket, chunk)
    send_body(socket, rest, rate, started, sent + size)
  end

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

SourceOverlapRequestBench.run(System.argv())
