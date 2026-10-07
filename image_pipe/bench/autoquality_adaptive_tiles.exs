# From image_pipe/: mise exec -- mix run --no-compile
# bench/autoquality_adaptive_tiles.exs CORPUS manifest.json results.jsonl
# AUTOQUALITY_SIZES=4.2,5.96,8 AUTOQUALITY_REPEATS=1 AUTOQUALITY_REQUESTS=1
# AUTOQUALITY_VARIANTS=fixed8,fixed16,fixed32,adaptive05,adaptive10
# Optional controls: production16, fixed16_cached, adaptive05_cached, adaptive10_cached.
# Cached controls retain at most two materialized decoded candidates.
# AUTOQUALITY_PATHS optionally selects comma-separated relative corpus paths.
# Actual model wall time includes references, encodes, decodes and tile scoring.
# Full-frame and expanded-sample verification happens after all trials for a frame.
defmodule AutoqualityAdaptiveTilesBench do
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

  @levels [8, 12, 16, 24, 32]
  @variants ["fixed8", "fixed16", "fixed32", "adaptive05", "adaptive10"]
  @encode_budget 12

  def main([corpus, manifest, output]) do
    sizes = numbers("AUTOQUALITY_SIZES", "4.2,5.96,8")
    repeats = System.get_env("AUTOQUALITY_REPEATS", "1") |> String.to_integer()
    requests = System.get_env("AUTOQUALITY_REQUESTS", "1") |> String.to_integer()

    variants =
      System.get_env("AUTOQUALITY_VARIANTS", Enum.join(@variants, ",")) |> String.split(",")

    paths = System.get_env("AUTOQUALITY_PATHS")
    subjects = manifest |> File.read!() |> JSON.decode!() |> select(paths)
    configure_threads(System.get_env("AUTOQUALITY_VIPS_THREADS"))
    Vix.Vips.cache_set_max(0)
    Vix.Vips.cache_set_max_mem(0)
    File.write!(output, "")
    policy = resolve()

    emit(output, %{
      kind: :environment,
      elixir: System.version(),
      otp: System.otp_release(),
      libvips: Vix.Vips.version(),
      dirty_cpu_schedulers: :erlang.system_info(:dirty_cpu_schedulers),
      vips_concurrency: Vix.Vips.concurrency_get(),
      sizes: sizes,
      repeats: repeats,
      requests: requests,
      variants: variants,
      levels: @levels,
      encode_budget: @encode_budget,
      target: policy.quality_search.target,
      allowed_error: policy.quality_search.allowed_error,
      offset: 1.0
    })

    {:ok, warm} = Image.new(128, 128, color: [61, 137, 204])
    Enum.each(variants, &run_model(warm, policy, locations(warm), &1))

    Enum.each(subjects, fn subject ->
      base = open(Path.join(corpus, subject["path"]))

      for mp <- sizes, mp <= megapixels(base) do
        {:ok, resized} = Image.resize(base, :math.sqrt(mp / megapixels(base)))
        {:ok, sized} = VipsImage.copy_memory(resized)
        measure(sized, policy, subject, variants, repeats, requests, output)
        :erlang.garbage_collect()
      end
    end)
  end

  defp measure(base, policy, subject, variants, repeats, requests, output) do
    coords = locations(base)

    # Accuracy parity check, outside the timing region.
    custom = run_model(base, policy, coords, "fixed16")
    {:ok, body, meta} = EncodeSearch.run(base, policy, scorer: :crop)
    ^body = custom.body
    true = meta.quality == custom.quality and meta.score == custom.score

    rows =
      for trial <- 1..repeats,
          variant <- variant_order(variants, trial) do
        :erlang.garbage_collect()

        {elapsed_us, result} =
          :timer.tc(fn -> run_batch(base, policy, coords, variant, requests) end)

        Map.merge(result, %{trial: trial, variant: variant, elapsed_us: elapsed_us})
      end

    {:ok, full_ref} = Ssimulacra2.reference(base)
    {:ok, _full_body, full_meta} = EncodeSearch.run(base, policy, scorer: :full)
    diag_refs = references(base, coords)

    checks =
      rows
      |> Enum.uniq_by(& &1.quality)
      |> Map.new(fn row ->
        {:ok, candidate} = Image.from_binary(row.body)
        {:ok, truth} = Ssimulacra2.score(full_ref, candidate)
        scores = tile_scores(diag_refs, candidate) |> Map.new()

        nested =
          Enum.map(levels(coords), &%{tiles: &1, score: estimate(scores, Enum.take(coords, &1))})

        {row.quality, %{truth: truth, nested: nested}}
      end)

    Enum.each(rows, fn row ->
      check = Map.fetch!(checks, row.quality)

      emit(output, %{
        kind: :sample,
        source: subject["source"],
        path: subject["path"],
        split: subject["split"],
        format: :jpeg,
        dimensions: [Image.width(base), Image.height(base)],
        megapixels: megapixels(base),
        target: policy.quality_search.target,
        allowed_error: policy.quality_search.allowed_error,
        requests: requests,
        full_quality: full_meta.quality,
        full_bytes: full_meta.bytes,
        full_truth: full_meta.score,
        locations: Enum.map(coords, &Tuple.to_list/1),
        truth: check.truth,
        nested: check.nested,
        result: Map.delete(row, :body)
      })
    end)
  end

  defp run_batch(base, policy, coords, variant, 1), do: run_model(base, policy, coords, variant)

  defp run_batch(base, policy, coords, variant, requests) do
    [winner | others] =
      1..requests
      |> Task.async_stream(fn _ -> run_model(base, policy, coords, variant) end,
        max_concurrency: requests,
        timeout: :infinity
      )
      |> Enum.map(fn {:ok, result} -> result end)

    Enum.each(others, fn result -> ^winner = result end)
    winner
  end

  defp run_model(base, policy, coords, "production16") do
    {:ok, body, meta} = EncodeSearch.run(base, policy, scorer: :crop)
    tiles = min(16, length(coords))

    round = %{
      quality: meta.quality,
      score: meta.score,
      tiles: tiles,
      outcome: meta.outcome,
      trace: []
    }

    %{
      quality: meta.quality,
      score: meta.score,
      tiles: tiles,
      outcome: meta.outcome,
      stop: :fixed,
      rounds: [round],
      body: body,
      bytes: byte_size(body),
      body_sha256: :crypto.hash(:sha256, body) |> Base.encode16(case: :lower),
      encodes: meta.iterations,
      references: tiles,
      comparisons: meta.iterations * tiles,
      decodes: meta.iterations
    }
  end

  defp run_model(base, policy, coords, variant) do
    ctx = %{
      base: base,
      policy: policy,
      points: :ets.new(:points, [:set, :private]),
      refs: :ets.new(:refs, [:set, :private]),
      scores: :ets.new(:scores, [:set, :private]),
      decoded: :ets.new(:decoded, [:set, :private]),
      decoded_capacity: decoded_capacity(variant),
      counters: :ets.new(:counts, [:set, :private]),
      trace: :ets.new(:trace, [:ordered_set, :private])
    }

    try do
      result = model(ctx, coords, variant)
      body = body(ctx, result.quality)

      Map.merge(result, %{
        body: body,
        bytes: byte_size(body),
        body_sha256: :crypto.hash(:sha256, body) |> Base.encode16(case: :lower),
        encodes: :ets.info(ctx.points, :size),
        references: :ets.info(ctx.refs, :size),
        comparisons: :ets.info(ctx.scores, :size),
        decodes: count(ctx, :decodes),
        decoded_capacity: ctx.decoded_capacity,
        decoded_cache_rgb8_bytes:
          ctx.decoded_capacity * Image.width(base) * Image.height(base) * 3
      })
    after
      Enum.each(
        [ctx.points, ctx.refs, ctx.scores, ctx.decoded, ctx.counters, ctx.trace],
        &:ets.delete/1
      )
    end
  end

  defp model(ctx, coords, "fixed8"), do: fixed(ctx, Enum.take(coords, 8))
  defp model(ctx, coords, "fixed16"), do: fixed(ctx, Enum.take(coords, 16))
  defp model(ctx, coords, "fixed32"), do: fixed(ctx, coords)
  defp model(ctx, coords, "adaptive05"), do: grow(ctx, coords, levels(coords), nil, [], 0.5)
  defp model(ctx, coords, "adaptive10"), do: grow(ctx, coords, levels(coords), nil, [], 1.0)
  defp model(ctx, coords, "adaptive05_cached"), do: model(ctx, coords, "adaptive05")
  defp model(ctx, coords, "adaptive10_cached"), do: model(ctx, coords, "adaptive10")
  defp model(ctx, coords, "fixed16_cached"), do: model(ctx, coords, "fixed16")

  defp decoded_capacity(variant)
       when variant in ["adaptive05_cached", "adaptive10_cached", "fixed16_cached"],
       do: 2

  defp decoded_capacity(_variant), do: 0

  defp fixed(ctx, coords) do
    {:ok, result} = round_search(ctx, coords, nil)
    Map.merge(result, %{stop: :fixed, rounds: [result]})
  end

  defp grow(_ctx, _coords, [], previous, rounds, _tolerance),
    do: Map.merge(previous, %{stop: :locations_exhausted, rounds: Enum.reverse(rounds)})

  defp grow(ctx, coords, [size | rest], previous, rounds, tolerance) do
    sample = Enum.take(coords, size)

    case round_search(ctx, sample, previous) do
      {:error, :encode_budget} ->
        Map.merge(previous, %{stop: :encode_budget, rounds: Enum.reverse(rounds)})

      {:ok, result} ->
        rounds = [result | rounds]

        case stable?(ctx, coords, previous, result, tolerance) do
          true -> Map.merge(result, %{stop: :stable, rounds: Enum.reverse(rounds)})
          false -> grow(ctx, coords, rest, result, rounds, tolerance)
        end
    end
  end

  defp stable?(_ctx, _coords, nil, _result, _tolerance), do: false

  defp stable?(ctx, coords, previous, result, tolerance) do
    old_score = score(ctx, result.quality, Enum.take(coords, previous.tiles))
    qs = ctx.policy.quality_search

    abs(result.quality - previous.quality) <= 1 and
      abs(result.score - old_score) <= tolerance and
      result.score >= qs.target - qs.allowed_error and result.score <= qs.target + 1.0
  end

  defp round_search(ctx, coords, previous) do
    ensure_refs(ctx, coords)
    :ets.delete_all_objects(ctx.trace)
    qs = start_at(ctx.policy.quality_search, previous)

    encode_fun = fn quality ->
      with {:ok, body} <- encode(ctx, quality) do
        :ets.insert(ctx.trace, {:ets.info(ctx.trace, :size), quality})
        {:ok, body}
      end
    end

    score_fun = fn _body ->
      [{_, quality}] = :ets.lookup(ctx.trace, :ets.last(ctx.trace))
      score(ctx, quality, coords)
    end

    case EncodeSearch.search(qs, nil,
           encode_fun: encode_fun,
           score_fun: score_fun,
           max_iterations: 6
         ) do
      {:ok, _body, meta} ->
        {:ok,
         %{
           quality: meta.quality,
           score: meta.score,
           tiles: length(coords),
           outcome: meta.outcome,
           trace: Enum.map(:ets.tab2list(ctx.trace), fn {_, quality} -> quality end)
         }}

      {:error, :encode_budget} = error ->
        error
    end
  end

  defp start_at(qs, nil), do: qs
  defp start_at(qs, previous), do: %{qs | start_quality: previous.quality}

  defp encode(ctx, quality) do
    case :ets.lookup(ctx.points, quality) do
      [{_, body}] -> {:ok, body}
      [] -> encode_new(ctx, quality, :ets.info(ctx.points, :size))
    end
  end

  defp encode_new(_ctx, _quality, @encode_budget), do: {:error, :encode_budget}

  defp encode_new(ctx, quality, _count) do
    {:ok, body} = Encoder.encode_to_buffer(ctx.base, ctx.policy, quality)
    :ets.insert(ctx.points, {quality, body})
    {:ok, body}
  end

  defp body(ctx, quality) do
    [{_, body}] = :ets.lookup(ctx.points, quality)
    body
  end

  defp score(ctx, quality, coords) do
    missing = Enum.reject(coords, &:ets.member(ctx.scores, {quality, &1}))
    score_missing(ctx, quality, missing)

    scores =
      Map.new(coords, fn coord ->
        [{_, value}] = :ets.lookup(ctx.scores, {quality, coord})
        {coord, value}
      end)

    estimate(scores, coords)
  end

  defp score_missing(_ctx, _quality, []), do: :ok

  defp score_missing(ctx, quality, missing) do
    candidate = candidate(ctx, quality)

    refs =
      Enum.map(missing, fn coord ->
        [{_, ref}] = :ets.lookup(ctx.refs, coord)
        {coord, ref}
      end)

    Enum.each(tile_scores(refs, candidate), fn {coord, value} ->
      :ets.insert(ctx.scores, {{quality, coord}, value})
    end)
  end

  defp candidate(%{decoded_capacity: 0} = ctx, quality), do: decode(ctx, quality)

  defp candidate(ctx, quality) do
    stamp = :ets.update_counter(ctx.counters, :clock, {2, 1}, {:clock, 0})

    case :ets.lookup(ctx.decoded, quality) do
      [{_, {_old_stamp, image}}] ->
        :ets.insert(ctx.decoded, {quality, {stamp, image}})
        image

      [] ->
        evict_decoded(ctx)
        {:ok, memory} = VipsImage.copy_memory(decode(ctx, quality))
        :ets.insert(ctx.decoded, {quality, {stamp, memory}})
        memory
    end
  end

  defp evict_decoded(ctx) do
    case :ets.info(ctx.decoded, :size) == ctx.decoded_capacity do
      true ->
        {quality, _} =
          ctx.decoded |> :ets.tab2list() |> Enum.min_by(fn {_, {stamp, _}} -> stamp end)

        :ets.delete(ctx.decoded, quality)

      false ->
        :ok
    end
  end

  defp decode(ctx, quality) do
    {:ok, image} = Image.from_binary(body(ctx, quality))
    :ets.update_counter(ctx.counters, :decodes, {2, 1}, {:decodes, 0})
    image
  end

  defp ensure_refs(ctx, coords) do
    missing = Enum.reject(coords, &:ets.member(ctx.refs, &1))
    :ets.insert(ctx.refs, references(ctx.base, missing))
  end

  defp references(base, coords) do
    parallel(coords, fn {x, y, w, h} = coord ->
      {:ok, tile} = Image.crop(base, x, y, w, h)
      {:ok, ref} = Ssimulacra2.reference(tile)
      {coord, ref}
    end)
  end

  defp tile_scores(refs, candidate) do
    parallel(refs, fn {{x, y, w, h} = coord, ref} ->
      {:ok, tile} = Image.crop(candidate, x, y, w, h)
      {:ok, score} = Ssimulacra2.score(ref, tile)
      {coord, score}
    end)
  end

  defp parallel(items, fun) do
    items
    |> Task.async_stream(fun,
      max_concurrency: :erlang.system_info(:dirty_cpu_schedulers),
      timeout: :infinity
    )
    |> Enum.map(fn {:ok, value} -> value end)
  end

  defp estimate(scores, coords),
    do:
      coords
      |> Enum.map(&Map.fetch!(scores, &1))
      |> Enum.sort()
      |> CropScore.percentile(0.10)
      |> then(&(&1 - 1.0))

  defp locations(base) do
    w = Image.width(base)
    h = Image.height(base)
    shipped = CropScore.sample_tiles(w, h)
    anchors = spread(shipped, [], w, h)
    extras = spread(CropScore.tile_coords(w, h) -- shipped, anchors, w, h)
    Enum.take(anchors ++ extras, 32)
  end

  defp spread([], _selected, _w, _h), do: []

  defp spread(remaining, selected, w, h) do
    next = Enum.max_by(remaining, &distance(&1, selected, w, h))
    [next | spread(List.delete(remaining, next), [next | selected], w, h)]
  end

  defp distance({x, y, tw, th}, [], w, h),
    do: -(:math.pow((x + tw / 2) / w - 0.5, 2) + :math.pow((y + th / 2) / h - 0.5, 2))

  defp distance({x, y, _, _}, selected, w, h),
    do:
      selected
      |> Enum.map(fn {sx, sy, _, _} ->
        :math.pow((x - sx) / w, 2) + :math.pow((y - sy) / h, 2)
      end)
      |> Enum.min()

  defp levels(coords), do: @levels |> Enum.map(&min(&1, length(coords))) |> Enum.uniq()

  defp count(ctx, name) do
    case :ets.lookup(ctx.counters, name) do
      [] -> 0
      [{_, value}] -> value
    end
  end

  defp resolve do
    config = Config.validate!([])
    seg = fn raw -> {raw, {0, byte_size(raw)}} end

    lexed = %{
      segments: [seg.("format=jpeg"), seg.("autoquality")],
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
  defp configure_threads(nil), do: :ok
  defp configure_threads(value), do: Vix.Vips.concurrency_set(String.to_integer(value))
  defp select(subjects, nil), do: subjects

  defp select(subjects, paths),
    do: Enum.filter(subjects, &(&1["path"] in String.split(paths, ",")))

  defp variant_order(variants, trial) do
    {first, last} = Enum.split(variants, rem(trial - 1, length(variants)))
    last ++ first
  end

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

AutoqualityAdaptiveTilesBench.main(System.argv())
