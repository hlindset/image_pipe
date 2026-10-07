# From image_pipe/: mise exec -- mix run --no-compile
# bench/autoquality_prediction.exs collect|evaluate CORPUS manifest.json OUTPUT [models.json]
# AUTOQUALITY_SIZES=0.5,2,8 AUTOQUALITY_REPEATS=3 AUTOQUALITY_FORMATS=jpeg,webp,avif
# Evaluation times local file read/decode, sRGB/flatten, resize, features, search,
# and encoded output. It excludes Plug orchestration, HTTP and cache delivery.
Code.require_file("support/autoquality_research.exs", __DIR__)
Code.require_file("support/autoquality_features.exs", __DIR__)
Code.require_file("../test/support/image_pipe/autoquality/content_classifier.ex", __DIR__)

defmodule AutoqualityPrediction do
  alias AutoqualityResearch, as: Bench
  alias ImagePipe.Output.{ContentClassifier, EncodeSearch}

  def main([mode, corpus, manifest, output | rest]) do
    Bench.configure()
    File.write!(output, "")

    formats =
      System.get_env("AUTOQUALITY_FORMATS", "jpeg,webp,avif")
      |> String.split(",")
      |> Enum.map(&format/1)

    sizes = Bench.numbers("AUTOQUALITY_SIZES", "0.5,2,8")
    repeats = System.get_env("AUTOQUALITY_REPEATS", "3") |> String.to_integer()
    models = load_models(mode, rest)
    subjects = Bench.subjects(manifest)

    Bench.emit(
      output,
      Map.merge(Bench.environment(), %{
        experiment: :prediction,
        mode: mode,
        sizes: sizes,
        formats: formats,
        repeats: repeats,
        feature_names: [
          "log_mp",
          "log_aspect",
          "crop",
          "log_adjacent",
          "log_squared",
          "log_coarse",
          "log_checker",
          "log_chroma",
          "log_spread"
        ]
      })
    )

    {:ok, warm} = Image.new(128, 128, color: [61, 137, 204])
    AutoqualityFeatures.extract(warm)
    ContentClassifier.classify(warm)
    Enum.each(formats, &EncodeSearch.run(warm, Bench.policy(&1), scorer: :full))

    Enum.each(subjects, fn subject ->
      native = Bench.open(Path.join(corpus, subject["path"]))

      for mp <- sizes, mp <= Bench.megapixels(native) do
        frame(mode, native, corpus, subject, mp, formats, repeats, models, output)
        :erlang.garbage_collect()
      end
    end)
  end

  defp frame("collect", native, _corpus, subject, mp, formats, _repeats, _models, output) do
    base = Bench.size(native, mp)
    measurements = for _ <- 1..3, do: :timer.tc(fn -> AutoqualityFeatures.extract(base) end)
    {_, features} = hd(measurements)
    true = Enum.all?(measurements, fn {_, value} -> value == features end)
    {class_us, {class, class_features}} = :timer.tc(fn -> ContentClassifier.classify(base) end)

    Enum.each(formats, fn format ->
      policy = Bench.policy(format)

      {elapsed_us, {:ok, body, meta}} =
        :timer.tc(fn -> EncodeSearch.run(base, policy, scorer: Bench.scorer(base)) end)

      Bench.emit(
        output,
        Map.merge(subject, %{
          kind: :label,
          dimensions: [Image.width(base), Image.height(base)],
          megapixels: Bench.megapixels(base),
          format: format,
          scorer: Bench.scorer(base),
          features: features,
          feature_us: Enum.map(measurements, &elem(&1, 0)),
          class: class,
          class_features: class_features,
          class_us: class_us,
          truth: Bench.truth(base, body),
          elapsed_us: elapsed_us,
          meta: meta,
          encoder_options: options(policy),
          body: Bench.body_summary(body)
        })
      )
    end)

    IO.puts("prediction labels: #{subject["path"]} #{mp}MP")
  end

  defp frame(
         "evaluate",
         _native,
         _corpus,
         %{"split" => "exploratory"},
         _mp,
         _formats,
         _repeats,
         _models,
         _output
       ),
       do: :ok

  defp frame("evaluate", _native, corpus, subject, mp, formats, repeats, models, output) do
    for format <- formats do
      model = Map.fetch!(models["models"], to_string(format))
      policy = Bench.policy(format)

      rows =
        for trial <- 1..repeats,
            variant <- Bench.rotate([:production, :class_lookup, :ridge], trial) do
          :erlang.garbage_collect()

          {elapsed_us, row} =
            :timer.tc(fn ->
              pipeline(Path.join(corpus, subject["path"]), mp, policy, model, variant)
            end)

          Map.merge(row, %{elapsed_us: elapsed_us, trial: trial, variant: variant})
        end

      # Independent truth checks are outside every variant's timed pipeline.
      base = corpus |> Path.join(subject["path"]) |> Bench.open() |> Bench.size(mp)

      Enum.each(rows, fn row ->
        Bench.emit(
          output,
          Map.merge(subject, %{
            kind: :sample,
            dimensions: [Image.width(base), Image.height(base)],
            megapixels: Bench.megapixels(base),
            format: format,
            scorer: Bench.scorer(base),
            truth: Bench.truth(base, row.body),
            encoder_options: options(policy),
            result: Map.merge(Map.delete(row, :body), Bench.body_summary(row.body))
          })
        )
      end)
    end

    IO.puts("prediction evaluation: #{subject["path"]} #{mp}MP")
  end

  defp pipeline(path, mp, policy, model, variant) do
    {prepare_us, base} = :timer.tc(fn -> path |> Bench.open() |> Bench.size(mp) end)

    {feature_us, starting_quality} =
      :timer.tc(fn -> starting_quality(base, policy, model, variant) end)

    qs = %{policy.quality_search | start_quality: starting_quality}
    adjusted = %{policy | quality_search: qs}

    {search_us, {:ok, body, meta}} =
      :timer.tc(fn -> EncodeSearch.run(base, adjusted, scorer: Bench.scorer(base)) end)

    %{
      body: body,
      meta: meta,
      prepare_us: prepare_us,
      feature_us: feature_us,
      search_us: search_us,
      starting_quality: starting_quality,
      encodes: meta.iterations,
      metric_calls: meta.iterations,
      tile_comparisons: comparisons(base, meta.iterations),
      input_rgb8_bytes: Image.width(base) * Image.height(base) * 3
    }
  end

  defp starting_quality(_base, policy, _model, :production),
    do: policy.quality_search.start_quality

  defp starting_quality(base, policy, model, :class_lookup) do
    {class, _features} = ContentClassifier.classify(base)
    model["class_lookup"][to_string(class)] |> clamp(policy)
  end

  defp starting_quality(base, policy, model, :ridge) do
    features = AutoqualityFeatures.extract(base)

    prediction =
      Enum.zip([features, model["mean"], model["scale"], model["coefficients"]])
      |> Enum.reduce(model["intercept"], fn {x, mean, scale, coefficient}, total ->
        total + (x - mean) / scale * coefficient
      end)

    clamp(prediction, policy)
  end

  defp clamp(value, policy),
    do:
      round(value)
      |> max(policy.quality_search.min_quality)
      |> min(policy.quality_search.max_quality)

  defp comparisons(base, probes) do
    case Bench.scorer(base) do
      :full ->
        probes

      :crop ->
        probes *
          length(
            ImagePipe.Output.Ssim2Metric.CropScore.sample_tiles(
              Image.width(base),
              Image.height(base)
            )
          )
    end
  end

  defp options(%{encoder_options: nil}), do: nil
  defp options(%{encoder_options: options}), do: Map.from_struct(options)
  defp load_models("collect", []), do: nil
  defp load_models("evaluate", [path]), do: path |> File.read!() |> JSON.decode!()
  defp format("jpeg"), do: :jpeg
  defp format("webp"), do: :webp
  defp format("avif"), do: :avif
end

AutoqualityPrediction.main(System.argv())
