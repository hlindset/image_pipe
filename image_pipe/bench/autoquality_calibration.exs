# From image_pipe/: mise exec -- mix run --no-compile
# bench/autoquality_calibration.exs CORPUS manifest.json results.jsonl
# AUTOQUALITY_SIZES=4.2,5.96 AUTOQUALITY_TARGETS=75
# AUTOQUALITY_OFFSETS=-2,-1,0,0.5,1 AUTOQUALITY_CAPS=6,12
# This is an accuracy experiment, not a latency benchmark. Each distinct quality
# is encoded and measured once, then shared across production search-core runs.
# Trace order and both scores separate estimator error from search overshoot.
defmodule AutoqualityCalibrationBench do
  alias ImagePipe.API.Parser
  alias ImagePipe.Output.EncodeSearch
  alias ImagePipe.Output.Encoder
  alias ImagePipe.Output.Metric.Ssimulacra2
  alias ImagePipe.Output.Policy
  alias ImagePipe.Output.RequestPolicy
  alias ImagePipe.Output.Ssim2Metric.CropScore
  alias ImagePipe.Plug.Config
  alias Vix.Vips.Image, as: VipsImage
  alias Vix.Vips.Operation

  def main([corpus, manifest, output]) do
    sizes = numbers("AUTOQUALITY_SIZES", "4.2,5.96")
    targets = numbers("AUTOQUALITY_TARGETS", "75")
    offsets = numbers("AUTOQUALITY_OFFSETS", "-2,-1,0,0.5,1")
    caps = numbers("AUTOQUALITY_CAPS", "6,12") |> Enum.map(&trunc/1)
    subjects = manifest |> File.read!() |> JSON.decode!()
    Vix.Vips.cache_set_max(0)
    Vix.Vips.cache_set_max_mem(0)
    File.write!(output, "")

    emit(output, %{
      kind: :environment,
      elixir: System.version(),
      otp: System.otp_release(),
      libvips: Vix.Vips.version(),
      dirty_cpu_schedulers: :erlang.system_info(:dirty_cpu_schedulers),
      vips_concurrency: Vix.Vips.concurrency_get(),
      sizes: sizes,
      targets: targets,
      offsets: offsets,
      caps: caps,
      jpeg_header_sampling: true,
      timing: :memoized_accuracy_only
    })

    Enum.each(subjects, fn %{"source" => source, "path" => relative, "split" => split} ->
      base = open(Path.join(corpus, relative))

      for mp <- sizes, mp <= megapixels(base) do
        {:ok, resized} = Image.resize(base, :math.sqrt(mp / megapixels(base)))
        {:ok, sized} = VipsImage.copy_memory(resized)
        measure(sized, source, relative, split, targets, offsets, caps, output)
        :erlang.garbage_collect()
      end
    end)
  end

  defp measure(base, source, path, split, targets, offsets, caps, output) do
    {:ok, truth_ref} = Ssimulacra2.reference(base)
    {:ok, refs} = CropScore.references(base)
    cache = :ets.new(:calibration_points, [:set, :private])
    trace = :ets.new(:calibration_trace, [:ordered_set, :private])

    try do
      runs =
        for target <- targets,
            cap <- caps,
            {scorer, offset} <- [{:full, 0.0} | Enum.map(offsets, &{:crop, &1})] do
          policy = resolve(target)
          probe = &point(cache, base, truth_ref, refs, policy, &1)
          run = search(policy, probe, trace, scorer, offset, cap, length(refs))
          Map.put(run, :target, target)
        end

      points =
        cache
        |> :ets.tab2list()
        |> Enum.map(fn {{:quality, _q}, point} -> Map.delete(point, :body) end)
        |> Enum.sort_by(& &1.quality)

      emit(output, %{
        kind: :case,
        source: source,
        path: path,
        split: split,
        format: :jpeg,
        dimensions: [Image.width(base), Image.height(base)],
        megapixels: megapixels(base),
        crop_sample_pixels: Enum.sum(Enum.map(refs, fn {{_, _, w, h}, _} -> w * h end)),
        runs: runs,
        points: points
      })
    after
      :ets.delete(cache)
      :ets.delete(trace)
    end
  end

  defp search(policy, probe, trace, scorer, offset, cap, tile_count) do
    :ets.delete_all_objects(trace)

    encode = fn quality ->
      point = probe.(quality)
      :ets.insert(trace, {:ets.info(trace, :size), point})
      {:ok, point.body}
    end

    score = fn _body ->
      [{_index, point}] = :ets.lookup(trace, :ets.last(trace))
      estimate(point, scorer) - offset
    end

    {:ok, _body, meta} =
      EncodeSearch.search(policy.quality_search, policy.max_bytes,
        encode_fun: encode,
        score_fun: score,
        scorer: scorer,
        scorer_tiles: tiles(scorer, tile_count),
        max_iterations: cap,
        telemetry_opts: []
      )

    point = probe.(meta.quality)

    %{
      scorer: scorer,
      offset: offset,
      cap: cap,
      quality: meta.quality,
      bytes: meta.bytes,
      body_sha256: point.body_sha256,
      estimated_score: meta.score,
      truth: point.truth,
      iterations: meta.iterations,
      outcome: meta.outcome,
      limiting_factor: meta.limiting_factor,
      allowed_error: policy.quality_search.allowed_error,
      trace: Enum.map(:ets.tab2list(trace), fn {_, point} -> point.quality end)
    }
  end

  defp tiles(:full, _count), do: nil
  defp tiles(:crop, count), do: count
  defp estimate(point, :full), do: point.truth
  defp estimate(point, :crop), do: point.p10

  defp point(cache, base, truth_ref, refs, policy, quality) do
    case :ets.lookup(cache, {:quality, quality}) do
      [{_, point}] ->
        point

      [] ->
        {:ok, body} = Encoder.encode_to_buffer(base, policy, quality)
        {:ok, candidate} = Image.from_binary(body)
        {:ok, memory} = VipsImage.copy_memory(candidate)
        {:ok, truth} = Ssimulacra2.score(truth_ref, memory)
        {:ok, p10} = CropScore.p10(refs, memory)

        point = %{
          quality: quality,
          body: body,
          body_sha256: :crypto.hash(:sha256, body) |> Base.encode16(case: :lower),
          bytes: byte_size(body),
          sampling: jpeg_sampling(body),
          truth: truth,
          p10: p10
        }

        :ets.insert(cache, {{:quality, quality}, point})
        point
    end
  end

  # Read SOF component sampling factors from the real encoded JPEG. This lets
  # score discontinuities be tied to codec behavior without changing the encoder.
  defp jpeg_sampling(<<0xFF, 0xD8, rest::binary>>), do: jpeg_frame(rest)

  defp jpeg_frame(<<0xFF, marker, size::16, payload::binary-size(size - 2), rest::binary>>) do
    case marker in [0xC0, 0xC1, 0xC2] do
      true ->
        <<_precision, _height::16, _width::16, _count, components::binary>> = payload
        for <<id, sampling, _table <- components>>, do: [id, div(sampling, 16), rem(sampling, 16)]

      false ->
        jpeg_frame(rest)
    end
  end

  defp resolve(target) do
    config = Config.validate!([])
    segment = fn raw -> {raw, {0, byte_size(raw)}} end

    lexed = %{
      segments: [segment.("format=jpeg"), segment.("autoquality=#{target}")],
      source: {:src, "bench.png", {0, 9}}
    }

    {:ok, request} = Parser.parse(lexed, config)
    {:ok, policy} = RequestPolicy.resolve(request.output, config, "")
    {:ok, resolved} = Policy.resolve(policy, :jpeg)
    resolved
  end

  defp open(path) do
    {:ok, image} = Image.open(path, access: :random)
    {:ok, srgb} = Operation.colourspace(image, :VIPS_INTERPRETATION_sRGB)
    {:ok, flattened} = Image.flatten(srgb, background: [255, 255, 255])
    {:ok, memory} = VipsImage.copy_memory(flattened)
    memory
  end

  defp megapixels(image), do: Image.width(image) * Image.height(image) / 1_000_000

  defp numbers(key, default) do
    System.get_env(key, default)
    |> String.split(",")
    |> Enum.map(fn value ->
      {number, ""} = Float.parse(value)
      number
    end)
  end

  defp emit(output, row) do
    File.write!(output, JSON.encode!(row) <> "\n", [:append])

    IO.puts(
      "#{row.kind}: #{Map.get(row, :path, "settings")} #{Map.get(row, :dimensions, []) |> inspect()}"
    )
  end
end

AutoqualityCalibrationBench.main(System.argv())
