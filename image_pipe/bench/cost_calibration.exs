# Compares ImagePipe.Cache.Cost's render-cost estimate with measured render
# time, to calibrate its weights on the machine it runs on.
#
#     mix run bench/cost_calibration.exs [--quick] [--iterations N] [--csv PATH] [--json PATH]
#     mix run bench/cost_calibration.exs --combine A.json B.json
#
# Renders a corpus through ImagePipe.run/4 with a cache attached. Every run
# gets its own cachebuster, so each one renders and writes, and the estimate
# is read from the `[:cache, :write]` stop event, as the cache stores it.
# Cases run in a shuffled order, one warm-up each, then in rounds that run
# every case once. Run it with VIPS_CONCURRENCY=1, as CI does: one libvips
# thread per render measures CPU time, which is what a render costs a loaded
# server, and doesn't depend on the machine's core count.
#
# Only ratios between estimates matter to the cache, so every comparison
# divides out one overall scale (this machine against the reference core).
# The acceptance check is on the weights in ImagePipe.Cache.Cost: RMS log
# error after that scale, and each class's ratio. The script exits non-zero
# when it fails. It also fits the weights by minimising the squared log
# error, with every weight non-negative, and reports the fit's
# leave-one-source-out error. Prints Markdown.
#
# `--json` writes the rows, their features and both weight sets at full
# precision. `--combine` takes two such files (from x86 and ARM runs, say)
# and prints the geometric mean of their fitted weights as a `@weights`
# literal for ImagePipe.Cache.Cost.

defmodule CostCalibration do
  alias ImagePipe.Cache.Cost

  @images Path.expand("priv/static/images", File.cwd!())
  @prefix [:cost_calibration]
  @seed {861, 2026, 10}
  @write_timeout 30_000
  # The model's own floor, its best in-sample fit, is about 0.33 on CI
  # runners, so the bar leaves room for run-to-run noise while still failing
  # weights that are off by a factor of two or three somewhere.
  @max_rms 0.40
  @max_class_ratio 1.6
  @widths [400, 1200]
  # The fit's smallest weight, and its largest step in log weight.
  @floor 1.0e-12
  @max_step 5.0
  @unmeasured "Watermarks (`{:op, :watermark}`) and detection (`:detect`) aren't in the corpus."

  def main(argv) do
    {opts, rest} =
      OptionParser.parse!(argv,
        strict: [
          quick: :boolean,
          iterations: :integer,
          csv: :string,
          json: :string,
          combine: :boolean
        ]
      )

    :io.setopts(:standard_io, encoding: :unicode)

    case {opts[:combine], rest} do
      {true, [a, b]} -> combine(a, b)
      {true, _rest} -> raise ArgumentError, "--combine takes two JSON files"
      {_calibrate, []} -> calibrate(opts)
      {_calibrate, rest} -> raise ArgumentError, "unexpected arguments: #{inspect(rest)}"
    end
  end

  defp calibrate(opts) do
    quick? = Keyword.get(opts, :quick, false)
    iterations = Keyword.get(opts, :iterations, if(quick?, do: 1, else: 3))
    if iterations < 1, do: raise(ArgumentError, "--iterations must be at least 1")

    # As image_pipe_server does, so every run decodes its source.
    Vix.Vips.cache_set_max(0)

    root = Path.join(System.tmp_dir!(), "cost_calibration_#{System.unique_integer([:positive])}")
    media = Path.join(root, "media")
    File.mkdir_p!(media)

    pass? =
      try do
        variants = make_variants(media, quick?)
        cache_root = Path.join(root, "cache")

        {rows, skipped} =
          with_instance(cache_root, media, fn name ->
            attach()
            measure_all(name, cache_root, cases(variants, quick?), iterations)
          end)

        if rows == [], do: raise("every case was skipped: #{inspect(skipped)}")
        if path = opts[:csv], do: write_csv(path, rows)
        result = report(rows, skipped, iterations)
        if path = opts[:json], do: write_json(path, rows, skipped, iterations, result)
        result.pass?
      after
        # A leftover temp directory isn't worth failing a finished run over.
        File.rm_rf(root)
      end

    if not pass?, do: System.halt(1)
  end

  # ── corpus ──────────────────────────────────────────────────────────────

  @decode_formats [:jpeg, :png, :webp, :avif, :jpeg_xl, :tiff, :gif]

  # The photos, and every decode format made from two of them: beach.jpg, and
  # cooking.png for an alpha channel (JPEG has none). A format this libvips
  # can't write is left out.
  defp make_variants(media, quick?) do
    for name <- sources(quick?) do
      File.cp!(Path.join(@images, name), Path.join(media, name))
    end

    photo = Image.open!(Path.join(@images, "beach.jpg"))
    alpha = Image.open!(Path.join(@images, "cooking.png"))

    converted =
      for {base, image, formats} <- [
            {"beach", photo, @decode_formats -- [:jpeg]},
            {"cooking", alpha, @decode_formats -- [:jpeg, :png]}
          ],
          format <- formats,
          into: %{} do
        file = "#{base}.#{extension(format)}"

        case write(image, Path.join(media, file), format) do
          :ok ->
            {{base, format}, file}

          {:error, reason} ->
            IO.write(:stderr, "skipping #{file}: #{inspect(reason)}\n")
            {{base, format}, nil}
        end
      end

    Map.merge(%{{"beach", :jpeg} => "beach.jpg", {"cooking", :png} => "cooking.png"}, converted)
  end

  defp sources(true), do: ~w(woman.jpg beach.jpg cooking.png)
  defp sources(false), do: ~w(woman.jpg beach.jpg cooking.png spinning_baseline.jpg dog.jpg)

  defp extension(:jpeg_xl), do: "jxl"
  defp extension(format), do: Atom.to_string(format)

  # Vix directly, since `Image.write/3` doesn't pick these savers by suffix
  # or options. An uncompressed TIFF would be needlessly large.
  defp write(image, path, :jpeg_xl) do
    Code.ensure_loaded(Vix.Vips.Operation)

    if function_exported?(Vix.Vips.Operation, :jxlsave, 3),
      do: apply(Vix.Vips.Operation, :jxlsave, [image, path, [effort: 3]]),
      else: {:error, :unsupported}
  end

  defp write(image, path, :tiff),
    do:
      Vix.Vips.Operation.tiffsave(image, path,
        compression: :VIPS_FOREIGN_TIFF_COMPRESSION_DEFLATE
      )

  defp write(image, path, :avif) do
    with {:ok, _image} <- Image.write(image, path, effort: 2), do: :ok
  end

  defp write(image, path, _format) do
    with {:ok, _image} <- Image.write(image, path), do: :ok
  end

  # Each case: its class, the feature the class is named for, the source
  # file, the groups and the output options.
  defp cases(variants, quick?) do
    decode =
      for {{base, format}, file} <- Enum.sort(variants),
          file != nil,
          width <- @widths do
        {class, feature} =
          if base == "cooking",
            do: {"decode #{format} alpha", :alpha},
            else: {"decode #{format}", {:decode, format}}

        new_case(class, feature, file, [[resize: [width: width]]], format: :jpeg)
      end

    operations =
      for {name, options} <- [
            trim: [trim: :auto],
            rotate: [rotate: 17],
            crop_guided: [crop: {{:pct, 60}, {:pct, 60}}, anchor: :smart],
            blur: [blur: 5],
            progressive_blur: [progressive_blur: [sigma: 10]],
            sharpen: [sharpen: 1.5],
            pixelate: [pixelate: 8]
          ],
          source <- ~w(beach.jpg cooking.png),
          width <- @widths,
          do:
            new_case(
              "op #{name}",
              {:op, name},
              source,
              [[resize: [width: width]] ++ options],
              format: :jpeg
            )

    widths = if quick?, do: [1600], else: [600, 1600]

    encoders =
      [
        {"jpeg", [format: :jpeg]},
        {"png", [format: :png]},
        {"png palette", [format: :png, png_options: [palette: true]]}
      ] ++
        for(
          effort <- [0, 2, 4, 6],
          do: {"webp e#{effort}", [format: :webp, webp_options: [effort: effort]]}
        ) ++
        for(
          effort <- [0, 2, 3, 4, 5, 6, 8],
          do: {"avif e#{effort}", [format: :avif, avif_options: [effort: effort]]}
        )

    encode =
      for {encoder, output} <- encoders,
          source <- sources(quick?),
          width <- widths,
          do:
            new_case(
              "encode #{encoder}",
              encoder_feature(output),
              source,
              [[resize: [width: width]]],
              output
            )

    # Above 6 MP the search scores crops instead of the whole frame.
    searched =
      for format <- [:webp, :avif],
          {scorer, width} <- [{"full", 1200}, {"crop", 3200}],
          source <- ~w(beach.jpg spinning_baseline.jpg),
          not quick? or source == "beach.jpg",
          do:
            new_case(
              "autoquality #{format} #{scorer}",
              :metric,
              source,
              [[resize: [width: width]]],
              [format: format, autoquality: true] ++ effort(format)
            )

    terminals =
      for terminal <- [:info, :blurhash, :lqip_css],
          source <- ~w(woman.jpg beach.jpg),
          do:
            new_case("terminal #{terminal}", {:terminal, terminal}, source, [],
              terminal: terminal
            )

    (decode ++ operations ++ encode ++ searched ++ terminals)
    |> Enum.with_index()
    |> Enum.map(fn {c, id} -> Map.put(c, :id, id) end)
  end

  defp new_case(class, feature, source, groups, output),
    do: %{class: class, feature: feature, source: source, groups: groups, output: output}

  defp encoder_feature(output) do
    case Map.new(output) do
      %{format: :png, png_options: [palette: true]} -> {:encode, :png_palette}
      %{format: :webp, webp_options: [effort: effort]} -> {:encode, :webp, effort}
      %{format: :avif, avif_options: [effort: effort]} -> {:encode, :avif, effort}
      %{format: format} -> {:encode, format}
    end
  end

  # The server's default efforts, given explicitly so the features know them.
  defp effort(:webp), do: [webp_options: [effort: 4]]
  defp effort(:avif), do: [avif_options: [effort: 3]]

  # ── running ─────────────────────────────────────────────────────────────

  # Stops the instance before the temp directory goes, so its writers and
  # sweep don't add files while it's removed.
  defp with_instance(cache_root, media, fun) do
    supervisor = start_instance(cache_root, media)

    try do
      fun.(CostCalibration.Instance)
    after
      Supervisor.stop(supervisor)
    end
  end

  defp start_instance(cache_root, media) do
    name = CostCalibration.Instance

    # The converted sources are larger than the default `max_body_bytes`.
    {:ok, supervisor} =
      Supervisor.start_link(
        [
          {ImagePipe,
           name: name,
           telemetry_prefix: @prefix,
           max_body_bytes: 200_000_000,
           sources: [
             media: [
               adapter: ImagePipe.Source.File,
               match: :path,
               options: [root: media, root_id: "media"]
             ]
           ],
           cache: [root: cache_root, max_size_bytes: 50_000_000_000]}
        ],
        strategy: :one_for_one
      )

    supervisor
  end

  defp attach do
    :telemetry.attach(
      "cost-calibration",
      @prefix ++ [:cache, :write, :stop],
      &__MODULE__.handle_write/4,
      self()
    )
  end

  # Source records are written too, and carry no estimate.
  def handle_write(_event, _measurements, %{estimated_cost_us: estimate} = meta, bench),
    do: send(bench, {:estimate, estimate, meta.cache_key})

  def handle_write(_event, _measurements, _meta, _bench), do: :ok

  # A case that fails a run is skipped from then on.
  defp measure_all(name, cache_root, cases, iterations) do
    :rand.seed(:exsss, @seed)
    cases = Enum.shuffle(cases)
    total = length(cases)

    {live, skipped} =
      cases
      |> Enum.with_index(1)
      |> Enum.reduce({[], []}, fn {c, n}, {live, skipped} ->
        progress("warm-up #{n}/#{total}", c)

        case warm_up(name, cache_root, c) do
          {:ok, row} -> {[row | live], skipped}
          {:error, reason} -> {live, [{c, reason} | skipped]}
        end
      end)

    live = Enum.reverse(live)

    {times, skipped} =
      Enum.reduce(
        1..iterations//1,
        {Map.new(live, &{&1.id, []}), skipped},
        &timed_round(name, live, "round #{&1}/#{iterations}", &2)
      )

    rows =
      for row <- live,
          us = times[row.id],
          us != nil,
          do: Map.put(row, :ms, median(us) / 1000)

    {rows, Enum.reverse(skipped)}
  end

  # Runs every live case once, in a fresh order.
  defp timed_round(name, live, stage, acc) do
    live
    |> Enum.shuffle()
    |> Enum.reduce(acc, fn row, {times, skipped} = acc ->
      if Map.has_key?(times, row.id) do
        progress(stage, row)

        case run(name, row) do
          {:ok, us, _estimate, _key} -> {Map.update!(times, row.id, &[us | &1]), skipped}
          {:error, reason} -> {Map.delete(times, row.id), [{row, reason} | skipped]}
        end
      else
        acc
      end
    end)
  end

  defp progress(stage, c), do: IO.write(:stderr, "#{stage} #{c.class} #{c.source}\n")

  # The first run warms the decoders and encoders and isn't counted. It
  # records the estimate and the features it was made from.
  defp warm_up(name, cache_root, c) do
    with {:ok, _us, estimate, key} <- run(name, c),
         {:ok, features, label} <- features(cache_root, key, c) do
      check_estimate!(c, features, estimate)
      {:ok, Map.merge(c, %{label: label, estimate_ms: estimate / 1000, features: features})}
    end
  end

  # The features the estimate was made from, from the debug info the cache
  # stored with the entry. The label gives the output's actual size.
  defp features(cache_root, key, %{output: output, source: source}) do
    case Keyword.get(output, :terminal) do
      nil ->
        with {:ok, paths} <- ImagePipe.Cache.FileSystem.paths_from_hash(key, root: cache_root),
             {:ok, binary} <- File.read(paths.meta_path) do
          debug = :erlang.binary_to_term(binary).debug
          label = "#{source} #{debug.output_width}×#{debug.output_height}"
          {:ok, Cost.features(debug, resolved(output)), label}
        else
          {:error, reason} -> {:error, {:missing_entry, reason}}
        end

      terminal ->
        {:ok, %{{:terminal, terminal} => 1}, source}
    end
  end

  # The fit is only meaningful if the features reproduce the estimate.
  defp check_estimate!(c, features, estimate) do
    computed = round(predict(Cost.weights(), features))

    if computed != estimate do
      raise "#{c.class} #{c.source}: the features give #{computed} but the cache " <>
              "estimated #{estimate}, so the bench is out of step with Cost.features/2"
    end
  end

  defp resolved(output) do
    format = Keyword.fetch!(output, :format)

    options =
      Keyword.get(output, :png_options) || Keyword.get(output, :webp_options) ||
        Keyword.get(output, :avif_options) || []

    %ImagePipe.Output.Resolved{
      format: format,
      quality: :default,
      response_headers: [],
      strip_metadata: true,
      keep_copyright: false,
      color_profile: :keep,
      encoder_options: Map.new(options)
    }
  end

  defp run(name, %{source: source, groups: groups, output: output}) do
    flush_estimates()

    builder =
      Enum.reduce(
        groups,
        ImagePipe.URL.new(ImagePipe.url_config(name), cachebuster: unique()),
        &ImagePipe.URL.group(&2, &1)
      )
      |> ImagePipe.URL.output(output)

    try do
      case :timer.tc(fn -> ImagePipe.run(name, builder, {:source, source}) end) do
        {us, {:ok, _result}} -> await_write(us)
        {_us, {:error, reason}} -> {:error, {:request, reason}}
      end
    catch
      kind, reason -> {:error, {:request, {kind, reason}}}
    end
  end

  # Waiting for the write keeps it out of the next run's time.
  defp await_write(us) do
    receive do
      {:estimate, estimate, key} -> {:ok, us, estimate, key}
    after
      @write_timeout -> {:error, :no_cache_write}
    end
  end

  # A write that arrived after its run timed out belongs to no run.
  defp flush_estimates do
    receive do
      {:estimate, _estimate, _key} -> flush_estimates()
    after
      0 -> :ok
    end
  end

  defp unique, do: Integer.to_string(System.unique_integer([:positive]))

  # ── report ──────────────────────────────────────────────────────────────

  defp report(rows, skipped, iterations) do
    current = Cost.weights()
    scale = best_scale(current, rows)
    current_rms = rms_log(current, rows)
    classes = class_stats(rows, current, scale)

    failing =
      Enum.filter(classes, fn class ->
        class.rows >= 2 and
          (class.ratio > @max_class_ratio or class.ratio < 1 / @max_class_ratio)
      end)

    pass? = current_rms <= @max_rms and failing == []

    worst =
      classes
      |> Enum.filter(&(&1.rows >= 2))
      |> Enum.max_by(&abs(:math.log(&1.ratio)), fn -> nil end)

    images = Enum.reject(rows, &String.starts_with?(&1.class, "terminal"))
    rho = spearman(Enum.map(rows, & &1.ms), Enum.map(rows, & &1.estimate_ms))
    image_rho = spearman(Enum.map(images, & &1.ms), Enum.map(images, & &1.estimate_ms))

    IO.puts("""
    ### Render cost calibration

    #{length(rows)} cases, median of #{iterations} timed #{if iterations == 1, do: "run", else: "runs"} \
    each after a warm-up, in a shuffled order (seed #{inspect(@seed)}). \
    #{length(skipped)} skipped.

    #### Acceptance (the weights in ImagePipe.Cache.Cost)

    **#{if pass?, do: "PASS", else: "FAIL"}**: RMS log error after scale \
    #{fmt(current_rms, 3)} (bar #{@max_rms}), worst class ratio \
    #{worst_text(worst)} (bar within #{@max_class_ratio}× for classes with 2 or more cases)\
    #{failing_text(failing)}

    - Scale, measured ÷ estimated (geometric mean): #{fmt(scale, 3)}× \
    (this machine against the reference core)
    - Spearman rank correlation (information only): #{fmt(rho, 3)} over all cases, \
    #{fmt(image_rho, 3)} over images

    #### By class

    Ratio is measured ÷ estimated, divided by the overall scale. Share is the \
    class's weight's median part of its cases' estimates: a ratio of r needs \
    that weight scaled by about 1 + (r − 1) ÷ share.

    | Class | Cases | Ratio | Range | Weight | Share | Spearman |
    | --- | ---: | ---: | --- | --- | ---: | ---: |\
    """)

    for class <- classes do
      IO.puts(
        "| #{class.class} | #{class.rows} | #{fmt(class.ratio, 2)} | " <>
          "#{fmt(class.min, 2)}–#{fmt(class.max, 2)} | `#{inspect(class.feature)}` | " <>
          "#{fmt(class.share * 100, 0)}% | #{fmt(class.spearman, 2)} |"
      )
    end

    IO.puts("""

    <details><summary>Cases</summary>

    | Class | Case | Measured (ms) | Estimate (ms) | Ratio |
    | --- | --- | ---: | ---: | ---: |\
    """)

    for row <- Enum.sort_by(rows, &{&1.class, &1.label}) do
      IO.puts(
        "| #{row.class} | #{row.label} | #{fmt(row.ms, 1)} | #{fmt(row.estimate_ms, 1)} | " <>
          "#{fmt(row.ms / row.estimate_ms / scale, 2)} |"
      )
    end

    IO.puts("\n</details>")

    fit = report_fit(rows, current, scale, current_rms)
    report_skipped(skipped)

    IO.puts("""

    **#{if pass?, do: "PASS", else: "FAIL"}**: RMS log error #{fmt(current_rms, 3)} \
    (≤ #{@max_rms}), worst class ratio #{worst_text(worst)} (within #{@max_class_ratio}×)\
    """)

    Map.merge(fit, %{
      pass?: pass?,
      scale: scale,
      current_rms: current_rms,
      worst_class: worst && %{class: worst.class, ratio: worst.ratio},
      spearman: rho
    })
  end

  defp worst_text(nil), do: "–"
  defp worst_text(class), do: "#{fmt(class.ratio, 2)} (#{class.class})"

  defp failing_text([]), do: "."

  defp failing_text(failing) do
    ". Out of range: " <>
      Enum.map_join(failing, ", ", &"#{&1.class} #{fmt(&1.ratio, 2)}") <> "."
  end

  defp class_stats(rows, weights, scale) do
    rows
    |> Enum.group_by(& &1.class)
    |> Enum.sort_by(fn {class, _rows} -> class end)
    |> Enum.map(fn {class, [first | _] = class_rows} ->
      ratios = Enum.map(class_rows, &(&1.ms * 1000 / predict(weights, &1.features) / scale))

      shares =
        Enum.map(class_rows, fn row ->
          Map.get(row.features, first.feature, 0) * Map.fetch!(weights, first.feature) /
            predict(weights, row.features)
        end)

      %{
        class: class,
        feature: first.feature,
        rows: length(class_rows),
        ratio: geomean(ratios),
        min: Enum.min(ratios),
        max: Enum.max(ratios),
        share: median(shares),
        spearman: spearman(Enum.map(class_rows, & &1.ms), Enum.map(class_rows, & &1.estimate_ms))
      }
    end)
  end

  # Fits every measured feature's weight, then shows the weights in the
  # reference core's units (the current weights' scale), so they can replace
  # the current ones.
  defp report_fit(rows, current, scale, current_rms) do
    start = Map.new(current, fn {feature, weight} -> {feature, weight * scale} end)
    fitted = fit(rows, start)
    reference = Map.new(fitted, fn {feature, weight} -> {feature, weight / scale} end)
    fitted_rms = rms_log(fitted, rows)
    loso = leave_one_source_out(rows, start, fitted)

    fitted_rho =
      spearman(Enum.map(rows, & &1.ms), Enum.map(rows, &predict(fitted, &1.features)))

    unmeasured =
      current
      |> Map.keys()
      |> Enum.reject(&(Map.has_key?(fitted, &1) or &1 in [:detect, {:op, :watermark}]))
      |> Enum.sort()

    IO.puts("""

    #### Fitted weights

    Fitted by minimising the squared log error, with every weight non-negative. \
    Errors are RMS of log(estimate ÷ measured), each weight set after its own \
    best overall scale.

    - RMS log error: #{fmt(current_rms, 3)} with the current weights, \
    #{fmt(fitted_rms, 3)} fitted (in sample)
    - Leave-one-source-out RMS log error of the fit: **#{fmt(loso, 3)}** \
    (each source's cases predicted by a fit without them)
    - Spearman with the fitted weights: #{fmt(fitted_rho, 3)}
    - Not measured: #{@unmeasured}#{unmeasured_text(unmeasured)}

    | Feature | Current | Fitted |
    | --- | ---: | ---: |\
    """)

    for {feature, weight} <- Enum.sort(current) do
      value =
        case reference[feature] do
          nil -> "not measured"
          w -> fitted_text(w)
        end

      IO.puts("| `#{inspect(feature)}` | #{weight} | #{value} |")
    end

    %{fitted: reference, fitted_rms: fitted_rms, loso_rms: loso, fitted_spearman: fitted_rho}
  end

  defp unmeasured_text([]), do: ""

  defp unmeasured_text(features),
    do: " Nor are " <> Enum.map_join(features, ", ", &"`#{inspect(&1)}`") <> "."

  defp report_skipped([]), do: :ok

  defp report_skipped(skipped) do
    IO.puts("""

    #### Skipped

    | Class | Source | Reason |
    | --- | --- | --- |\
    """)

    for {c, reason} <- skipped,
        do: IO.puts("| #{c.class} | #{c.source} | `#{reason_text(reason)}` |")
  end

  defp reason_text(reason),
    do: reason |> inspect(limit: 8, printable_limit: 120) |> String.replace("|", "\\|")

  # ── fit ─────────────────────────────────────────────────────────────────

  # Minimises Σ log(estimate / measured)² over non-negative weights with
  # Levenberg-Marquardt in log-weight space: a weight w = e^θ stays
  # positive, and one the data wants at 0 runs down to the floor. Features
  # absent from `rows` aren't in the result.
  defp fit(rows, start) do
    features = rows |> Enum.flat_map(&Map.keys(&1.features)) |> Enum.uniq() |> Enum.sort()
    index = features |> Enum.with_index() |> Map.new()

    design =
      for row <- rows do
        {for({feature, amount} <- row.features, do: {index[feature], amount * 1.0}),
         :math.log(row.ms * 1000)}
      end

    theta =
      features
      |> Enum.map(&:math.log(max(Map.fetch!(start, &1), @floor)))
      |> List.to_tuple()

    theta = levenberg_marquardt(design, theta, length(features))

    features
    |> Enum.with_index()
    |> Map.new(fn {feature, j} -> {feature, :math.exp(elem(theta, j))} end)
  end

  defp levenberg_marquardt(design, theta, n),
    do: lm_iterate(design, theta, n, cost(design, theta), 1.0e-3, 0, 0)

  # Stops when no step lowers the cost, or after 20 steps in a row that
  # barely lower it: a weight running down to 0 changes the cost little.
  defp lm_iterate(_design, theta, _n, _cost, _lambda, iteration, stalled)
       when iteration == 2000 or stalled == 20,
       do: theta

  defp lm_iterate(design, theta, n, cost, lambda, iteration, stalled) do
    {jtj, jtr} = normal_equations(design, theta, n)

    case lm_step(design, theta, cost, jtj, jtr, lambda) do
      {:ok, next, next_cost, lambda} ->
        stalled = if cost - next_cost <= 1.0e-12 * cost, do: stalled + 1, else: 0
        lm_iterate(design, next, n, next_cost, lambda / 3, iteration + 1, stalled)

      :stuck ->
        theta
    end
  end

  # Raises the damping until a step lowers the cost.
  defp lm_step(_design, _theta, _cost, _jtj, _jtr, lambda) when lambda > 1.0e12, do: :stuck

  defp lm_step(design, theta, cost, jtj, jtr, lambda) do
    damped =
      jtj
      |> Enum.with_index()
      |> Enum.map(fn {row, i} ->
        List.update_at(row, i, &(&1 + lambda * max(&1, 1.0e-6)))
      end)

    step = solve(damped, Enum.map(jtr, &(-&1)))

    next =
      theta
      |> Tuple.to_list()
      |> Enum.zip_with(step, fn t, d ->
        max(t + min(max(d, -@max_step), @max_step), :math.log(@floor))
      end)
      |> List.to_tuple()

    next_cost = cost(design, next)

    if next_cost < cost,
      do: {:ok, next, next_cost, lambda},
      else: lm_step(design, theta, cost, jtj, jtr, lambda * 4)
  end

  defp cost(design, theta) do
    Enum.reduce(design, 0.0, fn {row, log_y}, sum ->
      r = :math.log(row_prediction(row, theta)) - log_y
      sum + r * r
    end)
  end

  defp row_prediction(row, theta),
    do: Enum.reduce(row, 0.0, fn {j, a}, sum -> sum + a * :math.exp(elem(theta, j)) end)

  # JᵀJ and Jᵀr, where J is d log(estimate) / dθ: each feature's share of
  # the row's estimate.
  defp normal_equations(design, theta, n) do
    {jtj, jtr} =
      Enum.reduce(design, {%{}, %{}}, fn {row, log_y}, {jtj, jtr} ->
        p = row_prediction(row, theta)
        r = :math.log(p) - log_y
        shares = for {j, a} <- row, do: {j, a * :math.exp(elem(theta, j)) / p}

        jtr =
          Enum.reduce(shares, jtr, fn {j, s}, acc -> Map.update(acc, j, s * r, &(&1 + s * r)) end)

        jtj =
          for {i, si} <- shares, {j, sj} <- shares, reduce: jtj do
            acc -> Map.update(acc, {i, j}, si * sj, &(&1 + si * sj))
          end

        {jtj, jtr}
      end)

    matrix = for i <- 0..(n - 1)//1, do: for(j <- 0..(n - 1)//1, do: Map.get(jtj, {i, j}, 0.0))
    {matrix, for(j <- 0..(n - 1)//1, do: Map.get(jtr, j, 0.0))}
  end

  # Gaussian elimination with partial pivoting.
  defp solve(matrix, rhs) do
    matrix
    |> Enum.zip_with(rhs, fn row, b -> row ++ [b] end)
    |> eliminate([])
    |> Enum.reduce([], fn [pivot | rest], xs ->
      {coefficients, [b]} = Enum.split(rest, -1)
      s = b - Enum.sum(Enum.zip_with(coefficients, xs, &(&1 * &2)))
      [if(abs(pivot) < 1.0e-300, do: 0.0, else: s / pivot) | xs]
    end)
  end

  # Returns the pivot rows last first, for back substitution.
  defp eliminate([], upper), do: upper

  defp eliminate(rows, upper) do
    {[pivot | pivot_rest] = pivot_row, index} =
      rows |> Enum.with_index() |> Enum.max_by(fn {[head | _], _i} -> abs(head) end)

    reduced =
      for {[head | rest], i} <- Enum.with_index(rows), i != index do
        factor = if pivot == 0.0, do: 0.0, else: head / pivot
        Enum.zip_with(rest, pivot_rest, &(&1 - factor * &2))
      end

    eliminate(reduced, [pivot_row | upper])
  end

  # Each source's cases predicted by a fit to the others. A feature only
  # that source measures keeps its starting weight.
  defp leave_one_source_out(rows, start, fitted) do
    errors =
      rows
      |> Enum.group_by(& &1.source)
      |> Enum.flat_map(fn {source, held_out} ->
        training = Enum.reject(rows, &(&1.source == source))
        seen = training |> Enum.flat_map(&Map.keys(&1.features)) |> MapSet.new()
        warm = Map.new(start, fn {f, w} -> {f, if(f in seen, do: fitted[f], else: w)} end)
        log_errors(Map.merge(warm, fit(training, warm)), held_out)
      end)

    :math.sqrt(mean(Enum.map(errors, &(&1 * &1))))
  end

  # ── metrics ─────────────────────────────────────────────────────────────

  defp predict(weights, features),
    do: Enum.reduce(features, 0, fn {f, a}, sum -> sum + a * Map.fetch!(weights, f) end)

  defp log_errors(weights, rows),
    do: Enum.map(rows, &:math.log(predict(weights, &1.features) / (&1.ms * 1000)))

  # The factor that best maps the weights' estimates onto measured times.
  defp best_scale(weights, rows), do: :math.exp(-mean(log_errors(weights, rows)))

  # RMS log error after the weights' own best scale.
  defp rms_log(weights, rows) do
    errors = log_errors(weights, rows)
    m = mean(errors)
    :math.sqrt(mean(Enum.map(errors, &((&1 - m) * (&1 - m)))))
  end

  defp mean(values), do: Enum.sum(values) / length(values)

  defp median(values) do
    sorted = Enum.sort(values)
    n = length(sorted)

    if rem(n, 2) == 1,
      do: Enum.at(sorted, div(n, 2)),
      else: (Enum.at(sorted, div(n, 2) - 1) + Enum.at(sorted, div(n, 2))) / 2
  end

  defp geomean(values),
    do: :math.exp(Enum.sum(Enum.map(values, &:math.log(max(&1, 1.0e-9)))) / length(values))

  defp spearman(xs, _ys) when length(xs) < 2, do: nil
  defp spearman(xs, ys), do: pearson(ranks(xs), ranks(ys))

  # Tied values share their mean rank.
  defp ranks(values) do
    sorted = values |> Enum.with_index() |> Enum.sort_by(&elem(&1, 0))

    sorted
    |> Enum.chunk_by(&elem(&1, 0))
    |> Enum.reduce({%{}, 1}, fn group, {ranks, next} ->
      rank = next + (length(group) - 1) / 2

      {Enum.reduce(group, ranks, fn {_value, index}, acc -> Map.put(acc, index, rank) end),
       next + length(group)}
    end)
    |> elem(0)
    |> Enum.sort()
    |> Enum.map(&elem(&1, 1))
  end

  # nil when either side doesn't vary.
  defp pearson(xs, ys) do
    mx = mean(xs)
    my = mean(ys)
    cov = Enum.sum(Enum.zip_with(xs, ys, fn x, y -> (x - mx) * (y - my) end))
    sx = :math.sqrt(Enum.sum(for x <- xs, do: (x - mx) ** 2))
    sy = :math.sqrt(Enum.sum(for y <- ys, do: (y - my) ** 2))
    if sx == 0 or sy == 0, do: nil, else: cov / (sx * sy)
  end

  # ── output files ────────────────────────────────────────────────────────

  defp write_csv(path, rows) do
    lines =
      for row <- rows,
          do:
            Enum.join(
              [row.class, csv_field(row.label), fmt(row.ms, 3), fmt(row.estimate_ms, 3)],
              ","
            )

    File.write!(path, Enum.join(["class,case,measured_ms,estimate_ms" | lines], "\n") <> "\n")
  end

  defp csv_field(value), do: if(value =~ ~r/[",]/, do: inspect(value), else: value)

  defp write_json(path, rows, skipped, iterations, result) do
    data = %{
      iterations: iterations,
      seed: Tuple.to_list(@seed),
      scale: result.scale,
      metrics: %{
        pass: result.pass?,
        rms_log_current: result.current_rms,
        rms_log_fitted: result.fitted_rms,
        loso_rms_log_fitted: result.loso_rms,
        worst_class: result.worst_class,
        spearman_current: result.spearman,
        spearman_fitted: result.fitted_spearman
      },
      current_weights: weight_pairs(Cost.weights()),
      fitted_weights: weight_pairs(result.fitted),
      rows:
        for row <- rows do
          %{
            class: row.class,
            label: row.label,
            source: row.source,
            measured_ms: row.ms,
            estimate_ms: row.estimate_ms,
            features: weight_pairs(row.features)
          }
        end,
      skipped:
        Enum.map(skipped, fn {c, reason} ->
          %{class: c.class, source: c.source, reason: reason_text(reason)}
        end)
    }

    File.write!(path, JSON.encode!(data))
  end

  defp weight_pairs(map),
    do: for({feature, value} <- Enum.sort(map), do: [inspect(feature), value])

  # ── combine ─────────────────────────────────────────────────────────────

  # The geometric mean of two runs' fitted weights, in the reference units.
  # A weight one run didn't fit, or fit to about 0, takes the other run's.
  defp combine(path_a, path_b) do
    current = Cost.weights()
    features = Map.new(current, fn {feature, _weight} -> {inspect(feature), feature} end)
    a = read_fit(path_a, features)
    b = read_fit(path_b, features)

    combined =
      for {feature, weight} <- Enum.sort(current) do
        case {usable(a[feature]), usable(b[feature])} do
          {nil, nil} -> {feature, weight, kept(a[feature], b[feature])}
          {x, nil} -> {feature, x, {:only, "A"}}
          {nil, y} -> {feature, y, {:only, "B"}}
          {x, y} -> {feature, :math.sqrt(x * y), :both}
        end
      end

    IO.puts("""
    ### Combined weights

    Geometric mean of the fitted weights in `#{path_a}` (A) and `#{path_b}` (B), \
    in the reference core's units.

    | Feature | Current | A | B | Combined |
    | --- | ---: | ---: | ---: | ---: |\
    """)

    for {feature, value, _origin} <- combined do
      IO.puts(
        "| `#{inspect(feature)}` | #{current[feature]} | #{fitted_text(a[feature])} | " <>
          "#{fitted_text(b[feature])} | #{literal(value)} |"
      )
    end

    mention(
      "Fitted in only one file (missing or ≤ 1e-9 in the other), which gives the weight",
      for({feature, _value, {:only, file}} <- combined, do: "`#{inspect(feature)}` (#{file})")
    )

    mention(
      "Fitted to about 0 in every file that measured them, so they keep their current weight",
      for({feature, _value, :zero} <- combined, do: "`#{inspect(feature)}`")
    )

    mention(
      "Neither file measured these, so they keep their current weight",
      for({feature, _value, :unmeasured} <- combined, do: "`#{inspect(feature)}`")
    )

    last = length(combined) - 1

    lines =
      for {{feature, value, origin}, i} <- Enum.with_index(combined) do
        comma = if i == last, do: "", else: ","

        comment =
          case origin do
            :unmeasured -> " # not measured"
            :zero -> " # fitted to 0"
            _fitted -> ""
          end

        "  #{inspect(feature)} => #{literal(value)}#{comma}#{comment}"
      end

    IO.puts("""

    ```elixir
    @weights %{
    #{Enum.join(lines, "\n")}
    }
    ```\
    """)
  end

  defp kept(nil, nil), do: :unmeasured
  defp kept(_a, _b), do: :zero

  defp fitted_text(nil), do: "–"
  defp fitted_text(weight) when weight <= 1.0e-9, do: "≈ 0"
  defp fitted_text(weight), do: sig(weight, 3)

  defp mention(_text, []), do: :ok
  defp mention(text, items), do: IO.puts("\n#{text}: #{Enum.join(items, ", ")}.")

  defp read_fit(path, features) do
    data = path |> File.read!() |> JSON.decode!()

    for [key, weight] <- Map.fetch!(data, "fitted_weights"), into: %{} do
      case features do
        %{^key => feature} -> {feature, weight}
        _unknown -> raise "#{path}: #{key} isn't a weight in ImagePipe.Cache.Cost"
      end
    end
  end

  defp usable(weight) when is_number(weight) and weight > 1.0e-9, do: weight
  defp usable(_weight), do: nil

  # Two significant digits, written as an integer from 100 up.
  defp literal(value) do
    digits = floor(:math.log10(value))

    rounded =
      if digits >= 1,
        do: round(value / :math.pow(10, digits - 1)) * :math.pow(10, digits - 1),
        else: Float.round(value * 1.0, 1 - digits)

    cond do
      rounded >= 100 -> integer_literal(round(rounded))
      rounded == trunc(rounded) -> integer_literal(trunc(rounded))
      true -> Float.to_string(rounded)
    end
  end

  defp integer_literal(n) when n < 1000, do: Integer.to_string(n)

  defp integer_literal(n) do
    n
    |> Integer.to_string()
    |> String.reverse()
    |> String.to_charlist()
    |> Enum.chunk_every(3)
    |> Enum.join("_")
    |> String.reverse()
  end

  # ── formatting ──────────────────────────────────────────────────────────

  defp fmt(nil, _decimals), do: "–"
  defp fmt(number, decimals), do: :erlang.float_to_binary(number / 1, decimals: decimals)

  defp sig(value, _digits) when value == 0, do: "0"

  defp sig(value, digits) do
    decimals = max(digits - 1 - floor(:math.log10(abs(value))), 0)
    fmt(value, decimals)
  end
end

CostCalibration.main(System.argv())
