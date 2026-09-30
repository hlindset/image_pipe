defmodule Mix.Tasks.Autoquality.Corpus.Capture do
  @shortdoc "Capture large full-page web screenshots for the >6 MP screen-content cohort"
  @moduledoc """
  Materializes the **screen-content half of the `mix autoquality.bench` >6 MP
  cohort** by capturing full-page screenshots of a committed list of public pages
  into the shared corpus cache, one subdir per source:

      ${XDG_CACHE_HOME:-~/.cache}/image_pipe/corpus/<sha>/<source>/<name>.png

  This is the deliberate complement to the off-the-shelf datasets: large
  *screen content* (text / UI / charts / tables) above the 6 MP crop crossover is
  where the crop-scoring residual tail lives (Part K), and no convenient permissive
  dataset ships it — UI-screenshot datasets are overwhelmingly viewport-sized
  (1920×1080 ≈ 2 MP), below the crossover. Capturing full-page at a wide viewport
  (`--width #{2560}`, no fixed height) puts every reasonably tall page over 6 MP,
  guaranteeing the spec (>6 MP, PNG, stable filenames) that real datasets don't.

  Two sources, captured as separate bench sources so the per-source residual
  separates the two screen-content tails:

    * `web_sc` — text / docs / UI pages (Wikipedia articles & tables, MDN, language
      docs, news, package docs).
    * `grafana_sc` — Grafana Play dashboards: dense charts, heatmaps, flame graphs,
      time series, candlesticks, BI tables. The hardest tracking content — fine lines,
      gradients, and small labels diverge most from the whole frame. A dashboard is a
      fixed-viewport SPA (~1.8 MP full-page), so these capture at 2× density and are
      vertically stitched in threes (~22 MP) to land deep enough in the crop regime to
      exercise the residual (see `@stitch`).

  ## Prerequisites

  [`shot-scraper`](https://shot-scraper.datasette.io/) (a headless Chromium wrapper)
  is a mise-managed tool (`pipx:shot-scraper` in `mise.toml`), so `mise install`
  provides it. Its browser is a one-time separate download:

      mise install                       # installs shot-scraper (+ python/uv)
      mise exec -- shot-scraper install  # one-time; downloads headless Chromium

  ## Reproducibility & expansion

  The committed `@sources` list of `{source, [{name, url}]}` is the recipe: `name` is
  a stable, hand-pinned filename stem, so the URL→file mapping never drifts. Capture
  is **incremental** — a page is captured only if its `<name>.png` is missing, so
  re-runs fill gaps and never re-fetch. That makes already-materialized pixels
  *sticky*: live-site drift (Grafana panels render live data) only affects newly
  added or explicitly refreshed URLs, not every run.

    * **Expand** — append `{stem, url}` entries and re-run; only the new ones capture.
    * **Refresh one** — delete its `<name>.png` (or pass `--force` to recapture all).

  Captured bytes live in the shared cache, never in a tracked repo dir — same posture
  as `mix autoquality.corpus`. The pages carry their origin sites' copyright; this is
  a local benchmark cache, not redistribution.

  Grafana panels load asynchronously, so the default wait is generous
  (`--wait #{4000}` ms); raise it for the heavy BI dashboards if panels capture blank.

  Full-page captures of long pages can be enormous (a long wiki article is ~100 MP)
  and pathologically tall, exceeding both ImagePipe's #{40} MP decode limit and the
  16383 px WebP/AVIF encoder dimension limit (which would drop those formats — the
  binding ssim2 formats — from the cohort). Each capture is **cropped from the top**
  in place to at most `--max-mp #{30}` MP and ≤ 16383 px tall, preserving native
  resolution and a realistic screenshot aspect rather than squashing the whole page.
  The cap pass is idempotent and runs over every cached file, so it also normalizes
  pages captured before the cap existed.

      mise exec -- mix autoquality.corpus.capture            # capture the missing pages
      mise exec -- mix autoquality.corpus.capture --force    # recapture everything
      mise exec -- mix autoquality.corpus.capture --width 2880 --wait 6000 --max-mp 25
      mise exec -- mix autoquality.corpus.capture --path     # just print the cache dir
  """
  use Mix.Task
  use Boundary, top_level?: true, check: [out: false]

  alias Mix.Tasks.Autoquality.Corpus
  alias Vix.Vips.Operation

  @default_width 2560
  @default_wait_ms 4000
  @default_max_megapixels 30
  @crossover_megapixels 6
  # WebP's hard max dimension (AVIF in this libvips build too); a taller capture would
  # silently drop from the WebP/AVIF cohort, leaving only jpeg.
  @max_dimension 16_383

  # Sources to vertically stitch into composites of N captures (source => N). A single
  # Grafana dashboard at 2× density is only ~7.4 MP — over the crossover, but crop
  # scoring covers ~57% of it, so its confirm-skipped residual is ~0 (uninformative).
  # Stacking 3 dashboards (~22 MP) drops coverage to ~19%, the regime where the
  # residual the bench measures actually appears. The raw single captures stay in a
  # hidden staging dir so capture stays incremental and the bench scans only composites.
  @stitch %{"grafana_sc" => 3}

  # Committed recipe: {source_dir, extra_shot_scraper_args, [{stable_stem, url}]}.
  # `stem` pins the filename so the URL→file mapping never drifts; append to expand,
  # never rename an existing stem (it would orphan the cached file). Curated toward
  # tall, dense pages — the residual-tail stressors. `grafana_sc` adds `--retina`: a
  # Grafana dashboard is a fixed-viewport SPA (full-page is only ~2560×720 ≈ 1.8 MP,
  # below the crossover), so 2× device density (≈7.4 MP) lifts it into the crop cohort
  # while preserving the real layout.
  @sources [
    {"web_sc", [],
     [
       {"wikipedia_ww2", "https://en.wikipedia.org/wiki/World_War_II"},
       {"wikipedia_gdp", "https://en.wikipedia.org/wiki/List_of_countries_by_GDP_(nominal)"},
       {"wikipedia_filesystems", "https://en.wikipedia.org/wiki/Comparison_of_file_systems"},
       {"wikipedia_unicode", "https://en.wikipedia.org/wiki/List_of_Unicode_characters"},
       {"mdn_css", "https://developer.mozilla.org/en-US/docs/Web/CSS"},
       {"mdn_js_array",
        "https://developer.mozilla.org/en-US/docs/Web/JavaScript/Reference/Global_Objects/Array"},
       {"mdn_http_headers", "https://developer.mozilla.org/en-US/docs/Web/HTTP/Headers"},
       {"pydocs_stdtypes", "https://docs.python.org/3/library/stdtypes.html"},
       {"pydocs_functions", "https://docs.python.org/3/library/functions.html"},
       {"postgres_string_funcs", "https://www.postgresql.org/docs/current/functions-string.html"},
       {"rust_book_ownership", "https://doc.rust-lang.org/book/ch04-01-what-is-ownership.html"},
       {"elixir_kernel", "https://hexdocs.pm/elixir/Kernel.html"},
       {"sqlite_lang", "https://www.sqlite.org/lang_select.html"},
       {"w3_css22_visudet", "https://www.w3.org/TR/CSS22/visudet.html"},
       {"hn", "https://news.ycombinator.com/"},
       {"hackernews_item", "https://news.ycombinator.com/item?id=1"},
       {"github_linux", "https://github.com/torvalds/linux"},
       {"stackoverflow_yield",
        "https://stackoverflow.com/questions/231767/what-does-the-yield-keyword-do-in-python"},
       {"arxiv_attention", "https://arxiv.org/abs/1706.03762"},
       {"caniuse_grid", "https://caniuse.com/grid"},
       {"stripe_pricing", "https://stripe.com/pricing"},
       {"tailwind_flex", "https://tailwindcss.com/docs/flex"},
       {"csstricks_flexbox", "https://css-tricks.com/snippets/css/a-guide-to-flexbox/"},
       {"kernel_org", "https://www.kernel.org/"},
       {"bbc_news", "https://www.bbc.com/news"},
       {"reddit_programming", "https://www.reddit.com/r/programming/"},
       {"mozilla_security", "https://infosec.mozilla.org/guidelines/web_security"}
     ]},
    {"grafana_sc", ["--retina"],
     [
       {"grafana_bar_gauges",
        "https://play.grafana.org/d/KIhkVD6Gk/bar-gauges?orgId=1&from=now-6h&to=now&timezone=browser"},
       {"grafana_flame_graphs",
        "https://play.grafana.org/d/cdl34qv4zzg8wa/flame-graphs?orgId=1&from=now-6h&to=now&timezone=browser"},
       {"grafana_heatmaps",
        "https://play.grafana.org/d/heatmap-calculate-log/grafana-heatmaps?orgId=1&from=now-6h&to=now&timezone=utc"},
       {"grafana_histogram",
        "https://play.grafana.org/d/histogram_tests/histogram-examples?orgId=1&from=now-6h&to=now&timezone=utc"},
       {"grafana_logs",
        "https://play.grafana.org/d/6NmftOxZz/logs-panel?orgId=1&from=now-6h&to=now&timezone=browser"},
       {"grafana_time_series",
        "https://play.grafana.org/d/000000016/time-series-graphs?orgId=1&from=now-1h&to=now&timezone=browser"},
       {"grafana_state_timeline",
        "https://play.grafana.org/d/qD-rVv6Mz/state-timeline-and-status-history?orgId=1&from=now-6h&to=now&timezone=browser"},
       {"grafana_stats",
        "https://play.grafana.org/d/Zb3f4veGk/stats?orgId=1&from=now-6h&to=now&timezone=utc"},
       {"grafana_candlestick",
        "https://play.grafana.org/d/candlestick/candlestick?orgId=1&from=2021-07-13T22:13:30.740Z&to=2021-07-13T22:46:18.921Z&timezone=utc"},
       {"grafana_weblogs",
        "https://play.grafana.org/d/play-elastic-web-logs/elasticsearch-83a-web-logs?orgId=1&from=1998-04-30T20:00:18.000Z&to=1998-04-30T20:10:33.000Z&timezone=utc"},
       {"grafana_gapminder",
        "https://play.grafana.org/d/play-bigquery-2/gapminder-ish-hans-rosling?orgId=1&from=now-20y&to=now&timezone=browser&var-country_name=Japan"},
       {"grafana_revops_sql",
        "https://play.grafana.org/d/territory-navigator-sql-only-version/grafanacon2026-revops3a-sql-only?orgId=1&from=2026-02-01T00:00:00.000Z&to=2026-04-30T23:59:59.000Z&timezone=utc"},
       {"grafana_revops_semantic",
        "https://play.grafana.org/d/territory-navigator/grafanacon2026-revops3a-semantic-layer?orgId=1&from=2026-02-01T00:00:00.000Z&to=2026-04-30T23:59:59.000Z&timezone=utc&var-Filters="},
       {"grafana_product_usecase",
        "https://play.grafana.org/d/chmktv7/grafanacon2026-product-use-case?orgId=1&from=now%2Fd-90d&to=now%2Fd-1d&timezone=utc&var-cohort=$__all"},
       {"grafana_citibike",
        "https://play.grafana.org/d/play-bigquery-1/citibike-example3a-overview?orgId=1&from=2017-04-01T00:00:00.000Z&to=2018-05-31T23:59:59.000Z&timezone=utc"}
     ]}
  ]

  @impl Mix.Task
  def run(args) do
    {opts, _, _} =
      OptionParser.parse(args,
        strict: [
          path: :boolean,
          force: :boolean,
          width: :integer,
          wait: :integer,
          max_mp: :integer
        ]
      )

    if opts[:path] do
      IO.puts(Corpus.cache_root())
    else
      Application.ensure_all_started(:image)
      bin = require_shot_scraper!()
      width = opts[:width] || @default_width
      wait = opts[:wait] || @default_wait_ms
      max_mp = opts[:max_mp] || @default_max_megapixels

      failures = Enum.flat_map(@sources, &capture_source(&1, bin, width, wait, opts[:force]))
      Enum.each(@sources, &stitch_source/1)
      inventory = Enum.flat_map(@sources, &cap_and_inventory(&1, max_mp))
      report(inventory, failures, max_mp)
    end
  end

  @doc "The committed `{source, [{name, url}]}` capture recipe, grouped by source."
  def sources, do: @sources

  @doc "The flattened committed `{name, url}` entries across all sources."
  def screenshot_urls, do: Enum.flat_map(@sources, fn {_source, _args, entries} -> entries end)

  @doc "Absolute dir the bench scans for a source (composites, for stitched sources)."
  def dest_dir(source), do: Path.join(Corpus.cache_root(), source)

  # Where raw single captures land. For stitched sources this is a hidden staging dir
  # (leading dot → skipped by the bench's `Path.wildcard("*")` source scan) so raw
  # captures stay incremental without polluting the cohort; others capture in place.
  defp capture_dir(source) do
    if Map.has_key?(@stitch, source),
      do: Path.join(Corpus.cache_root(), ".#{source}_raw"),
      else: dest_dir(source)
  end

  @doc "Stable path for a committed filename stem under `dir`."
  def target_path(dir, name), do: Path.join(dir, "#{name}.png")

  @doc """
  The entries from `urls` whose target file is missing under `dir` — the URLs a run
  would (re)capture. Already-materialized pages are skipped, so re-runs fill gaps.
  """
  def pending(urls, dir),
    do: Enum.reject(urls, fn {name, _url} -> File.exists?(target_path(dir, name)) end)

  @doc """
  How to bring a `w`×`h` image within budget by top-cropping: `:keep` if already
  within both the `max_megapixels` and the #{@max_dimension} px encoder limit, else
  `{:crop, keep_height}` — the (full-width) height to retain. Width is assumed within
  the encoder limit (capture widths are ≤ 2× `@default_width`).
  """
  def cap_crop(w, h, max_megapixels) do
    keep_h = Enum.min([h, div(max_megapixels * 1_000_000, w), @max_dimension])
    if keep_h >= h, do: :keep, else: {:crop, keep_h}
  end

  defp require_shot_scraper! do
    System.find_executable("shot-scraper") ||
      Mix.raise(
        "shot-scraper not found on PATH. It is a mise-managed tool:\n" <>
          "    mise install                       # installs shot-scraper\n" <>
          "    mise exec -- shot-scraper install  # one-time; downloads headless Chromium"
      )
  end

  defp capture_source({source, extra_args, entries}, bin, width, wait, force?) do
    dir = capture_dir(source)
    File.mkdir_p!(dir)
    todo = if force?, do: entries, else: pending(entries, dir)

    IO.puts(
      "[#{source}] capturing #{length(todo)}/#{length(entries)} pages " <>
        "(#{length(entries) - length(todo)} already cached) -> #{dir}"
    )

    todo
    |> Enum.map(&capture_one(bin, source, &1, dir, width, wait, extra_args))
    |> Enum.reject(&is_nil/1)
  end

  defp capture_one(bin, source, {name, url}, dir, width, wait, extra_args) do
    dest = target_path(dir, name)

    args =
      [url, "-o", dest, "--width", to_string(width), "--wait", to_string(wait), "--silent"] ++
        extra_args

    case System.cmd(bin, args, stderr_to_stdout: true) do
      {_out, 0} ->
        nil

      {out, status} ->
        File.rm(dest)
        {source, name, "exit #{status}: #{String.slice(out, 0, 200)}"}
    end
  end

  # Idempotent: downscale any cached file over the cap in place, and inventory the
  # final megapixels of every file in the source dir.
  defp cap_and_inventory({source, _extra_args, _entries}, max_mp) do
    dir = dest_dir(source)

    dir
    |> Path.join("*.png")
    |> Path.wildcard()
    |> Enum.sort()
    |> Enum.map(fn path -> {source, Path.basename(path, ".png"), cap_file(path, max_mp)} end)
  end

  # Rebuild a stitched source's composites from its (same-width) raw captures:
  # vertically concatenate every N into `stitch_NN.png`. Idempotent — old composites
  # are cleared and regenerated deterministically from the sorted raw set each run.
  defp stitch_source({source, _extra_args, _entries}) do
    case Map.get(@stitch, source) do
      nil ->
        :ok

      group_size ->
        dest = dest_dir(source)
        File.mkdir_p!(dest)
        dest |> Path.join("*.png") |> Path.wildcard() |> Enum.each(&File.rm!/1)

        capture_dir(source)
        |> Path.join("*.png")
        |> Path.wildcard()
        |> Enum.sort()
        |> Enum.chunk_every(group_size)
        |> Enum.with_index(1)
        |> Enum.each(fn {paths, i} ->
          out = Path.join(dest, "stitch_#{String.pad_leading(to_string(i), 2, "0")}.png")
          stitch_group(paths, out)
        end)
    end
  end

  defp stitch_group(paths, out) do
    images = Enum.map(paths, &Image.open!/1)
    {:ok, joined} = Operation.arrayjoin(images, across: 1)
    Image.write!(joined, out)
  end

  defp cap_file(path, max_mp) do
    img = Image.open!(path, access: :sequential)
    w = Image.width(img)
    h = Image.height(img)

    case cap_crop(w, h, max_mp) do
      :keep ->
        w * h / 1_000_000

      {:crop, keep_h} ->
        tmp = path <> ".tmp.png"
        img |> Image.crop!(0, 0, w, keep_h) |> Image.write!(tmp)
        File.rename!(tmp, path)
        w * keep_h / 1_000_000
    end
  end

  defp report(inventory, failures, max_mp) do
    {big, small} = Enum.split_with(inventory, fn {_s, _n, mp} -> mp > @crossover_megapixels end)

    for {source, name, mp} <- Enum.sort(inventory) do
      tag = if mp > @crossover_megapixels, do: "✓", else: "below"
      IO.puts("  #{String.pad_trailing("#{source}/#{name}", 36)} #{format_mp(mp)} MP  #{tag}")
    end

    for {source, name, msg} <- failures do
      IO.puts("  #{String.pad_trailing("#{source}/#{name}", 36)} FAILED — #{msg}")
    end

    IO.puts(
      "\n#{length(big)} in the crop cohort (>#{@crossover_megapixels} MP, capped at " <>
        "#{max_mp} MP), #{length(small)} below the crossover, #{length(failures)} failed."
    )
  end

  defp format_mp(mp), do: :erlang.float_to_binary(mp, decimals: 1) |> String.pad_leading(5)
end
