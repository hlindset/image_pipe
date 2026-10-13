# Compares ImagePipe.Cache.Cost's render-cost estimate with measured render
# time, to calibrate its weights on the machine it runs on.
#
#     mix run bench/cost_calibration.exs [--quick] [--iterations N] [--csv PATH]
#
# Renders a corpus through ImagePipe.run/4 with a cache attached. Every run
# gets its own cachebuster, so each one renders and writes, and the estimate
# is read from the `[:cache, :write]` stop event, as the cache stores it.
#
# Only ratios between estimates matter to the cache, so the report divides
# out the machine's speed: a class whose ratio is far from 1 has a weight to
# scale by that ratio. Spearman's rank correlation over all cases is the
# acceptance check. Prints Markdown.

defmodule CostCalibration do
  @images Path.expand("priv/static/images", File.cwd!())
  @acceptance 0.9

  def main(argv) do
    {opts, _rest} =
      OptionParser.parse!(argv, strict: [quick: :boolean, iterations: :integer, csv: :string])

    quick? = Keyword.get(opts, :quick, false)
    :io.setopts(:standard_io, encoding: :unicode)
    # As image_pipe_server does, so every run decodes its source.
    Vix.Vips.cache_set_max(0)
    iterations = Keyword.get(opts, :iterations, if(quick?, do: 1, else: 3))

    root = Path.join(System.tmp_dir!(), "cost_calibration_#{System.unique_integer([:positive])}")
    media = Path.join(root, "media")
    File.mkdir_p!(media)

    try do
      variants = make_variants(media, quick?)
      cache_root = Path.join(root, "cache")
      name = start_instance(cache_root, media)
      attach()

      rows =
        for {class, label, source, groups, output} <- cases(variants, quick?) do
          IO.write(:stderr, "#{class} #{label}\n")
          measure(name, cache_root, {class, label, source, groups, output}, iterations)
        end

      if path = opts[:csv], do: write_csv(path, rows)
      report(rows, iterations)
    after
      File.rm_rf!(root)
    end
  end

  # ── corpus ──────────────────────────────────────────────────────────────

  # Sources in every format the decode weights cover, made from one photo.
  # A format this libvips can't write is left out.
  @decode_formats [:jpeg, :png, :webp, :avif, :jpeg_xl, :tiff, :gif]

  defp make_variants(media, quick?) do
    copies =
      for name <-
            if(quick?,
              do: ~w(woman.jpg beach.jpg cooking.png),
              else: ~w(woman.jpg beach.jpg cooking.png spinning_baseline.jpg dog.jpg)
            ),
          into: %{} do
        File.cp!(Path.join(@images, name), Path.join(media, name))
        {name, name}
      end

    photo = Image.open!(Path.join(@images, "beach.jpg"))

    converted =
      for format <- @decode_formats -- [:jpeg], into: %{} do
        file = "beach.#{extension(format)}"

        case write(photo, Path.join(media, file), format) do
          :ok ->
            {"beach:#{format}", file}

          {:error, reason} ->
            IO.write(:stderr, "skipping #{format} source: #{inspect(reason)}\n")
            {"beach:#{format}", nil}
        end
      end

    Map.merge(copies, Map.reject(converted, fn {_key, file} -> is_nil(file) end))
  end

  defp extension(:jpeg_xl), do: "jxl"
  defp extension(format), do: Atom.to_string(format)

  # Vix directly, since `Image.write/3` doesn't pick these savers by suffix
  # or options. An uncompressed TIFF would exceed the source size limit.
  defp write(image, path, :jpeg_xl), do: Vix.Vips.Operation.jxlsave(image, path, effort: 3)

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

  # {class, label, source file, groups, output options}
  defp cases(variants, quick?) do
    decode =
      for format <- @decode_formats,
          key = if(format == :jpeg, do: "beach.jpg", else: "beach:#{format}"),
          file = variants[key],
          file != nil,
          do: {"decode #{format}", file, file, [[resize: [width: 400]]], [format: :jpeg]}

    sources =
      if quick?,
        do: ~w(woman.jpg beach.jpg cooking.png),
        else: ~w(woman.jpg beach.jpg cooking.png spinning_baseline.jpg dog.jpg)

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
          source <- sources,
          width <- widths,
          do:
            {"encode #{encoder}", "#{source} w#{width}", source, [[resize: [width: width]]],
             output}

    # Above 6 MP the search scores crops instead of the whole frame.
    searched =
      for format <- [:webp, :avif],
          {scorer, width} <- [{"full", 1200}, {"crop", 3200}],
          source <- ~w(beach.jpg spinning_baseline.jpg),
          not quick? or source == "beach.jpg",
          do:
            {"autoquality #{format} #{scorer}", "#{source} w#{width}", source,
             [[resize: [width: width]]], [format: format, autoquality: true] ++ effort(format)}

    terminals =
      for terminal <- [:info, :blurhash, :lqip_css],
          source <- ~w(woman.jpg beach.jpg),
          do: {"terminal #{terminal}", source, source, [], [terminal: terminal]}

    decode ++ encode ++ searched ++ terminals
  end

  # The server's default efforts, given explicitly so the features know them.
  defp effort(:webp), do: [webp_options: [effort: 4]]
  defp effort(:avif), do: [avif_options: [effort: 3]]

  # ── running ─────────────────────────────────────────────────────────────

  defp start_instance(cache_root, media) do
    name = CostCalibration.Instance

    {:ok, _pid} =
      Supervisor.start_link(
        [
          {ImagePipe,
           name: name,
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

    name
  end

  defp attach do
    :telemetry.attach(
      "cost-calibration",
      [:image_pipe, :cache, :write, :stop],
      &__MODULE__.handle_write/4,
      self()
    )
  end

  # Source records are written too, and carry no estimate.
  def handle_write(_event, _measurements, %{estimated_cost_us: estimate} = meta, bench),
    do: send(bench, {:estimate, estimate, meta.cache_key})

  def handle_write(_event, _measurements, _meta, _bench), do: :ok

  defp measure(name, cache_root, {class, label, source, groups, output}, iterations) do
    # The first run warms the decoders and encoders and isn't counted.
    {_us, estimate, key} = run(name, source, groups, output)

    times =
      for _iteration <- 1..iterations do
        {us, _estimate, _key} = run(name, source, groups, output)
        us
      end

    %{
      class: class,
      label: label,
      ms: median(times) / 1000,
      estimate_ms: estimate / 1000,
      features: features(cache_root, key, output)
    }
  end

  # The features the estimate was made from, from the debug info the cache
  # stored with the entry.
  defp features(cache_root, key, output) do
    case Keyword.get(output, :terminal) do
      nil ->
        {:ok, paths} = ImagePipe.Cache.FileSystem.paths_from_hash(key, root: cache_root)
        metadata = paths.meta_path |> File.read!() |> :erlang.binary_to_term()
        ImagePipe.Cache.Cost.features(metadata.debug, resolved(output))

      terminal ->
        %{{:terminal, terminal} => 1}
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

  defp run(name, source, groups, output) do
    builder =
      Enum.reduce(
        groups,
        ImagePipe.URL.new(ImagePipe.url_config(name), cachebuster: unique()),
        &ImagePipe.URL.group(&2, &1)
      )
      |> ImagePipe.URL.output(output)

    {us, {:ok, _result}} = :timer.tc(fn -> ImagePipe.run(name, builder, {:source, source}) end)

    # Waiting for the write keeps it out of the next run's time.
    receive do
      {:estimate, estimate, key} -> {us, estimate, key}
    after
      30_000 -> raise "no cache write for #{source} #{inspect(output)}"
    end
  end

  defp unique, do: Integer.to_string(System.unique_integer([:positive]))

  # ── report ──────────────────────────────────────────────────────────────

  defp report(rows, iterations) do
    rho = spearman(Enum.map(rows, & &1.ms), Enum.map(rows, & &1.estimate_ms))
    images = Enum.reject(rows, &String.starts_with?(&1.class, "terminal"))
    image_rho = spearman(Enum.map(images, & &1.ms), Enum.map(images, & &1.estimate_ms))
    scale = geomean(Enum.map(images, &(&1.ms / &1.estimate_ms)))

    IO.puts("""
    ### Render cost calibration

    #{length(rows)} cases, median of #{iterations} runs each.

    - Spearman rank correlation, all cases: **#{fmt(rho, 3)}** \
    (#{if rho >= @acceptance, do: "passes", else: "fails"} the #{@acceptance} bar)
    - Images only: #{fmt(image_rho, 3)}
    - Measured ÷ estimated, geometric mean over images: #{fmt(scale, 2)}× \
    (this machine against the reference core)

    #### By class

    Ratio is measured ÷ estimated, divided by the overall #{fmt(scale, 2)}×. \
    A class near 1 is calibrated. Otherwise its weight is off by about that factor.

    | Class | Cases | Ratio | Range |
    | --- | ---: | ---: | --- |\
    """)

    rows
    |> Enum.group_by(& &1.class)
    |> Enum.sort_by(fn {class, _rows} -> class end)
    |> Enum.each(fn {class, class_rows} ->
      ratios = Enum.map(class_rows, &(&1.ms / &1.estimate_ms / scale))

      IO.puts(
        "| #{class} | #{length(class_rows)} | #{fmt(geomean(ratios), 2)} | " <>
          "#{fmt(Enum.min(ratios), 2)}–#{fmt(Enum.max(ratios), 2)} |"
      )
    end)

    IO.puts("""

    <details><summary>Cases</summary>

    | Class | Case | Measured (ms) | Estimate (ms) | Ratio |
    | --- | --- | ---: | ---: | ---: |\
    """)

    for row <- rows do
      IO.puts(
        "| #{row.class} | #{row.label} | #{fmt(row.ms, 1)} | #{fmt(row.estimate_ms, 1)} | " <>
          "#{fmt(row.ms / row.estimate_ms / scale, 2)} |"
      )
    end

    IO.puts("\n</details>")
    report_fit(rows, scale)
  end

  # Fits every measured feature's weight by non-negative least squares on
  # relative error, then shows the weights in the reference core's units (the
  # current weights' scale), so they can replace the current ones.
  defp report_fit(rows, scale) do
    fitted = fit(rows)
    current = ImagePipe.Cache.Cost.weights()
    predict = fn weights, row -> Enum.sum(for {f, a} <- row.features, do: a * weights[f]) end

    fitted_rho =
      spearman(Enum.map(rows, & &1.ms), Enum.map(rows, &predict.(fitted, &1)))

    error = fn weights, factor ->
      rows
      |> Enum.map(&abs(predict.(weights, &1) * factor / (&1.ms * 1000) - 1))
      |> median()
    end

    IO.puts("""

    #### Fitted weights

    - Spearman with the fitted weights: **#{fmt(fitted_rho, 3)}**
    - Median relative error: #{fmt(error.(current, scale) * 100, 0)}% with the current weights, \
    #{fmt(error.(fitted, 1) * 100, 0)}% fitted

    | Feature | Current | Fitted |
    | --- | ---: | ---: |\
    """)

    for {feature, weight} <- Enum.sort(current) do
      value =
        if Map.has_key?(fitted, feature),
          do: fmt(fitted[feature] / scale, 1),
          else: "not measured"

      IO.puts("| `#{inspect(feature)}` | #{weight} | #{value} |")
    end
  end

  defp fit(rows) do
    current = ImagePipe.Cache.Cost.weights()
    features = rows |> Enum.flat_map(&Map.keys(&1.features)) |> Enum.uniq()
    targets = Enum.map(rows, &(&1.ms * 1000))
    columns = Enum.map(rows, & &1.features)
    start = Map.new(features, &{&1, current[&1] * 1.0})

    Enum.reduce(1..500, start, fn _sweep, weights ->
      Enum.reduce(features, weights, &update_weight(&1, &2, columns, targets))
    end)
  end

  # One coordinate-descent step: the best non-negative weight for `feature`
  # with the others fixed, each case weighted by 1 / measured².
  defp update_weight(feature, weights, columns, targets) do
    {num, den} =
      Enum.zip(columns, targets)
      |> Enum.reduce({0.0, 0.0}, fn {amounts, y}, {num, den} ->
        case amounts do
          %{^feature => a} ->
            rest = Enum.sum(for {f, amount} <- amounts, f != feature, do: amount * weights[f])
            {num + a * (y - rest) / (y * y), den + a * a / (y * y)}

          _without ->
            {num, den}
        end
      end)

    Map.put(weights, feature, max(num / den, 0.0))
  end

  defp write_csv(path, rows) do
    lines =
      for row <- rows,
          do: Enum.join([row.class, row.label, fmt(row.ms, 3), fmt(row.estimate_ms, 3)], ",")

    File.write!(path, Enum.join(["class,case,measured_ms,estimate_ms" | lines], "\n") <> "\n")
  end

  defp median(values) do
    sorted = Enum.sort(values)
    Enum.at(sorted, div(length(sorted), 2))
  end

  defp geomean(values),
    do: :math.exp(Enum.sum(Enum.map(values, &:math.log(max(&1, 1.0e-9)))) / length(values))

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

  defp pearson(xs, ys) do
    n = length(xs)
    mx = Enum.sum(xs) / n
    my = Enum.sum(ys) / n
    pairs = Enum.zip(xs, ys)
    cov = Enum.sum(for {x, y} <- pairs, do: (x - mx) * (y - my))
    sx = :math.sqrt(Enum.sum(for x <- xs, do: (x - mx) ** 2))
    sy = :math.sqrt(Enum.sum(for y <- ys, do: (y - my) ** 2))
    cov / (sx * sy)
  end

  defp fmt(number, decimals), do: :erlang.float_to_binary(number / 1, decimals: decimals)
end

CostCalibration.main(System.argv())
