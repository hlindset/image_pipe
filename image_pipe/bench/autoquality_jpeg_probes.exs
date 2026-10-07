# From image_pipe/: mise exec -- mix run --no-compile
# bench/autoquality_jpeg_probes.exs CORPUS manifest.json output.jsonl
# AUTOQUALITY_SIZES=0.5,2,8 AUTOQUALITY_REPEATS=3
# AUTOQUALITY_SCOPE=pipeline includes local source decode/conditioning/resize.
# AUTOQUALITY_REQUESTS=4 measures concurrent batches (counts remain per request).
# Full search timing includes the extra final encode; pixel checks are outside timing.
Code.require_file("support/autoquality_research.exs", __DIR__)

defmodule AutoqualityJpegProbes do
  alias AutoqualityResearch, as: Bench
  alias ImagePipe.Output.EncodeSearch
  alias Vix.Vips.Image, as: VipsImage

  def main([corpus, manifest, output]) do
    Bench.configure()
    File.write!(output, "")
    repeats = System.get_env("AUTOQUALITY_REPEATS", "3") |> String.to_integer()
    sizes = Bench.numbers("AUTOQUALITY_SIZES", "0.5,2,8")
    scope = System.get_env("AUTOQUALITY_SCOPE", "search")
    requests = System.get_env("AUTOQUALITY_REQUESTS", "1") |> String.to_integer()

    policies = %{
      default: Bench.policy(:jpeg),
      progressive: Bench.policy(:jpeg, ["jpeg-options=progressive"])
    }

    Bench.emit(
      output,
      Map.merge(Bench.environment(), %{
        repeats: repeats,
        sizes: sizes,
        experiment: :jpeg_probes,
        scope: scope,
        requests: requests
      })
    )

    {:ok, warm} = Image.new(128, 128, color: [61, 137, 204])
    Enum.each(policies, fn {_name, policy} -> run(warm, policy, :deferred, nil) end)

    Enum.each(Bench.subjects(manifest), fn subject ->
      base = Bench.open(Path.join(corpus, subject["path"]))

      for mp <- sizes, mp <= Bench.megapixels(base) do
        sized = Bench.size(base, mp)
        checks(sized, policies, subject, output)
        source = Path.join(corpus, subject["path"])
        measure(sized, policies, subject, repeats, output, {source, mp, scope, requests})
        :erlang.garbage_collect()
      end
    end)
  end

  defp checks(base, policies, subject, output) do
    for q <- [50, 75, 89, 90, 95] do
      trial = cheap(base, q)
      pixels = Bench.pixels(trial)
      optimized = raw(base, q, "interlace=false,optimize-coding=true")
      true = pixels == Bench.pixels(optimized)

      results =
        Map.new(policies, fn {name, policy} ->
          final = Bench.production_encode(base, policy, q)
          true = pixels == Bench.pixels(final)
          {name, Map.merge(Bench.body_summary(final), %{identical_trial_body: final == trial})}
        end)

      Bench.emit(
        output,
        Map.merge(frame(base, subject), %{
          kind: :pixel_check,
          quality: q,
          exact_pixel_equivalence: true,
          trial: Bench.body_summary(trial),
          optimized: Bench.body_summary(optimized),
          final: results
        })
      )
    end
  end

  defp measure(base, policies, subject, repeats, output, pipeline) do
    # The injected core must reproduce the actual production wrapper.
    Enum.each(policies, fn {_name, policy} ->
      custom = run(base, policy, :normal, nil)
      {:ok, body, meta} = EncodeSearch.run(base, policy, scorer: Bench.scorer(base))
      ^body = custom.body
      true = meta.quality == custom.meta.quality and meta.score == custom.meta.score
    end)

    variants =
      for name <- [:default, :progressive], mode <- [:normal, :deferred], do: {name, mode}

    rows =
      for trial <- 1..repeats, {name, mode} <- Bench.rotate(variants, trial) do
        :erlang.garbage_collect()

        {elapsed, result} =
          :timer.tc(fn -> batch(base, Map.fetch!(policies, name), mode, pipeline) end)

        Map.merge(result, %{elapsed_us: elapsed, trial: trial, packaging: name, mode: mode})
      end

    Enum.each(rows, fn result ->
      Bench.emit(
        output,
        Map.merge(frame(base, subject), %{
          kind: :sample,
          truth: Bench.truth(base, result.body),
          result: Map.merge(Map.delete(result, :body), Bench.body_summary(result.body))
        })
      )
    end)

    # A size search cannot use the cheap container size as its final byte count.
    policy = Map.fetch!(policies, :progressive)
    baseline = Enum.find(rows, &(&1.packaging == :progressive and &1.mode == :normal))
    budget = trunc(byte_size(baseline.body) * 0.8)
    normal = run(base, policy, :normal, budget)
    checked = run(base, policy, :budget_checked, budget)
    true = normal.body == checked.body and normal.meta == checked.meta
    true = byte_size(checked.body) <= budget or checked.meta.limiting_factor == :max_bytes

    Bench.emit(
      output,
      Map.merge(frame(base, subject), %{
        kind: :budget_check,
        budget: budget,
        exact_final_body_equivalence: true,
        normal: Map.merge(Map.delete(normal, :body), Bench.body_summary(normal.body)),
        checked: Map.merge(Map.delete(checked, :body), Bench.body_summary(checked.body))
      })
    )

    IO.puts("jpeg probes: #{subject["path"]} #{Bench.megapixels(base)}MP")
  end

  defp batch(base, policy, mode, {source, mp, scope, 1}),
    do: pipeline(base, policy, mode, source, mp, scope)

  defp batch(base, policy, mode, {source, mp, scope, requests}) do
    [winner | others] =
      1..requests
      |> Task.async_stream(fn _ -> pipeline(base, policy, mode, source, mp, scope) end,
        max_concurrency: requests,
        timeout: :infinity
      )
      |> Enum.map(fn {:ok, row} -> row end)

    Enum.each(others, fn row -> ^winner = row end)
    winner
  end

  defp pipeline(base, policy, mode, _source, _mp, "search"), do: run(base, policy, mode, nil)

  defp pipeline(_base, policy, mode, source, mp, "pipeline"),
    do: run(source |> Bench.open() |> Bench.size(mp), policy, mode, nil)

  defp run(base, policy, mode, budget) do
    counts = :ets.new(:probe_counts, [:set, :private])

    try do
      context = Bench.score_context(base, Bench.scorer(base))

      encode = fn q ->
        :ets.update_counter(counts, :encodes, {2, 1}, {:encodes, 0})
        body = encode(base, policy, q, mode, counts)
        {:ok, body}
      end

      score = fn body ->
        :ets.update_counter(counts, :scores, {2, 1}, {:scores, 0})
        Bench.score(context, body)
      end

      {:ok, winner, meta} =
        EncodeSearch.search(policy.quality_search, budget,
          encode_fun: encode,
          score_fun: score,
          scorer: Bench.scorer(base)
        )

      {body, final_encodes} = final(base, policy, mode, winner, meta.quality)

      %{
        body: body,
        meta: meta,
        encodes: count(counts, :encodes) + final_encodes,
        metric_calls: count(counts, :scores),
        final_encodes: final_encodes,
        trial_winner_bytes: byte_size(winner)
      }
    after
      :ets.delete(counts)
    end
  end

  defp encode(base, policy, q, :normal, _counts), do: Bench.production_encode(base, policy, q)
  defp encode(base, _policy, q, :deferred, _counts), do: cheap(base, q)

  defp encode(base, policy, q, :budget_checked, counts) do
    trial = cheap(base, q)
    final = Bench.production_encode(base, policy, q)
    true = Bench.pixels(trial) == Bench.pixels(final)
    :ets.update_counter(counts, :encodes, {2, 1}, {:encodes, 0})
    final
  end

  defp final(base, policy, :deferred, _body, quality),
    do: {Bench.production_encode(base, policy, quality), 1}

  defp final(_base, _policy, _mode, body, _quality), do: {body, 0}

  defp cheap(base, q), do: raw(base, q, "interlace=false,optimize-coding=false")

  defp raw(base, q, options) do
    {:ok, body} = VipsImage.write_to_buffer(base, ".jpg[Q=#{q},#{options}]")
    body
  end

  defp count(table, key) do
    case :ets.lookup(table, key) do
      [] -> 0
      [{_, count}] -> count
    end
  end

  defp frame(base, subject),
    do:
      Map.merge(subject, %{
        dimensions: [Image.width(base), Image.height(base)],
        megapixels: Bench.megapixels(base),
        scorer: Bench.scorer(base)
      })
end

AutoqualityJpegProbes.main(System.argv())
