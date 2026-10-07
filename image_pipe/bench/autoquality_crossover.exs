# Run from image_pipe/ with a corpus root and a JSON manifest of {source, path}
# objects (paths relative to the corpus root):
# mise exec -- mix run bench/autoquality_crossover.exs CORPUS manifest.json results.jsonl
# AUTOQUALITY_SIZES=1,2,3,4,5.96,6.04 (MP, downscale only)
# AUTOQUALITY_FORMATS=jpeg,webp,avif AUTOQUALITY_REPEATS=3
# AUTOQUALITY_REQUESTS=1 (concurrent searches per timed batch)
# AUTOQUALITY_VIPS_THREADS overrides libvips's per-operation thread count.
# Both modes use production resolution/search/encoder settings. Timings cover
# EncodeSearch.run/3 on an already finalized frame, including reference setup.
# Delivered full-frame scores are measured afterward, outside the timed region.
# Alternating mode order reduces bias from changing host load. Libvips's operation
# cache is disabled; memory counters describe the whole VM, including verification.
defmodule AutoqualityCrossoverBench do
  alias ImagePipe.API.Parser
  alias ImagePipe.Output.EncodeSearch
  alias ImagePipe.Output.Metric.Ssimulacra2
  alias ImagePipe.Output.Policy
  alias ImagePipe.Output.RequestPolicy
  alias ImagePipe.Output.Ssim2Metric.CropScore
  alias ImagePipe.Plug.Config
  alias Vix.Vips.Image, as: VipsImage
  alias Vix.Vips.Operation

  def main([corpus, manifest, output]) do
    sizes = numbers("AUTOQUALITY_SIZES", "1,2,3,4,5.96,6.04")
    formats = formats(System.get_env("AUTOQUALITY_FORMATS", "jpeg,webp,avif"))
    repeats = System.get_env("AUTOQUALITY_REPEATS", "3") |> String.to_integer()
    requests = System.get_env("AUTOQUALITY_REQUESTS", "1") |> String.to_integer()
    subjects = manifest |> File.read!() |> JSON.decode!()

    Vix.Vips.cache_set_max(0)
    Vix.Vips.cache_set_max_mem(0)
    configure_threads(System.get_env("AUTOQUALITY_VIPS_THREADS"))

    File.write!(output, "")

    emit(output, %{
      kind: :environment,
      elixir: System.version(),
      otp: System.otp_release(),
      libvips: Vix.Vips.version(),
      schedulers: :erlang.system_info(:schedulers_online),
      dirty_cpu_schedulers: :erlang.system_info(:dirty_cpu_schedulers),
      vips_concurrency: Vix.Vips.concurrency_get(),
      sizes: sizes,
      formats: formats,
      repeats: repeats,
      requests: requests,
      operation_cache: 0
    })

    resolved = Map.new(formats, &{&1, resolve(&1)})
    warmup(resolved)

    Enum.each(subjects, fn %{"source" => source, "path" => relative} ->
      path = Path.join(corpus, relative)
      base = open(path)

      for mp <- sizes, mp <= megapixels(base) do
        sized = resize(base, mp)
        bench_frame(sized, source, path, resolved, repeats, requests, output)
        :erlang.garbage_collect()
      end
    end)
  end

  defp bench_frame(base, source, path, resolved, repeats, requests, output) do
    for {format, policy} <- Enum.sort(resolved), trial <- 1..repeats do
      rows =
        for scorer <- order(trial) do
          :erlang.garbage_collect()

          {elapsed_us, {:ok, bytes, meta}} =
            :timer.tc(fn -> run_batch(base, policy, scorer, requests) end)

          # Hold only the encoded winners until both timings have finished.
          %{scorer: scorer, elapsed_us: elapsed_us, bytes: bytes, meta: meta}
        end

      {:ok, truth_ref} = Ssimulacra2.reference(base)

      Enum.each(rows, fn row ->
        {:ok, candidate} = Image.from_binary(row.bytes)
        {:ok, truth} = Ssimulacra2.score(truth_ref, candidate)

        emit(output, %{
          kind: :sample,
          source: source,
          label: Path.basename(path),
          format: format,
          dimensions: [Image.width(base), Image.height(base)],
          megapixels: megapixels(base),
          trial: trial,
          requests: requests,
          scorer: row.scorer,
          elapsed_us: row.elapsed_us,
          quality: row.meta.quality,
          bytes: byte_size(row.bytes),
          body_sha256: digest(row.bytes),
          truth: truth,
          estimated_score: row.meta.score,
          target: policy.quality_search.target,
          allowed_error: policy.quality_search.allowed_error,
          iterations: row.meta.iterations,
          outcome: row.meta.outcome,
          tiles: row.meta.tiles_scored,
          crop_sample_pixels: crop_sample_pixels(base),
          libvips_vm_peak_bytes: Vix.Vips.tracked_get_mem_highwater(),
          beam_vm_bytes: :erlang.memory(:total)
        })
      end)
    end
  end

  defp run_batch(base, policy, scorer, 1),
    do: EncodeSearch.run(base, policy, scorer: scorer)

  defp run_batch(base, policy, scorer, requests) do
    [winner | others] =
      1..requests
      |> Task.async_stream(fn _ -> EncodeSearch.run(base, policy, scorer: scorer) end,
        max_concurrency: requests,
        timeout: :infinity
      )
      |> Enum.map(fn {:ok, result} -> result end)

    Enum.each(others, fn result -> ^winner = result end)
    winner
  end

  defp resolve(format) do
    config = Config.validate!([])
    segment = fn raw -> {raw, {0, byte_size(raw)}} end

    lexed = %{
      segments: [segment.("format=#{format}"), segment.("autoquality")],
      source: {:src, "bench.png", {0, 9}}
    }

    {:ok, request} = Parser.parse(lexed, config)
    {:ok, policy} = RequestPolicy.resolve(request.output, config, "")
    {:ok, resolved} = Policy.resolve(policy, format)
    resolved
  end

  defp warmup(resolved) do
    {:ok, image} = Image.new(128, 128, color: [61, 137, 204])

    for {_format, policy} <- resolved, scorer <- [:full, :crop] do
      {:ok, _bytes, _meta} = EncodeSearch.run(image, policy, scorer: scorer)
    end
  end

  defp open(path) do
    {:ok, image} = Image.open(path, access: :random)
    {:ok, srgb} = Operation.colourspace(image, :VIPS_INTERPRETATION_sRGB)
    {:ok, flattened} = Image.flatten(srgb, background: [255, 255, 255])
    {:ok, memory} = VipsImage.copy_memory(flattened)
    memory
  end

  defp resize(image, mp) do
    {:ok, resized} = Image.resize(image, :math.sqrt(mp / megapixels(image)))
    {:ok, memory} = VipsImage.copy_memory(resized)
    memory
  end

  defp megapixels(image), do: Image.width(image) * Image.height(image) / 1_000_000

  defp crop_sample_pixels(image) do
    image
    |> then(&CropScore.sample_tiles(Image.width(&1), Image.height(&1)))
    |> Enum.map(fn {_x, _y, w, h} -> w * h end)
    |> Enum.sum()
  end

  defp order(trial) when rem(trial, 2) == 0, do: [:crop, :full]
  defp order(_trial), do: [:full, :crop]

  defp configure_threads(nil), do: :ok
  defp configure_threads(value), do: Vix.Vips.concurrency_set(String.to_integer(value))

  defp numbers(key, default) do
    System.get_env(key, default)
    |> String.split(",")
    |> Enum.map(fn value ->
      {number, ""} = Float.parse(value)
      number
    end)
  end

  defp formats(value) do
    value
    |> String.split(",")
    |> Enum.map(fn
      "jpeg" -> :jpeg
      "webp" -> :webp
      "avif" -> :avif
    end)
  end

  defp digest(bytes), do: :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)

  defp emit(output, row) do
    line = JSON.encode!(row)
    File.write!(output, line <> "\n", [:append])
    IO.puts(line)
  end
end

AutoqualityCrossoverBench.main(System.argv())
