# Feasibility benchmark, not the ImagePipe request path. See docs/source-overlap.md.
# Run each sample in a fresh VM with --preload-modules.
# mix run --no-compile --preload-modules bench/source_overlap.exs MODE IMAGE MBPS SHRINK
defmodule SourceOverlapBench do
  alias Vix.Vips.Image, as: VipsImage

  @chunk_size 65_536

  def run(["probe", source]) do
    owner = self()
    ref = make_ref()
    {:ok, supervisor} = Task.Supervisor.start_link()

    task =
      Task.Supervisor.async_nolink(supervisor, fn ->
        stream =
          source
          |> File.stream!(@chunk_size)
          |> Stream.with_index()
          |> Stream.map(fn
            {bytes, 4} ->
              send(owner, {ref, :source_gated, self()})

              receive do
                {^ref, :continue} -> bytes
              after
                10_000 -> raise "probe gate was not released"
              end

            {bytes, _index} ->
              bytes
          end)

        {:ok, image} =
          VipsImage.new_from_enum(stream,
            access: :VIPS_ACCESS_SEQUENTIAL,
            fail_on: :VIPS_FAIL_ON_ERROR
          )

        send(owner, {ref, :header_opened})
        {:ok, resized} = Image.resize(image, 0.5)
        {:ok, pixels} = VipsImage.write_to_binary(resized)
        :crypto.hash(:sha256, pixels)
      end)

    try do
      receive do
        {^ref, :header_opened} -> :ok
      after
        10_000 -> raise "header open waited for the gated source tail"
      end

      receive do
        {^ref, :source_gated, producer} -> send(producer, {ref, :continue})
      after
        10_000 -> raise "source did not reach the gate"
      end

      digest = Task.await(task, 30_000)

      IO.puts(
        JSON.encode!(%{
          header_opened_before_tail_release: true,
          pixel_sha256: Base.encode16(digest, case: :lower)
        })
      )
    after
      Supervisor.stop(supervisor)
    end
  end

  def run([mode, source, rate, shrink]) do
    rate = String.to_integer(rate)
    shrink = String.to_integer(shrink)

    path =
      Path.join(
        System.tmp_dir!(),
        "overlap-#{System.pid()}-#{System.unique_integer([:positive])}"
      )

    events = :ets.new(:overlap_events, [:public, :set])
    {:ok, supervisor} = Task.Supervisor.start_link()
    Vix.Vips.cache_set_max(0)
    Vix.Vips.cache_set_max_mem(0)
    sampler = Task.Supervisor.async_nolink(supervisor, fn -> sample_rss(0) end)

    try do
      started = System.monotonic_time(:microsecond)
      stream = source_stream(source, path, rate, events, started)

      {:ok, header} = Image.open(source)
      {:ok, format} = ImagePipe.Decode.SourceFormat.from_image(header)
      load_options = if format == :jpeg, do: [shrink: shrink], else: []

      {:ok, options} =
        Image.Options.Open.validate_options(
          [access: :sequential, fail_on: :error] ++ load_options
        )

      image = open(mode, stream, path, options, events, File.stat!(source).size)
      opened = System.monotonic_time(:microsecond)
      {:ok, resized} = Image.resize(image, 0.5)
      {:ok, pixels} = VipsImage.write_to_binary(resized)
      finished = System.monotonic_time(:microsecond)

      # The image may stop reading at JPEG EOI before its producer closes the file.
      # Wait for resource cleanup independently of pixel evaluation.
      await_source(events)
      [{:source, downloaded, bytes, digest}] = :ets.lookup(events, :source)
      send(sampler.pid, :stop)
      rss = Task.await(sampler, 10_000)
      staged_digest = path |> File.read!() |> then(&:crypto.hash(:sha256, &1))
      true = digest == staged_digest
      true = bytes == File.stat!(source).size

      IO.puts(
        JSON.encode!(%{
          mode: mode,
          selection: selection(events, mode),
          source: source,
          rate_mib_s: rate,
          shrink: shrink,
          bytes: bytes,
          source_sha256: Base.encode16(digest, case: :lower),
          opened_ms: (opened - started) / 1000,
          downloaded_ms: (downloaded - started) / 1000,
          total_ms: (max(finished, downloaded) - started) / 1000,
          opened_before_complete: opened < downloaded,
          width: Image.width(resized),
          height: Image.height(resized),
          pixel_sha256: Base.encode16(:crypto.hash(:sha256, pixels), case: :lower),
          rss_peak_bytes: rss,
          libvips_peak_bytes: Vix.Vips.tracked_get_mem_highwater()
        })
      )
    after
      Supervisor.stop(supervisor)
      File.rm(path)
      :ets.delete(events)
    end
  end

  defp open("spool", stream, path, options, _events, _size) do
    Stream.run(stream)
    {:ok, image} = VipsImage.new_from_file(path, options)
    image
  end

  defp open("overlap", stream, _path, options, _events, _size) do
    {:ok, image} = VipsImage.new_from_enum(stream, options)
    image
  end

  defp open("auto", stream, path, options, events, size) do
    next = fn command ->
      Enumerable.reduce(stream, command, fn bytes, _acc -> {:suspend, bytes} end)
    end

    {prefix, continuation, count, elapsed} = prefix(next, [], 0, nil)
    remaining_ms = elapsed / 1000 * max(0, size - count) / max(1, count - @chunk_size)

    choice =
      case {continuation, elapsed >= 2_000 and remaining_ms >= 30} do
        {nil, _} -> "spool"
        {_, true} -> "overlap"
        {_, false} -> "spool"
      end

    :ets.insert(
      events,
      {:selection,
       %{
         mode: choice,
         prefix_bytes: count,
         sample_ms: elapsed / 1000,
         estimated_remaining_ms: remaining_ms
       }}
    )

    rest = resume(continuation)

    case choice do
      "overlap" ->
        open("overlap", Stream.concat(Enum.reverse(prefix), rest), path, options, events, size)

      "spool" ->
        open("spool", rest, path, options, events, size)
    end
  end

  defp prefix(next, chunks, count, first_at) do
    case next.({:cont, nil}) do
      {:suspended, bytes, continuation} ->
        now = System.monotonic_time(:microsecond)
        first_at = first_at || now
        count = count + byte_size(bytes)
        chunks = [bytes | chunks]

        case count >= 4 * @chunk_size do
          true -> {chunks, continuation, count, now - first_at}
          false -> prefix(continuation, chunks, count, first_at)
        end

      {status, _} when status in [:done, :halted] ->
        {chunks, nil, count, 0}
    end
  end

  defp resume(continuation) do
    Stream.resource(
      fn -> continuation end,
      fn
        nil ->
          {:halt, nil}

        next ->
          case next.({:cont, nil}) do
            {:suspended, bytes, next} -> {[bytes], next}
            {status, _} when status in [:done, :halted] -> {:halt, nil}
          end
      end,
      fn
        nil -> :ok
        next -> next.({:halt, nil})
      end
    )
  end

  defp selection(events, mode) do
    case :ets.lookup(events, :selection) do
      [] -> %{mode: mode}
      [{:selection, selection}] -> selection
    end
  end

  defp source_stream(source, path, rate, events, started) do
    owner = self()

    Stream.resource(
      fn ->
        {:ok, input} = File.open(source, [:read, :binary])
        {:ok, output} = File.open(path, [:write, :binary, :exclusive])
        {input, output, 0, :crypto.hash_init(:sha256)}
      end,
      fn {input, output, size, hash} = state ->
        case :file.read(input, @chunk_size) do
          {:ok, bytes} ->
            size = size + byte_size(bytes)
            pace(rate, size, started)
            :ok = :file.write(output, bytes)
            {[bytes], {input, output, size, :crypto.hash_update(hash, bytes)}}

          :eof ->
            {:halt, state}
        end
      end,
      fn {input, output, size, hash} ->
        :ok = File.close(input)
        :ok = File.close(output)

        :ets.insert(
          events,
          {:source, System.monotonic_time(:microsecond), size, :crypto.hash_final(hash)}
        )

        send(owner, {:source_complete, events})
      end
    )
  end

  defp pace(0, _size, _started), do: :ok

  defp pace(rate, size, started) do
    deadline = started + div(size * 1_000_000, rate * 1024 * 1024)
    wait = max(0, div(deadline - System.monotonic_time(:microsecond), 1000))

    receive do
    after
      wait -> :ok
    end
  end

  defp await_source(events) do
    receive do
      {:source_complete, ^events} -> :ok
    after
      10_000 -> raise "source producer did not finish"
    end
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

SourceOverlapBench.run(System.argv())
