defmodule Mix.Tasks.Autoquality.Bench do
  @shortdoc "Benchmark the autoquality ssim2 encode-quality search — cost curve + accuracy (no Docker)"
  @moduledoc """
  Produces real performance + accuracy numbers for the autoquality / max_bytes
  encode-quality search (`ImagePipe.Output.EncodeSearch`, shipped in #351). The
  search runs at the output/encode boundary; for the `:ssim2` objective every
  iteration does a full-resolution **encode + decode + SSIMULACRA2 metric** on
  the result, and the metric dominates. This task quantifies that.

  Gated off the default `mix test` lane: it lives under `test/support/mix/tasks`
  (compiled only in `MIX_ENV=test`), is a Mix task (never a test the lane runs),
  is NIF-heavy (the `ssimulacra2` Rust NIF) and slow. Auto-selects `MIX_ENV=test`
  via `mix.exs` `preferred_envs`.

      mise exec -- mix autoquality.bench                 # parts A+B, default sizes
      mise exec -- mix autoquality.bench --part a        # cost curve only
      mise exec -- mix autoquality.bench --part b        # accuracy/behavior only
      mise exec -- mix autoquality.bench --part c        # proxy-seed method + accuracy
      mise exec -- mix autoquality.bench --part d        # cheap full-res metric narrowing
      mise exec -- mix autoquality.bench --part e --corpus DIR  # crop-based scoring, per source
      mise exec -- mix autoquality.bench --part e --corpus DIR --corpus-cap 24  # cap/source
      mise exec -- mix autoquality.bench --part f --corpus DIR  # saliency selection vs confirm
      mise exec -- mix autoquality.bench --part all      # A + B + C + D + E + F
      mise exec -- mix autoquality.bench --mps 1,4,9     # custom Part A megapixels
      mise exec -- mix autoquality.bench --proxy-factors 2,4 --proxy-mp 25  # Part C knobs
      mise exec -- mix autoquality.bench --part c --proxy-files a.jpg,b.jpg # large real photos
      mise exec -- mix autoquality.bench --csv           # also write CSVs under /tmp

  Fetch the corpus first with `mix autoquality.corpus`. Under `--corpus DIR`, each
  subdirectory is a per-source group, reported separately then macro-averaged so no
  single content type dominates.

  ## Part A — per-megapixel cost curve

  Runs the real `:ssim2` search (target #{88}, bracket [#{40},#{95}],
  max_iterations #{6}) on a deterministic high-frequency zone-plate at a range of
  output sizes (default ~1, 4, 9, 16, 25, 36 MP). The zone-plate is adversarial
  for JPEG, so the search uses its full iteration budget — worst-case cost. The
  encode / decode / metric phases are wrapped (injected `encode_fun`/`score_fun`
  over `Encoder.encode_to_buffer` + `Ssim2Metric`) and timed separately, so the
  table shows where the wall-clock goes as a function of pixel count. This is the
  data that sets a sane `autoquality_max_resolution` default.

  ## Part B — accuracy + behavior over real content

  Runs the production encode path (`Encoder.stream_output/3`, which finalizes the
  image exactly as a real request would) over the committed differential sources
  at their native sizes, for three configurations on each source:

    * `ssim2:#{88}:#{40}:#{95}` — records chosen quality, the achieved
      SSIMULACRA2 score vs the target (the search's own `final_score` telemetry,
      not an ad-hoc baseline), bytes vs a fixed `q90` baseline (savings %), and
      iteration count.
    * `size` and `max_bytes` to the same byte budget — these skip the
      decode+metric, so they are far cheaper; the table quantifies the gap.

  Goal: confirm `:ssim2` lands at/above its target, and surface typical quality /
  savings / iteration counts to validate (or adjust) the shipped defaults.

  ## Part C — downscaled-proxy-seed method + accuracy

  Explores the deferred optimization: instead of searching at full resolution,
  downscale by `1/k`, run the ssim2 search on the proxy to pick a quality, then
  encode the **full-res** image once at that quality. For each subject × factor it
  records the full-res search as ground truth (`q_full`), the proxy's pick
  (`q_proxy`), and — the real accuracy question — the **delivered** full-res
  SSIMULACRA2 score of the full-res encode at `q_proxy`, plus byte movement and the
  measured speedup. Subjects: the committed sRGB high-detail sources at native size,
  an adversarial zone-plate at `--proxy-mp` (default 16), and any images passed via
  `--proxy-files a.jpg,b.jpg` (which replace the committed set — use it to point at
  genuinely large real photos the repo can't carry).

  Finding: SSIMULACRA2 is resolution-dependent (a given quality scores lower on a
  downscaled image), so the search systematically OVER-picks quality on real
  content, and the over-pick grows with image size (≤2 MP: +1–2q; 16 MP: +18q,
  +56% bytes). That savings loss is the expensive direction to undo; a cheap
  confirm-and-adjust only rescues the rarer undershoot. So a naive downscale+margin
  proxy is not viable — a correct one needs its target calibrated across resolution.

  ## Part D — cheap full-res metric narrowing (#6)

  Tests whether a CHEAP full-res metric (PSNR variants — no XYB/multiscale SSIM
  cost) can narrow the search so SSIMULACRA2 runs ~once instead of ~4–6×. The final
  decision stays full-res SSIMULACRA2, so there is no resolution bias (Part C's
  trap). Viability hinges on whether the cheap metric's value AT the SSIMULACRA2
  boundary is stable across images: a tight spread ⇒ one global threshold narrows
  reliably; a wide spread ⇒ content-dependent, so a global threshold mis-locates the
  boundary. We measure that spread, then simulate the global-threshold strategy
  (cheap bisection to a quality, one SSIMULACRA2 confirm) against the full-res
  search as oracle. Subjects/flags as Part C.

  Finding: PSNR-class metrics are NOT viable here. The cheap value at the boundary
  spans 11–22 dB across content (high-frequency images clear the target at low PSNR;
  clean graphics need high PSNR), so a global threshold underpicks by up to ~28q or
  overpicks by >100% bytes. The metric is ~9–11× cheaper, but it does not track the
  perceptual boundary. Narrowing would need a cheaper *perceptual* metric
  (MS-SSIM/butteraugli — not in our stack) or per-image SSIMULACRA2 anchoring (which
  saves ~0 probes on the shipped narrow [70,80] bracket).

  ## Part E — crop-based scoring vs full-frame (#1)

  Scores SSIMULACRA2 on native-resolution tiles of the *actual full-res encode*
  instead of the whole frame. Unlike Part C's proxy this keeps native resolution,
  so per-pixel artifact statistics match — the only error is *which regions* you
  look at. Runs on a curated `--corpus DIR` (assemble one spanning smooth /
  heterogeneous / dark / busy / text content; the committed sources are too
  synthetic). Reports, binned by measured heterogeneity: (1) tracking — the offset
  `tile_aggregate − full_frame_score` at the boundary (tight ⇒ a calibrated global
  threshold reproduces the full-frame decision); (2) sub-sampling penalty — K tiles
  vs full coverage; (3) cost — K tiles is a fixed pixel budget (16 × 512² ≈ 4.2 MP
  scored, independent of source size).

  Finding: crop scoring is the first lever that TRACKS. The p10-tile offset holds
  within ±~1.5 pts (median ~0) across content — vs Part C's ±18q and Part D's
  hopeless spread — because native resolution is preserved. K=16-tile sub-sampling
  adds only ~+0.3 (worst +1.6) pts. Full tile coverage saves nothing, but the fixed
  K-tile budget beats full-frame above a ~4 MP crossover: ~1.6× at 10.7 MP, ~2.3× at
  16 MP, and (budget being size-independent) growing with size. So crop scoring is a
  viable speedup for large images — use full-frame below the crossover.

  ## Part F — saliency tile selection vs the full-frame confirm (#359)

  Crop scoring (Part E) flattens the OBJECTIVE search to a fixed ~4.2 MP budget, but
  in crop mode `EncodeSearch.run` still runs a FULL-FRAME confirm (+ up to 2 bump
  passes) on the winner — an O(pixels) cost that grows with image size and is exactly
  what crop scoring was built to avoid. Part F asks the high-value question: can a
  smarter tile *selection* make the crop estimate accurate enough to RETIRE that
  confirm, so the whole search becomes size-independent?

  Method (no production change): per image, per selector × K, run the real pure
  search core (`EncodeSearch.search/3`) with a selector-parameterized crop
  `score_fun` and NO `confirm_fun` — that IS the confirm-skipped path — then take ONE
  full-frame score at the winner as ground truth. Baseline is the production-today
  crop path (even selection + full-frame confirm at K=#{16}). Selectors
  (`ImagePipe.Test.Autoquality.TileSelection`): `even` (shipped baseline),
  `source_detail` (edge energy of the source — candidate-independent),
  `mixed` (half coverage + half source-detail), and `diff_aware` (adds candidate-
  dependent |source−candidate| + its high-pass energy — an upper bound, not
  production-plausible since it is per-probe O(pixels) work). K ∈ #{inspect([8, 12, 16, 24])}.

  Each variant reports the delivered target error if the confirm is skipped (median +
  the global worst-undershoot tail, the safety number), the count of regressions
  (baseline+confirm hit but skip-confirm ships below target), and the residual
  decomposed into the two parts that decide whether selection can help at all:

    * sampling error   = selected_p10 − full_coverage_p10  (a selector CAN shrink)
    * systematic error = (full_coverage_p10 − offset) − full_frame_score
                         (the p10→full mapping; selection CANNOT fix it — only
                          per-content offset recalibration would)

  If |systematic| dominates |sampling|, no selector can retire the confirm and the
  lever is offset recalibration, not tile choice. Cost context prints the full-frame
  confirm time being saved (the prize) and the candidate-dependent diff-map overhead
  per probe (the price `diff_aware` pays).

  A second analysis asks whether a cheaper *aggregation* could stand in for the
  full-frame confirm: per image at the delivered quality it reports how tightly each
  aggregate (`p10`/`p25`/`median`/`mean`, over the K=16 sample and full coverage)
  predicts the full-frame score — `offset` (a global calibration constant) and `worst±`
  (the irreducible post-calibration tail a confirm must absorb). A crop confirm is
  viable only if some aggregate's `worst±` fits the best-effort band; if every aggregate
  shares the same large tail, the residual is systematic and per-content calibration —
  not aggregation — is the lever.

  Needs the corpus (`mix autoquality.corpus`, plus large photos for the size-dependent
  regime where the confirm cost is largest); the committed fallback sources are ≤ K
  tiles, so selection is a no-op on them.
  """
  use Mix.Task
  use Boundary, top_level?: true, check: [out: false]

  alias ImagePipe.Output.Encoder
  alias ImagePipe.Output.EncodeSearch
  alias ImagePipe.Output.Resolved
  alias ImagePipe.Output.ResolvedQualitySearch, as: RQS
  alias ImagePipe.Output.Ssim2Metric
  alias ImagePipe.Test.Autoquality.TileSelection
  alias ImagePipe.Test.ImgproxyDifferential.SourceInventory
  alias Vix.Vips.Image, as: VixImage
  alias Vix.Vips.Operation

  @sources_dir "test/support/image_pipe/test/imgproxy_differential/sources"
  @prefix [:autoquality_bench]

  # Shipped defaults under test (see ImagePipe.Output.EncodeSearch + the imgproxy
  # autoquality parser).
  @target 88
  @min_q 40
  @max_q 95
  @max_iter 6

  @default_mps [1, 4, 9, 16, 25, 36]
  @baseline_quality 90

  # Part C subjects: the committed sRGB high-detail sources (the ones with real
  # savings in Part B), where the downscale-proxy quality-transfer relationship is
  # meaningful. CMYK / embedded-ICC / 16-bit / alpha sources are excluded to keep
  # the light finalize (copy_memory + sRGB + flatten) a no-op-equivalent.
  @part_c_sources [
    "high_freq.jpg",
    "marker.png",
    "border.png",
    "border_asym.png",
    "placement.png"
  ]

  @default_factors [2, 3, 4]

  @impl Mix.Task
  def run(args) do
    {opts, _, _} =
      OptionParser.parse(args,
        strict: [
          part: :string,
          mps: :string,
          csv: :boolean,
          format: :string,
          proxy_factors: :string,
          proxy_mp: :integer,
          proxy_files: :string,
          corpus: :string,
          corpus_cap: :integer
        ]
      )

    part = Keyword.get(opts, :part, "both")
    csv? = Keyword.get(opts, :csv, false)
    format = opts |> Keyword.get(:format, "jpeg") |> parse_format()
    mps = parse_mps(Keyword.get(opts, :mps))
    factors = parse_factors(Keyword.get(opts, :proxy_factors))
    proxy_files = parse_files(Keyword.get(opts, :proxy_files))
    proxy_mp = Keyword.get(opts, :proxy_mp, 16)

    {:ok, _} = Application.ensure_all_started(:image_pipe)
    warmup(format)

    run_ctx = %{
      part: part,
      mps: mps,
      factors: factors,
      proxy_mp: proxy_mp,
      proxy_files: proxy_files,
      corpus_dir: Keyword.get(opts, :corpus),
      corpus_cap: Keyword.get(opts, :corpus_cap, 24),
      format: format
    }

    {a_rows, b_rows, c_rows, e_rows, f_rows} = run_selected_parts(run_ctx)
    if csv?, do: write_csvs(a_rows, b_rows, c_rows, e_rows, f_rows)
    print_findings(a_rows, b_rows, c_rows, e_rows, f_rows, format)
  end

  defp run_selected_parts(%{part: part, format: format} = ctx) do
    a = if part in ["a", "both", "all"], do: run_part_a(ctx.mps, format)
    b = if part in ["b", "both", "all"], do: run_part_b(format)

    c =
      if part in ["c", "all"], do: run_part_c(ctx.factors, ctx.proxy_mp, ctx.proxy_files, format)

    if part in ["d", "all"], do: run_part_d(ctx.proxy_files, ctx.proxy_mp, format)

    e =
      if part in ["e", "all"],
        do: run_part_e(ctx.corpus_dir, ctx.proxy_files, ctx.corpus_cap, ctx.proxy_mp, format)

    f =
      if part in ["f", "all"],
        do: run_part_f(ctx.corpus_dir, ctx.proxy_files, ctx.corpus_cap, ctx.proxy_mp, format)

    {a, b, c, e, f}
  end

  defp write_csvs(a_rows, b_rows, c_rows, e_rows, f_rows) do
    if a_rows, do: write_part_a_csv(a_rows)
    if b_rows, do: write_part_b_csv(b_rows)
    if c_rows, do: write_part_c_csv(c_rows)
    if e_rows, do: write_part_e_csv(e_rows)

    if f_rows do
      write_part_f_csv(f_rows.variants)
      write_part_f_agg_csv(f_rows.agg)
    end
  end

  # Touch every NIF/libvips path once so first-call JIT + library init does not
  # land inside a timed measurement (the SSIMULACRA2 NIF's first call is ~10x a
  # warm call). Discarded.
  defp warmup(format) do
    image = zone_plate(256, 256)
    {:ok, ref} = Ssim2Metric.reference(image)
    {:ok, bin} = Encoder.encode_to_buffer(image, ssim2_resolved(format), 80)
    {:ok, candidate} = Image.from_binary(bin)
    {:ok, _} = Ssim2Metric.score(ref, candidate)
    :ok
  end

  # --- Part A: cost curve ---------------------------------------------------

  defp run_part_a(mps, format) do
    IO.puts("\n== Part A — ssim2 search cost vs. megapixels ==")
    IO.puts("objective ssim2  target #{@target}  bracket [#{@min_q},#{@max_q}]  ")
    IO.puts("max_iterations #{@max_iter}  format #{format}  source: deterministic zone-plate\n")

    header =
      pad(["MP", 6]) <>
        pad(["dims", 12]) <>
        pad(["iters", 6]) <>
        pad(["total_ms", 10]) <>
        pad(["ref_ms", 9]) <>
        pad(["encode_ms", 11]) <>
        pad(["decode_ms", 11]) <>
        pad(["metric_ms", 11]) <>
        pad(["/iter_ms", 10]) <>
        pad(["metric%", 8])

    IO.puts(header)
    IO.puts(String.duplicate("-", String.length(header)))

    resolved = ssim2_resolved(format)

    rows =
      Enum.map(mps, fn mp ->
        {w, h} = square_dims(mp)
        image = zone_plate(w, h)

        # One-time reference build (part of the real per-request ssim2 cost).
        {ref_us, {:ok, ref}} = timed(fn -> Ssim2Metric.reference(image) end)

        acc = :atomics.new(3, signed: true)
        encode_fun = instrumented_encode(image, resolved, acc)
        score_fun = instrumented_score(ref, acc)

        {search_us, {:ok, _binary, meta}} =
          timed(fn ->
            EncodeSearch.search(resolved.quality_search, nil,
              encode_fun: encode_fun,
              score_fun: score_fun,
              base_quality: @max_q,
              max_iterations: @max_iter,
              telemetry_opts: [telemetry_prefix: @prefix]
            )
          end)

        encode_us = :atomics.get(acc, 1)
        decode_us = :atomics.get(acc, 2)
        metric_us = :atomics.get(acc, 3)
        total_us = ref_us + search_us
        iters = meta.iterations
        per_iter_us = if iters > 0, do: div(encode_us + decode_us + metric_us, iters), else: 0
        metric_pct = pct(metric_us, total_us)

        row = %{
          mp: mp,
          w: w,
          h: h,
          iters: iters,
          total_us: total_us,
          ref_us: ref_us,
          encode_us: encode_us,
          decode_us: decode_us,
          metric_us: metric_us,
          per_iter_us: per_iter_us,
          metric_pct: metric_pct,
          score: meta.score,
          quality: meta.quality
        }

        IO.puts(
          pad([mp, 6]) <>
            pad(["#{w}x#{h}", 12]) <>
            pad([iters, 6]) <>
            pad([ms(total_us), 10]) <>
            pad([ms(ref_us), 9]) <>
            pad([ms(encode_us), 11]) <>
            pad([ms(decode_us), 11]) <>
            pad([ms(metric_us), 11]) <>
            pad([ms(per_iter_us), 10]) <>
            pad(["#{metric_pct}%", 8])
        )

        row
      end)

    rows
  end

  defp instrumented_encode(image, resolved, acc) do
    fn quality ->
      {us, result} = timed(fn -> Encoder.encode_to_buffer(image, resolved, quality) end)
      :atomics.add(acc, 1, us)
      result
    end
  end

  # Mirrors EncodeSearch.run/3's real score closure (decode the candidate buffer,
  # then SSIMULACRA2 against the pre-encode reference) but splits decode vs metric
  # timing. Failures throw the same tagged tuple run/3 catches.
  defp instrumented_score(ref, acc) do
    fn bytes ->
      {dec_us, decoded} = timed(fn -> Image.from_binary(bytes) end)
      :atomics.add(acc, 2, dec_us)
      candidate = unwrap(decoded)

      {met_us, scored} = timed(fn -> Ssim2Metric.score(ref, candidate) end)
      :atomics.add(acc, 3, met_us)
      unwrap(scored)
    end
  end

  defp unwrap({:ok, value}), do: value
  defp unwrap({:error, reason}), do: throw({:image_pipe_score_error, reason})

  # --- Part B: accuracy + behavior ------------------------------------------

  defp run_part_b(format) do
    IO.puts("\n== Part B — accuracy + behavior over real sources (native sizes) ==")
    IO.puts("ssim2 target #{@target} [#{@min_q},#{@max_q}]  baseline q#{@baseline_quality}  ")

    IO.puts(
      "format #{format}  size/max_bytes budget = round(q#{@baseline_quality} bytes * 0.6)\n"
    )

    attach_telemetry()

    header =
      pad(["source", 22]) <>
        pad(["dims", 12]) <>
        pad(["MP", 6]) <>
        pad(["q", 4]) <>
        pad(["score", 8]) <>
        pad(["hit?", 6]) <>
        pad(["bytes", 9]) <>
        pad(["q#{@baseline_quality}", 9]) <>
        pad(["save%", 7]) <>
        pad(["iters", 6]) <>
        pad(["ssim2ms", 9]) <>
        pad(["sizems", 8]) <>
        pad(["mbms", 8])

    IO.puts(header)
    IO.puts(String.duplicate("-", String.length(header)))

    rows =
      SourceInventory.entries()
      |> Enum.sort_by(&(&1.width * &1.height))
      |> Enum.map(fn entry -> bench_source(entry, format) end)
      |> Enum.reject(&is_nil/1)

    detach_telemetry()
    rows
  end

  defp bench_source(entry, format) do
    path = Path.join(@sources_dir, entry.file)

    case Image.open(path, access: :random) do
      {:ok, image} ->
        mp = Float.round(Image.width(image) * Image.height(image) / 1_000_000, 2)

        # Fixed-quality baseline (no search) — finalized identically.
        {_us, baseline_bytes} = encode_once(image, plain_resolved(format, @baseline_quality))
        budget = round(baseline_bytes * 0.6)

        ssim2 = run_config(image, ssim2_resolved(format))
        size = run_config(image, size_resolved(format, budget))
        mb = run_config(image, max_bytes_resolved(format, budget))

        savings = pct(baseline_bytes - ssim2.bytes, baseline_bytes)
        hit? = ssim2.score && ssim2.score >= @target

        IO.puts(
          pad([entry.file, 22]) <>
            pad(["#{Image.width(image)}x#{Image.height(image)}", 12]) <>
            pad([mp, 6]) <>
            pad([ssim2.quality, 4]) <>
            pad([fmt_score(ssim2.score), 8]) <>
            pad([if(hit?, do: "yes", else: "NO"), 6]) <>
            pad([ssim2.bytes, 9]) <>
            pad([baseline_bytes, 9]) <>
            pad(["#{savings}%", 7]) <>
            pad([ssim2.iters, 6]) <>
            pad([ms(ssim2.us), 9]) <>
            pad([ms(size.us), 8]) <>
            pad([ms(mb.us), 8])
        )

        %{
          source: entry.file,
          w: Image.width(image),
          h: Image.height(image),
          mp: mp,
          quality: ssim2.quality,
          score: ssim2.score,
          hit?: hit?,
          bytes: ssim2.bytes,
          baseline_bytes: baseline_bytes,
          savings: savings,
          iters: ssim2.iters,
          ssim2_us: ssim2.us,
          size_us: size.us,
          size_iters: size.iters,
          mb_us: mb.us,
          mb_iters: mb.iters
        }

      {:error, reason} ->
        IO.puts(pad([entry.file, 22]) <> "skipped (open failed: #{inspect(reason)})")
        nil
    end
  end

  # Run one production search config and read the verdict from the search's own
  # [:encode, :search] :stop telemetry (chosen_quality/bytes/iterations/final_score).
  defp run_config(image, resolved) do
    {us, _result} =
      timed(fn ->
        {:ok, stream, _mime} =
          Encoder.stream_output(image, resolved, telemetry_prefix: @prefix)

        Enum.each(stream, fn _ -> :ok end)
      end)

    meta = receive_search_meta()

    %{
      us: us,
      quality: meta.chosen_quality,
      bytes: meta.chosen_bytes,
      iters: meta.iterations,
      score: Map.get(meta, :final_score)
    }
  end

  defp encode_once(image, resolved) do
    timed(fn ->
      {:ok, stream, _mime} = Encoder.stream_output(image, resolved, [])
      Enum.reduce(stream, 0, fn chunk, acc -> acc + byte_size(chunk) end)
    end)
  end

  # --- Part C: downscaled-proxy-seed method + accuracy ----------------------

  # The proxy method: downscale the finalized image by 1/k, run the ssim2 search
  # on that proxy to pick a quality, then encode the FULL-res image once at that
  # quality. We measure whether the delivered full-res image still hits the target
  # (the real accuracy question) against the current full-res search as ground
  # truth, plus the measured speedup.
  defp run_part_c(factors, synth_mp, proxy_files, format) do
    IO.puts("\n== Part C — downscaled-proxy-seed method + accuracy ==")
    IO.puts("ssim2 target #{@target} [#{@min_q},#{@max_q}]  factors #{inspect(factors)}  ")

    IO.puts(
      "format #{format}  truth = full-res search  delivered = full-res encode at proxy's q\n"
    )

    header =
      pad(["source", 18]) <>
        pad(["MP", 6]) <>
        pad(["k", 3]) <>
        pad(["pMP", 6]) <>
        pad(["qFull", 6]) <>
        pad(["qProxy", 7]) <>
        pad(["dq", 5]) <>
        pad(["fullSc", 8]) <>
        pad(["delivSc", 9]) <>
        pad(["d-#{@target}", 7]) <>
        pad(["hit?", 6]) <>
        pad(["bFull", 9]) <>
        pad(["bProxy", 9]) <>
        pad(["speedup", 8])

    IO.puts(header)
    IO.puts(String.duplicate("-", String.length(header)))

    resolved = ssim2_resolved(format)
    subjects = load_subjects(proxy_files, synth_mp)

    subjects
    |> Enum.flat_map(fn {label, base} ->
      bench_proxy_subject(label, base, factors, resolved)
    end)
  end

  defp bench_proxy_subject(label, base, factors, resolved) do
    mp = Float.round(Image.width(base) * Image.height(base) / 1_000_000, 2)
    {:ok, full_ref} = Ssim2Metric.reference(base)

    {full_us, {:ok, _full_bin, full_meta}} =
      timed(fn -> EncodeSearch.run(base, resolved, telemetry_opts: []) end)

    Enum.map(factors, fn k ->
      {ds_us, proxy} = timed(fn -> downscale(base, k) end)

      {proxy_us, {:ok, _pbin, proxy_meta}} =
        timed(fn -> EncodeSearch.run(proxy, resolved, telemetry_opts: []) end)

      {conf_us, {:ok, conf_bin}} =
        timed(fn -> Encoder.encode_to_buffer(base, resolved, proxy_meta.quality) end)

      {:ok, candidate} = Image.from_binary(conf_bin)
      {:ok, delivered} = Ssim2Metric.score(full_ref, candidate)

      pmp = Float.round(Image.width(proxy) * Image.height(proxy) / 1_000_000, 2)
      dq = proxy_meta.quality - full_meta.quality
      delta_target = delivered - @target
      hit? = delivered >= @target
      proxy_total_us = ds_us + proxy_us + conf_us
      speedup = ratio(full_us, proxy_total_us)

      IO.puts(
        pad([label, 18]) <>
          pad([mp, 6]) <>
          pad([k, 3]) <>
          pad([pmp, 6]) <>
          pad([full_meta.quality, 6]) <>
          pad([proxy_meta.quality, 7]) <>
          pad([dq, 5]) <>
          pad([fmt_score(full_meta.score), 8]) <>
          pad([fmt_score(delivered), 9]) <>
          pad([Float.round(delta_target, 2), 7]) <>
          pad([if(hit?, do: "yes", else: "NO"), 6]) <>
          pad([full_meta.bytes, 9]) <>
          pad([byte_size(conf_bin), 9]) <>
          pad(["#{speedup}x", 8])
      )

      %{
        source: label,
        mp: mp,
        k: k,
        proxy_mp: pmp,
        q_full: full_meta.quality,
        q_proxy: proxy_meta.quality,
        dq: dq,
        full_score: full_meta.score,
        delivered_score: delivered,
        delta_target: delta_target,
        hit?: hit?,
        bytes_full: full_meta.bytes,
        bytes_proxy: byte_size(conf_bin),
        full_us: full_us,
        proxy_total_us: proxy_total_us,
        speedup: speedup
      }
    end)
  end

  defp downscale(image, k) do
    {:ok, resized} = Operation.resize(image, 1.0 / k)
    resized
  end

  # Open an image at `path` and apply a light finalize (realize to memory, force
  # sRGB, flatten any alpha onto white) so encode_to_buffer to JPEG is valid. Real
  # production finalization (color management) is a near-no-op for sRGB sources, so
  # this keeps Part C self-contained without the private finalize.
  defp base_image_at(path) do
    case Image.open(path, access: :random) do
      {:ok, img} ->
        {:ok, mem} = VixImage.copy_memory(img)
        {:ok, srgb} = Operation.colourspace(mem, :VIPS_INTERPRETATION_sRGB)
        flatten_alpha(srgb)

      {:error, reason} ->
        IO.puts("Part C: skipping #{path} (open failed: #{inspect(reason)})")
        nil
    end
  end

  defp flatten_alpha(image) do
    if Image.has_alpha?(image) do
      {:ok, flat} = Image.flatten(image, background_color: [255, 255, 255])
      flat
    else
      image
    end
  end

  # Shared by Parts C and D. External files (e.g. genuinely large real photos)
  # replace the small committed set when given, so the run can target
  # production-scale content the repo can't carry. The adversarial synthetic
  # always anchors the worst case.
  defp load_subjects(proxy_files, synth_mp) do
    real =
      case proxy_files do
        [] ->
          Enum.map(@part_c_sources, fn f -> {f, base_image_at(Path.join(@sources_dir, f))} end)

        paths ->
          Enum.map(paths, fn p -> {Path.basename(p), base_image_at(p)} end)
      end

    Enum.reject(real, fn {_l, img} -> is_nil(img) end) ++
      [{"zone-#{synth_mp}MP", zone_plate_for(synth_mp)}]
  end

  # --- Part D: cheap full-res metric narrowing (#6) --------------------------

  # Can a CHEAP full-res metric (PSNR variants — no XYB/multiscale SSIM cost)
  # narrow the search so SSIMULACRA2 runs ~once instead of ~4-6×, landing on the
  # quality the full-res search picks? The final decision stays full-res
  # SSIMULACRA2, so there is no resolution bias (Part C's trap). The viability
  # hinges on ONE thing: is the cheap metric's value AT the SSIMULACRA2 boundary
  # stable across images? A tight spread ⇒ a single global threshold narrows
  # reliably; a wide spread ⇒ the cheap→target mapping is content-dependent and a
  # global threshold under/over-picks. We measure that spread, then simulate the
  # global-threshold strategy (cheap bisection to q, then one SSIMULACRA2 confirm)
  # against the full-res search as oracle.
  @cheap_metrics [:psnr_rgb, :psnr_luma]

  defp run_part_d(proxy_files, synth_mp, format) do
    IO.puts("\n== Part D — cheap full-res metric narrowing (#6) ==")
    IO.puts("oracle = full-res ssim2 search, target #{@target} [#{@min_q},#{@max_q}]  ")
    IO.puts("cheap metrics #{inspect(@cheap_metrics)}  format #{format}\n")

    resolved = ssim2_resolved(format)
    subjects = load_subjects(proxy_files, synth_mp)

    # Pass 1: oracle + the cheap value(s) at the oracle boundary (only meaningful
    # where the oracle actually hit the target — a best-effort ceiling has no
    # boundary, so it can't calibrate or be scored).
    pass1 =
      Enum.map(subjects, fn {label, base} ->
        {:ok, _bin, om} = EncodeSearch.run(base, resolved, telemetry_opts: [])

        boundary =
          if om.score >= @target,
            do: cheap_values(base, om.quality, format),
            else: nil

        %{
          label: label,
          base: base,
          q_oracle: om.quality,
          score_oracle: om.score,
          oracle_probes: om.iterations,
          bytes_oracle: om.bytes,
          boundary: boundary
        }
      end)

    calibrated = Enum.filter(pass1, & &1.boundary)

    thresholds =
      Map.new(@cheap_metrics, fn m -> {m, median(Enum.map(calibrated, & &1.boundary[m]))} end)

    cheap_us = sample_cheap_us(pass1, format)
    report_part_d(pass1, calibrated, thresholds, resolved, format, cheap_us)
  end

  defp report_part_d(pass1, calibrated, thresholds, resolved, format, cheap_us) do
    Enum.each(@cheap_metrics, fn metric ->
      threshold = thresholds[metric]
      IO.puts("--- #{metric}: global threshold #{Float.round(threshold, 2)} ---")

      vals = Enum.map(calibrated, & &1.boundary[metric])

      IO.puts(
        "  cheap@boundary spread: #{spread_note(vals)}  (n=#{length(calibrated)} subjects that hit target)"
      )

      header =
        pad(["source", 18]) <>
          pad(["qOracle", 8]) <>
          pad(["qCheap", 8]) <>
          pad(["dq", 5]) <>
          pad(["cheap@bnd", 11]) <>
          pad(["bytesΔ", 9]) <>
          pad(["verdict", 10])

      IO.puts(header)
      IO.puts(String.duplicate("-", String.length(header)))

      rows = Enum.map(calibrated, &part_d_row(&1, metric, threshold, resolved, format))
      print_part_d_findings(metric, rows, pass1, cheap_us)
    end)

    report_skipped(pass1)
  end

  defp part_d_row(s, metric, threshold, resolved, format) do
    q_cheap = bisect_cheap_q(s.base, format, metric, threshold)
    bytes_cheap = byte_size_at(s.base, resolved, q_cheap)
    dq = q_cheap - s.q_oracle
    bytes_delta = pct(bytes_cheap - s.bytes_oracle, s.bytes_oracle)
    verdict = verdict_for(dq)

    IO.puts(
      pad([s.label, 18]) <>
        pad([s.q_oracle, 8]) <>
        pad([q_cheap, 8]) <>
        pad([dq, 5]) <>
        pad([Float.round(s.boundary[metric], 2), 11]) <>
        pad(["#{bytes_delta}%", 9]) <>
        pad([verdict, 10])
    )

    %{
      label: s.label,
      metric: metric,
      q_oracle: s.q_oracle,
      q_cheap: q_cheap,
      dq: dq,
      bytes_delta: bytes_delta
    }
  end

  defp verdict_for(dq) when dq < 0, do: "UNDERPICK"
  defp verdict_for(dq) when dq > 0, do: "overpick"
  defp verdict_for(_dq), do: "exact"

  defp report_skipped(pass1) do
    skipped = Enum.reject(pass1, & &1.boundary)

    if skipped != [] do
      labels =
        Enum.map_join(
          skipped,
          ", ",
          &"#{&1.label} (oracle #{fmt_score(&1.score_oracle)} < target)"
        )

      IO.puts("(excluded — full-res search itself misses target, no boundary: #{labels})")
    end
  end

  defp print_part_d_findings(_metric, rows, pass1, {cheap_us, ssim2_us}) do
    n = length(rows)
    exact = Enum.count(rows, &(&1.dq == 0))
    within1 = Enum.count(rows, &(abs(&1.dq) <= 1))
    underpicks = Enum.filter(rows, &(&1.dq < 0))
    worst_under = rows |> Enum.map(& &1.dq) |> Enum.min()
    overpicks = Enum.filter(rows, &(&1.dq > 0))
    worst_waste = overpicks |> Enum.map(& &1.bytes_delta) |> max_or_zero()
    oracle_probes = pass1 |> Enum.map(& &1.oracle_probes) |> avg() |> Float.round(1)

    IO.puts("  exact-q #{exact}/#{n}, within-1q #{within1}/#{n}")

    IO.puts(
      "  underpick (dangerous) #{length(underpicks)}/#{n} (worst #{worst_under}q)  |  " <>
        "overpick byte waste worst +#{worst_waste}%"
    )

    IO.puts(
      "  ssim2 probes: oracle ~#{oracle_probes} → candidate 1 confirm (+1-2 on underpick retry)  |  " <>
        "cheap eval ~#{ms(cheap_us)}ms vs ssim2 ~#{ms(ssim2_us)}ms (#{ratio(ssim2_us, cheap_us)}× cheaper)\n"
    )
  end

  # Cheap metric value(s) of a candidate encoded at `q` against the finalized
  # reference. PSNR in dB (higher = better, monotone-ish in q).
  defp cheap_values(base, q, format) do
    {:ok, bin} = Encoder.encode_to_buffer(base, plain_resolved(format, q), q)
    {:ok, cand} = Image.from_binary(bin)
    Map.new(@cheap_metrics, fn m -> {m, cheap_metric(m, base, cand)} end)
  end

  defp cheap_metric(:psnr_rgb, ref, cand), do: psnr(ref, cand)

  defp cheap_metric(:psnr_luma, ref, cand) do
    {:ok, ref_l} = Operation.colourspace(ref, :VIPS_INTERPRETATION_B_W)
    {:ok, cand_l} = Operation.colourspace(cand, :VIPS_INTERPRETATION_B_W)
    psnr(ref_l, cand_l)
  end

  defp psnr(ref, cand) do
    {:ok, rf} = Operation.cast(ref, :VIPS_FORMAT_FLOAT)
    {:ok, cf} = Operation.cast(cand, :VIPS_FORMAT_FLOAT)
    {:ok, diff} = Operation.subtract(rf, cf)
    {:ok, sq} = Operation.multiply(diff, diff)
    {:ok, mse} = Operation.avg(sq)
    if mse <= 0.0, do: 99.0, else: 10 * :math.log10(255 * 255 / mse)
  end

  # Lowest q whose cheap metric clears `threshold` (monotone-increasing in q).
  # Pure cheap probes — no SSIMULACRA2.
  defp bisect_cheap_q(base, format, metric, threshold) do
    do_bisect_cheap(base, format, metric, threshold, @min_q, @max_q, @max_q)
  end

  defp do_bisect_cheap(_base, _format, _metric, _threshold, lo, hi, best) when lo > hi, do: best

  defp do_bisect_cheap(base, format, metric, threshold, lo, hi, best) do
    mid = div(lo + hi, 2)
    {:ok, bin} = Encoder.encode_to_buffer(base, plain_resolved(format, mid), mid)
    {:ok, cand} = Image.from_binary(bin)

    if cheap_metric(metric, base, cand) >= threshold,
      do: do_bisect_cheap(base, format, metric, threshold, lo, mid - 1, mid),
      else: do_bisect_cheap(base, format, metric, threshold, mid + 1, hi, best)
  end

  defp byte_size_at(base, resolved, q) do
    {:ok, bin} = Encoder.encode_to_buffer(base, resolved, q)
    byte_size(bin)
  end

  # One paired timing of a cheap eval vs a full SSIMULACRA2 eval, on the first
  # calibrated subject, to quantify "how much cheaper".
  defp sample_cheap_us(pass1, format) do
    case Enum.find(pass1, & &1.boundary) do
      nil ->
        {1, 1}

      s ->
        {:ok, bin} =
          Encoder.encode_to_buffer(s.base, plain_resolved(format, s.q_oracle), s.q_oracle)

        {:ok, cand} = Image.from_binary(bin)
        {cheap_us, _} = timed(fn -> cheap_metric(:psnr_rgb, s.base, cand) end)
        {:ok, ref} = Ssim2Metric.reference(s.base)
        {ssim2_us, _} = timed(fn -> Ssim2Metric.score(ref, cand) end)
        {cheap_us, ssim2_us}
    end
  end

  # --- Part E: crop-based scoring vs full-frame (#1) -------------------------

  # Score SSIMULACRA2 on native-resolution tiles of the actual full-res encode,
  # instead of the whole frame. Unlike the proxy (Part C) this keeps native
  # resolution, so per-pixel artifact statistics match — the only error is *which
  # regions* you look at. Three questions:
  #   1. Tracking — does a tile aggregate (worst / p10 / mean) at the full-frame
  #      boundary sit at a STABLE value across content? (a global threshold on it
  #      would then ≈ the full-frame target). Reported as the @boundary spread.
  #   2. Sub-sampling — full tile coverage costs ~the same as the full frame, so
  #      the speedup needs scoring only K tiles. Does K-tile sampling still catch
  #      the worst region, or does it miss localized banding? (penalty vs all-tile)
  #   3. Cost — K tiles is a fixed pixel budget regardless of image size.
  # All binned by measured heterogeneity (HET), since heterogeneous images
  # (smooth + detail) are where crop sampling is most at risk.
  @tile 512
  @subsample_k 16

  @e_exts ~w(.png .jpg .jpeg .webp)

  defp run_part_e(corpus_dir, fallback_files, cap, synth_mp, format) do
    IO.puts("\n== Part E — crop-based scoring vs full-frame (#1) ==")
    IO.puts("oracle = full-frame full-res ssim2, target #{@target} [#{@min_q},#{@max_q}]  ")

    IO.puts(
      "tile #{@tile}px  K=#{@subsample_k} (≈#{Float.round(@subsample_k * @tile * @tile / 1_000_000, 1)} MP scored)  " <>
        "q#{@baseline_quality} savings baseline  ≤#{cap}/source  format #{format}\n"
    )

    resolved = ssim2_resolved(format)
    sources = discover_sources(corpus_dir, fallback_files, cap, synth_mp)

    header =
      pad(["source", 14]) <>
        pad(["imgs", 6]) <>
        pad(["hit", 7]) <>
        pad(["q̄", 5]) <>
        pad(["save%", 7]) <>
        pad(["p10off", 8]) <>
        pad(["p10sprd", 9]) <>
        pad(["subPen", 8]) <>
        pad(["full ms", 9]) <>
        pad(["k16 ms", 8])

    IO.puts(header)
    IO.puts(String.duplicate("-", String.length(header)))

    Enum.flat_map(sources, fn {sname, subjects} ->
      rows = Enum.map(subjects, &bench_crop_subject(sname, &1, resolved, format))
      print_source_row(sname, rows)
      rows
    end)
  end

  # One summary line per source as it finishes (per-image rows go to the CSV).
  defp print_source_row(sname, rows) do
    n = length(rows)
    hits = Enum.filter(rows, & &1.hit?)

    if hits == [] do
      IO.puts(pad([sname, 14]) <> pad([n, 6]) <> "0/#{n} hit — no boundary")
    else
      offs = Enum.map(hits, &(&1.p10 - &1.full_score))

      IO.puts(
        pad([sname, 14]) <>
          pad([n, 6]) <>
          pad(["#{length(hits)}/#{n}", 7]) <>
          pad([round(avg(Enum.map(hits, & &1.quality))), 5]) <>
          pad(["#{round(avg(Enum.map(hits, & &1.savings)))}%", 7]) <>
          pad([Float.round(median(offs), 2), 8]) <>
          pad([Float.round(Enum.max(offs) - Enum.min(offs), 2), 9]) <>
          pad([Float.round(avg(Enum.map(hits, &(&1.sub_worst - &1.worst))), 2), 8]) <>
          pad([ms(round(avg(Enum.map(hits, & &1.full_us)))), 9]) <>
          pad([ms(round(avg(Enum.map(hits, & &1.per_tile_us)) * @subsample_k)), 8])
      )
    end
  end

  defp bench_crop_subject(source, {label, base}, resolved, format) do
    {:ok, _bin, om} = EncodeSearch.run(base, resolved, telemetry_opts: [])
    mp = Float.round(Image.width(base) * Image.height(base) / 1_000_000, 1)

    {:ok, b90} =
      Encoder.encode_to_buffer(base, plain_resolved(format, @baseline_quality), @baseline_quality)

    row = %{
      source: source,
      label: label,
      mp: mp,
      hit?: om.score >= @target,
      quality: om.quality,
      full_score: om.score,
      bytes: om.bytes,
      iters: om.iterations,
      savings: pct(byte_size(b90) - om.bytes, byte_size(b90))
    }

    if om.score >= @target,
      do: Map.merge(row, crop_metrics(base, om.quality, format)),
      else: row
  end

  # The crop-scoring measurements for one subject (E fields only; B fields and the
  # hit/miss decision live in bench_crop_subject).
  defp crop_metrics(base, quality, format) do
    {:ok, cbin} = Encoder.encode_to_buffer(base, plain_resolved(format, quality), quality)
    {:ok, cand} = Image.from_binary(cbin)

    {:ok, fref} = Ssim2Metric.reference(base)
    {full_us, {:ok, _}} = timed(fn -> Ssim2Metric.score(fref, cand) end)

    tiles =
      Image.width(base)
      |> tile_coords(Image.height(base), @tile)
      |> Enum.map(&tile_metrics(base, cand, &1))

    scores = Enum.map(tiles, & &1.score)
    texs = Enum.map(tiles, & &1.tex)
    n = length(tiles)
    sorted = Enum.sort(scores)

    lowtex = Enum.count(texs, &(&1 < 2.0)) / n
    busy = Enum.count(texs, &(&1 > 6.0)) / n
    sub = subsample(tiles, @subsample_k) |> Enum.map(& &1.score) |> Enum.sort()

    %{
      het: Float.round(min(lowtex, busy), 2),
      n_tiles: n,
      worst: hd(sorted),
      p10: percentile(sorted, 0.10),
      mean: avg(scores),
      sub_worst: hd(sub),
      sub_p10: percentile(sub, 0.10),
      worst_smooth?: Enum.min_by(tiles, & &1.score).tex < 2.0,
      full_us: full_us,
      per_tile_us: round(avg(Enum.map(tiles, & &1.ssim2_us)))
    }
  end

  # Sources for Part E: each subdirectory of `--corpus DIR` is a source (content
  # type); a flat dir is one "corpus" source; no `--corpus` falls back to the
  # committed high-detail set + a synthetic anchor. Per-source N is capped for
  # balanced macro-averaging and bounded runtime.
  defp discover_sources(nil, fallback_files, _cap, synth_mp) do
    files =
      if fallback_files == [],
        do: Enum.map(@part_c_sources, &Path.join(@sources_dir, &1)),
        else: fallback_files

    [{"corpus", load_bases(files) ++ [{"zone-#{synth_mp}MP", zone_plate_for(synth_mp)}]}]
  end

  defp discover_sources(corpus_dir, _fallback, cap, _synth_mp) do
    subdirs =
      corpus_dir |> Path.join("*") |> Path.wildcard() |> Enum.filter(&File.dir?/1) |> Enum.sort()

    sourced =
      for d <- subdirs,
          imgs = images_in(d, cap),
          imgs != [],
          do: {Path.basename(d), load_bases(imgs)}

    case sourced do
      [] -> [{"corpus", load_bases(images_in(corpus_dir, cap))}]
      list -> list
    end
  end

  defp images_in(dir, cap) do
    dir
    |> Path.join("*")
    |> Path.wildcard()
    |> Enum.filter(&(Path.extname(&1) |> String.downcase() |> Kernel.in(@e_exts)))
    |> Enum.sort()
    |> Enum.take(cap)
  end

  defp load_bases(files) do
    files
    |> Enum.map(&{Path.basename(&1), base_image_at(&1)})
    |> Enum.reject(fn {_label, base} -> is_nil(base) end)
  end

  # Tile coordinates covering the frame with exactly tile-sized windows; the last
  # row/col is clamped to the edge (slight overlap) so every tile is full size and
  # safe for SSIMULACRA2's multiscale downsamples.
  defp tile_coords(w, h, t) do
    tw = min(t, w)
    th = min(t, h)
    for y <- axis_positions(h, th), x <- axis_positions(w, tw), do: {x, y, tw, th}
  end

  defp axis_positions(size, t) when size <= t, do: [0]

  defp axis_positions(size, t) do
    (Enum.take_while(Stream.iterate(0, &(&1 + t)), &(&1 + t <= size)) ++ [size - t])
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp tile_metrics(base, cand, {x, y, w, h}) do
    {:ok, bt} = Operation.extract_area(base, x, y, w, h)
    {:ok, ct} = Operation.extract_area(cand, x, y, w, h)

    # Time only the SSIMULACRA2 work — a real crop-scoring path pays this, not the
    # high-pass texture, which exists only for this benchmark's HET binning.
    {ssim2_us, score} =
      timed(fn ->
        {:ok, ref} = Ssim2Metric.reference(bt)
        {:ok, s} = Ssim2Metric.score(ref, ct)
        s
      end)

    %{score: score, tex: tile_texture(bt), ssim2_us: ssim2_us}
  end

  # High-pass texture energy (gradients removed), so a smooth/gradient tile reads
  # low even if it isn't dead flat — the banding-prone signal.
  defp tile_texture(tile) do
    {:ok, g} = Operation.colourspace(tile, :VIPS_INTERPRETATION_B_W)
    {:ok, gf} = Operation.cast(g, :VIPS_FORMAT_FLOAT)
    {:ok, blur} = Operation.gaussblur(gf, 3.0)
    {:ok, hp} = Operation.subtract(gf, blur)
    {:ok, sq} = Operation.multiply(hp, hp)
    {:ok, ms} = Operation.avg(sq)
    :math.sqrt(max(0.0, ms))
  end

  defp subsample(tiles, k) do
    n = length(tiles)

    if n <= k do
      tiles
    else
      0..(k - 1)
      |> Enum.map(&Enum.at(tiles, div(&1 * (n - 1), k - 1)))
    end
  end

  defp percentile(sorted, p) do
    n = length(sorted)
    Enum.at(sorted, min(n - 1, max(0, trunc(p * (n - 1)))))
  end

  defp findings_part_e([]),
    do: IO.puts("Part E — crop-based scoring: no subjects processed\n")

  defp findings_part_e(rows) do
    hits = Enum.filter(rows, & &1.hit?)
    by_source = rows |> Enum.group_by(& &1.source) |> Enum.sort_by(&elem(&1, 0))

    IO.puts("Part E — crop-based scoring vs full-frame (per source, macro-averaged):")

    # B refresh (free byproduct of the full-frame oracle search), per source.
    IO.puts("  B refresh — ssim2 over real content (savings vs q#{@baseline_quality}):")

    Enum.each(by_source, fn {src, rs} ->
      hs = Enum.filter(rs, & &1.hit?)
      hit_note = "#{length(hs)}/#{length(rs)} hit target"

      if hs == [] do
        IO.puts("    #{String.pad_trailing(src, 14)} #{hit_note}")
      else
        IO.puts(
          "    #{String.pad_trailing(src, 14)} #{hit_note}, q̄ #{round(avg(Enum.map(hs, & &1.quality)))}, " <>
            "save #{round(avg(Enum.map(hs, & &1.savings)))}%, iters #{Float.round(avg(Enum.map(hs, & &1.iters)), 1)}"
        )
      end
    end)

    # E tracking: per-source p10 offset (tile p10 − full-frame score) at the
    # boundary; tight ⇒ a calibrated global threshold reproduces the decision.
    IO.puts("\n  E tracking — p10 offset (tile p10 − full-frame score), per source:")
    src_offset_medians = report_e_tracking(by_source)

    macro_off = src_offset_medians |> avg() |> Float.round(2)
    macro_save = macro_over_sources(by_source, & &1.savings) |> round()
    smooth_worst = Enum.count(hits, & &1.worst_smooth?)

    IO.puts("\n  macro-average across sources:")
    IO.puts("    p10 offset (mean of per-source medians): #{macro_off}")

    IO.puts(
      "    savings: #{macro_save}%  |  worst tile in a smooth region: #{smooth_worst}/#{length(hits)}"
    )

    IO.puts("  -> crops keep native resolution, so they TRACK full-frame across content types")

    IO.puts("     (p10 offset, above); the fixed K-tile budget wins on the large sources.\n")
  end

  defp report_e_tracking(by_source) do
    for {src, rs} <- by_source, hs = Enum.filter(rs, & &1.hit?), hs != [] do
      offs = Enum.map(hs, &(&1.p10 - &1.full_score))
      med = median(offs)
      sub_pen = Float.round(avg(Enum.map(hs, &(&1.sub_worst - &1.worst))), 2)
      k16 = ms(round(avg(Enum.map(hs, & &1.per_tile_us)) * @subsample_k))
      full = ms(round(avg(Enum.map(hs, & &1.full_us))))
      win = if k16 < full, do: "#{Float.round(full / k16, 1)}× win", else: "loss"

      IO.puts(
        "    #{String.pad_trailing(src, 14)} median #{Float.round(med, 2)}  spread #{spread_note(offs)}  " <>
          "subPen +#{sub_pen}  cost #{full}→#{k16}ms (#{win})"
      )

      med
    end
  end

  defp macro_over_sources(by_source, field_fun) do
    for {_src, rs} <- by_source, hs = Enum.filter(rs, & &1.hit?), hs != [] do
      avg(Enum.map(hs, field_fun))
    end
    |> avg()
  end

  # --- Part F: saliency tile selection vs the full-frame confirm (#359) -------

  # The prize crop-scoring leaves on the table: in crop mode the search still runs
  # a FULL-FRAME confirm (+ up to 2 bump passes) on the winner — an O(pixels) cost
  # crop-scoring was built to avoid. Part F asks whether a smarter tile *selection*
  # makes the crop estimate accurate enough to RETIRE that confirm, making the whole
  # search size-independent.
  #
  # Method (no production change): per image, per selector × K, run the real pure
  # search core (`EncodeSearch.search/3`) with a selector-parameterized crop
  # `score_fun` and NO `confirm_fun` — that IS the confirm-skipped path — then take
  # ONE full-frame score at the winner as ground truth. The baseline is the
  # production-today crop path (even selection + full-frame confirm at K=16). All
  # encodes / decodes / full-coverage tile scores are memoized per (image, q) so the
  # 16 selector×K runs reuse one another's work.
  #
  # Residual decomposition at the chosen q tells us whether selection can even help:
  #   * sampling error   = selected_p10 − full_coverage_p10  (selector CAN reduce)
  #   * systematic error = (full_coverage_p10 − offset) − full_frame_score
  #                        (the p10→full mapping; a selector CANNOT fix this — only
  #                         per-content offset recalibration would)
  @partf_ks [8, 12, 16, 24]
  @partf_strategies [:even, :source_detail, :mixed, :diff_aware]
  @crop_macro_offset 0.22

  # Aggregation tracking: {display label, agg_row key}. K16 = the 16-tile even sample
  # (a cheap crop confirm); full = full tile coverage (isolates aggregation from
  # sampling). The question: does a mean track the full-frame score tighter than p10?
  @partf_aggs [
    {"p10  K16", :p10_k16},
    {"p25  K16", :p25_k16},
    {"med  K16", :med_k16},
    {"mean K16", :mean_k16},
    {"p10  full", :p10_full},
    {"p25  full", :p25_full},
    {"med  full", :med_full},
    {"mean full", :mean_full}
  ]

  defp run_part_f(corpus_dir, fallback_files, cap, synth_mp, format) do
    IO.puts("\n== Part F — saliency tile selection vs the full-frame confirm (#359) ==")
    IO.puts("baseline = even + full-frame confirm @ K=#{@subsample_k} (production today)  ")

    IO.puts(
      "variants = {#{Enum.map_join(@partf_strategies, ",", &to_string/1)}} × K∈#{inspect(@partf_ks)}, confirm SKIPPED  " <>
        "target #{@target} [#{@min_q},#{@max_q}]  format #{format}\n"
    )

    resolved = ssim2_resolved(format)
    sources = discover_sources(corpus_dir, fallback_files, cap, synth_mp)

    collected =
      Enum.map(sources, fn {sname, subjects} ->
        pairs = Enum.map(subjects, &bench_partf_subject(sname, &1, resolved, format))
        IO.puts("  #{String.pad_trailing(sname, 14)} #{length(subjects)} imgs done")
        {Enum.flat_map(pairs, &elem(&1, 0)), Enum.map(pairs, &elem(&1, 1))}
      end)

    %{
      variants: Enum.flat_map(collected, &elem(&1, 0)),
      agg: Enum.flat_map(collected, &elem(&1, 1))
    }
  end

  defp bench_partf_subject(source, {label, base}, resolved, format) do
    {:ok, full_ref} = Ssim2Metric.reference(base)
    {:ok, cache} = Agent.start_link(fn -> %{enc: %{}, rev: %{}, data: %{}} end)
    mp = Float.round(Image.width(base) * Image.height(base) / 1_000_000, 1)

    encode_fun = partf_encode_fun(cache, base, format)
    qdata = partf_qdata_fun(cache, base, full_ref)

    d_at = fn q ->
      {:ok, bytes} = encode_fun.(q)
      qdata.(bytes)
    end

    crop_fun = fn strat, k -> partf_crop_score_fun(qdata, strat, k) end

    # Baseline: production-today crop path (even + full-frame confirm at K=16).
    {:ok, _b, bmeta} =
      EncodeSearch.search(resolved.quality_search, nil,
        encode_fun: encode_fun,
        score_fun: crop_fun.(:even, @subsample_k),
        confirm_fun: fn bytes -> qdata.(bytes).full_score end,
        confirm_band: @target,
        confirm_max_quality: @max_q,
        max_bump_passes: 2,
        scorer: :crop,
        scorer_tiles: @subsample_k,
        max_iterations: @max_iter + 3,
        telemetry_opts: []
      )

    d0 = d_at.(bmeta.quality)
    base_deliv = d0.full_score

    base_ctx = %{
      source: source,
      label: label,
      mp: mp,
      base_q: bmeta.quality,
      base_deliv: base_deliv,
      base_hit?: base_deliv >= @target,
      base_confirm_passes: bmeta.confirm_passes
    }

    rows =
      for strat <- @partf_strategies, k <- @partf_ks do
        partf_variant_row(base_ctx, resolved, encode_fun, d_at, crop_fun, strat, k)
      end

    agg_row = partf_agg_row(source, label, mp, d0)
    Agent.stop(cache)
    {rows, agg_row}
  end

  # Aggregation tracking at the delivered quality: how closely each crop aggregate
  # (p10/p25/median/mean, over the K=16 sample and over full coverage) predicts the
  # full-frame score. residual = aggregate − full_frame_score. Tests whether a CHEAP
  # crop aggregate could stand in for the full-frame confirm — the systematic gap
  # Part F's decomposition exposed is largely "p10-of-tiles vs whole-frame", so a
  # mean may track tighter than the (deliberately pessimistic) p10.
  defp partf_agg_row(source, label, mp, d) do
    full = d.full_score
    all = Enum.sort(Enum.map(d.tiles, & &1.score))

    k16 =
      d.tiles |> TileSelection.select(@subsample_k, :even) |> Enum.map(& &1.score) |> Enum.sort()

    %{
      source: source,
      label: label,
      mp: mp,
      full_score: full,
      p10_k16: percentile(k16, 0.10) - full,
      p25_k16: percentile(k16, 0.25) - full,
      med_k16: percentile(k16, 0.50) - full,
      mean_k16: avg(k16) - full,
      p10_full: percentile(all, 0.10) - full,
      p25_full: percentile(all, 0.25) - full,
      med_full: percentile(all, 0.50) - full,
      mean_full: avg(all) - full
    }
  end

  # One confirm-skipped variant: search with the selector's crop score_fun and no
  # confirm, then score the winner full-frame for ground truth + decompose residual.
  defp partf_variant_row(base_ctx, resolved, encode_fun, d_at, crop_fun, strat, k) do
    {:ok, _v, vmeta} =
      EncodeSearch.search(resolved.quality_search, nil,
        encode_fun: encode_fun,
        score_fun: crop_fun.(strat, k),
        max_iterations: @max_iter,
        telemetry_opts: []
      )

    d = d_at.(vmeta.quality)
    sel = TileSelection.select(d.tiles, k, strat)
    sel_p10 = percentile(Enum.sort(Enum.map(sel, & &1.score)), 0.10)
    full_p10 = percentile(Enum.sort(Enum.map(d.tiles, & &1.score)), 0.10)
    n = length(d.tiles)

    Map.merge(base_ctx, %{
      strategy: strat,
      k: k,
      q_sel: vmeta.quality,
      deliv: d.full_score,
      deliv_err: d.full_score - @target,
      regress?: base_ctx.base_hit? and d.full_score < @target,
      sampling_err: sel_p10 - full_p10,
      systematic_err: full_p10 - @crop_macro_offset - d.full_score,
      n_tiles: n,
      ktile_us: round(d.per_tile_us * min(k, n)),
      full_us: d.full_us,
      diff_map_us: d.diff_map_us
    })
  end

  # Encode closure: memoizes bytes per quality and the reverse bytes→q map (so the
  # bytes-keyed score_fun can recover q to hit the per-quality data cache). The
  # encode runs OUTSIDE the agent critical section — access is strictly sequential
  # per image, so a check-then-store can't race, and the agent never blocks past the
  # default GenServer-call timeout on a slow large-image encode.
  defp partf_encode_fun(cache, base, format) do
    fn q ->
      case Agent.get(cache, &Map.get(&1.enc, q)) do
        nil ->
          {:ok, bytes} = Encoder.encode_to_buffer(base, plain_resolved(format, q), q)
          Agent.update(cache, &store_encode(&1, q, bytes))
          {:ok, bytes}

        bytes ->
          {:ok, bytes}
      end
    end
  end

  defp store_encode(st, q, bytes),
    do: %{st | enc: Map.put(st.enc, q, bytes), rev: Map.put(st.rev, bytes, q)}

  # Per-quality data: decode once, full-frame score once, full tile coverage scored
  # + cheap signals once. Memoized by q; like the encode, the heavy compute runs
  # OUTSIDE the agent so the (sequential) call never trips the call timeout.
  defp partf_qdata_fun(cache, base, full_ref) do
    fn bytes -> fetch_qdata(cache, base, full_ref, bytes) end
  end

  defp fetch_qdata(cache, base, full_ref, bytes) do
    q = Agent.get(cache, &Map.fetch!(&1.rev, bytes))

    case Agent.get(cache, &Map.get(&1.data, q)) do
      nil -> store_qdata(cache, q, compute_partf_qdata(base, full_ref, bytes))
      d -> d
    end
  end

  defp store_qdata(cache, q, d) do
    Agent.update(cache, fn st -> %{st | data: Map.put(st.data, q, d)} end)
    d
  end

  defp partf_crop_score_fun(qdata, strat, k) do
    fn bytes ->
      d = qdata.(bytes)
      sel = TileSelection.select(d.tiles, k, strat)
      percentile(Enum.sort(Enum.map(sel, & &1.score)), 0.10) - @crop_macro_offset
    end
  end

  defp compute_partf_qdata(base, full_ref, bytes) do
    {:ok, cand} = Image.from_binary(bytes)
    {full_us, {:ok, full_score}} = timed(fn -> Ssim2Metric.score(full_ref, cand) end)
    coords = tile_coords(Image.width(base), Image.height(base), @tile)

    {tiles, ssim_us, source_us, diff_us} =
      Enum.reduce(coords, {[], 0, 0, 0}, fn {x, y, w, h}, {acc, su, so_us, di_us} ->
        {:ok, bt} = Operation.extract_area(base, x, y, w, h)
        {:ok, ct} = Operation.extract_area(cand, x, y, w, h)

        {so, source_detail} = timed(fn -> tile_texture(bt) end)
        {di, {diff, diff_detail}} = timed(fn -> diff_signals(bt, ct) end)

        {ss, score} =
          timed(fn ->
            {:ok, ref} = Ssim2Metric.reference(bt)
            {:ok, s} = Ssim2Metric.score(ref, ct)
            s
          end)

        tile = %{
          x: x,
          y: y,
          w: w,
          h: h,
          score: score,
          source_detail: source_detail,
          diff: diff,
          diff_detail: diff_detail
        }

        {[tile | acc], su + ss, so_us + so, di_us + di}
      end)

    n = length(coords)

    %{
      full_score: full_score,
      full_us: full_us,
      tiles: Enum.reverse(tiles),
      per_tile_us: if(n > 0, do: div(ssim_us, n), else: 0),
      source_map_us: source_us,
      diff_map_us: diff_us
    }
  end

  # Candidate-dependent signals for a tile pair: mean |source − candidate| and the
  # high-pass energy of that difference (structured artifacts: ringing, blocking).
  defp diff_signals(bt, ct) do
    {:ok, bf} = Operation.cast(bt, :VIPS_FORMAT_FLOAT)
    {:ok, cf} = Operation.cast(ct, :VIPS_FORMAT_FLOAT)
    {:ok, dimg} = Operation.subtract(bf, cf)
    {:ok, dabs} = Operation.abs(dimg)
    {:ok, diff} = Operation.avg(dabs)

    {:ok, blur} = Operation.gaussblur(dabs, 3.0)
    {:ok, hp} = Operation.subtract(dabs, blur)
    {:ok, sq} = Operation.multiply(hp, hp)
    {:ok, ms} = Operation.avg(sq)

    {diff, :math.sqrt(max(0.0, ms))}
  end

  defp findings_part_f([]),
    do: IO.puts("Part F — saliency tile selection: no subjects processed\n")

  defp findings_part_f(rows) do
    hits = Enum.filter(rows, & &1.base_hit?)

    IO.puts("Part F — saliency tile selection vs the full-frame confirm:")

    IO.puts(
      "  (over #{length(Enum.uniq_by(hits, &{&1.source, &1.label}))} images the baseline+confirm path hit target; " <>
        "deliv_err/|samp|/|sys| are macro-medians, worst_under is the global tail)\n"
    )

    Enum.each(@partf_ks, fn k -> report_partf_k(hits, k) end)

    base_full = hits |> Enum.map(& &1.full_us) |> avg() |> ms()
    base_passes = hits |> Enum.map(& &1.base_confirm_passes) |> avg() |> Float.round(1)
    diff_overhead = hits |> Enum.map(& &1.diff_map_us) |> avg() |> ms()

    IO.puts(
      "  cost context: 1 full-frame confirm ≈ #{base_full} ms (baseline runs ~#{base_passes} confirm passes);"
    )

    IO.puts(
      "    skipping it is the prize. candidate-dependent diff-map overhead ≈ #{diff_overhead} ms/probe " <>
        "(diff_aware only; source-only selectors add ~0 per-probe).\n"
    )

    IO.puts(
      "  read: a selector retires the confirm only if its worst_under stays inside the best-effort"
    )

    IO.puts(
      "  band AND |sys| (which selection can't fix) is small; if |sys| dominates |samp|, no selector helps.\n"
    )
  end

  defp report_partf_k(hits, k) do
    IO.puts("  K=#{k}")

    header =
      "    " <>
        pad(["strategy", 16]) <>
        pad(["deliv_err", 11]) <>
        pad(["worst_under", 13]) <>
        pad(["|samp|", 8]) <>
        pad(["|sys|", 8]) <>
        pad(["regress", 9]) <>
        pad(["Ktile_ms", 9])

    IO.puts(header)

    Enum.each(@partf_strategies, fn strat ->
      rs = Enum.filter(hits, &(&1.strategy == strat and &1.k == k))
      print_partf_strategy_row(strat, rs)
    end)
  end

  defp print_partf_strategy_row(strat, []), do: IO.puts("    #{pad([strat, 16])}(no data)")

  defp print_partf_strategy_row(strat, rs) do
    by_source = Enum.group_by(rs, & &1.source)
    deliv_med = macro_median(by_source, & &1.deliv_err)
    samp_med = macro_median(by_source, &abs(&1.sampling_err))
    sys_med = macro_median(by_source, &abs(&1.systematic_err))
    worst_under = rs |> Enum.map(& &1.deliv_err) |> Enum.min()
    regress = Enum.count(rs, & &1.regress?)
    ktile_ms = rs |> Enum.map(& &1.ktile_us) |> avg() |> ms()

    IO.puts(
      "    " <>
        pad([strat, 16]) <>
        pad([Float.round(deliv_med, 2), 11]) <>
        pad([Float.round(worst_under, 2), 13]) <>
        pad([Float.round(samp_med, 2), 8]) <>
        pad([Float.round(sys_med, 2), 8]) <>
        pad(["#{regress}/#{length(rs)}", 9]) <>
        pad([ktile_ms, 9])
    )
  end

  # Macro-median: median within each source, then the mean of those — so no single
  # content type dominates (matches Part E's macro convention).
  defp macro_median(by_source, fun) do
    by_source
    |> Enum.map(fn {_src, rs} -> median(Enum.map(rs, fun)) end)
    |> avg()
  end

  defp findings_part_f_agg([]), do: :ok

  defp findings_part_f_agg(rows) do
    IO.puts(
      "\n  Aggregation tracking — can a CROP aggregate stand in for the full-frame confirm?"
    )

    IO.puts(
      "  residual = aggregate(tiles) − full_frame_score, over #{length(rows)} images @ delivered q."
    )

    IO.puts(
      "  offset = median residual (a global calibration constant); worst± = max |residual − offset|"
    )

    IO.puts(
      "  (the irreducible per-image error a confirm/bump must absorb — smaller ⇒ better stand-in).\n"
    )

    IO.puts(
      "    " <>
        pad(["aggregate", 11]) <> pad(["offset", 9]) <> pad(["worst±", 9]) <> pad(["spread", 18])
    )

    Enum.each(@partf_aggs, fn {label, key} -> print_partf_agg_row(label, key, rows) end)

    {best_label, best_key} =
      Enum.min_by(@partf_aggs, fn {_label, key} -> partf_agg_worst(rows, key) end)

    best_worst = partf_agg_worst(rows, best_key)

    IO.puts(
      "\n  -> best aggregate: #{String.trim(best_label)} (worst±#{Float.round(best_worst, 2)}). " <>
        partf_agg_verdict(best_worst)
    )
  end

  # A crop aggregate can stand in for the full-frame confirm only if even its
  # worst-case post-calibration error fits the boundary tolerance the confirm
  # exists to defend (Part E's ±~1.5-pt tracking claim).
  @partf_confirm_band 1.5

  defp print_partf_agg_row(label, key, rows) do
    rs = Enum.map(rows, &Map.fetch!(&1, key))
    off = median(rs)
    worst = rs |> Enum.map(&abs(&1 - off)) |> Enum.max()

    IO.puts(
      "    " <>
        pad([label, 11]) <>
        pad([Float.round(off, 2), 9]) <>
        pad([Float.round(worst, 2), 9]) <>
        pad([spread_note(rs), 18])
    )
  end

  defp partf_agg_worst(rows, key) do
    rs = Enum.map(rows, &Map.fetch!(&1, key))
    off = median(rs)
    rs |> Enum.map(&abs(&1 - off)) |> Enum.max()
  end

  defp partf_agg_verdict(best_worst) when best_worst <= @partf_confirm_band,
    do:
      "fits the ±#{@partf_confirm_band} best-effort band — a crop confirm on this aggregate " <>
        "is worth prototyping."

  defp partf_agg_verdict(best_worst),
    do:
      "still ≫ the ±#{@partf_confirm_band} best-effort band (off by ~#{Float.round(best_worst, 1)} " <>
        "on the worst image) — every aggregate shares the same content-dependent systematic tail, " <>
        "so aggregation is NOT the lever; per-content offset calibration is."

  # --- resolved descriptors --------------------------------------------------

  defp ssim2_resolved(format) do
    %Resolved{
      base_resolved(format)
      | quality: :default,
        quality_search: %RQS{
          objective: :ssim2,
          target: @target,
          min_quality: @min_q,
          max_quality: @max_q,
          allowed_error: 0,
          max_resolution: 0
        }
    }
  end

  defp size_resolved(format, budget) do
    %Resolved{
      base_resolved(format)
      | quality: :default,
        quality_search: %RQS{
          objective: :size,
          target: budget,
          min_quality: @min_q,
          max_quality: @max_q,
          allowed_error: 0,
          max_resolution: 0
        }
    }
  end

  defp max_bytes_resolved(format, budget) do
    %Resolved{base_resolved(format) | quality: :default, max_bytes: budget}
  end

  defp plain_resolved(format, quality) do
    %Resolved{base_resolved(format) | quality: {:quality, quality}}
  end

  defp base_resolved(format) do
    %Resolved{
      format: format,
      quality: :default,
      response_headers: [],
      strip_metadata: true,
      keep_copyright: false,
      color_profile: :strip
    }
  end

  # --- telemetry capture -----------------------------------------------------

  defp attach_telemetry do
    :telemetry.attach(
      handler_id(),
      @prefix ++ [:encode, :search, :stop],
      &__MODULE__.handle_search_stop/4,
      self()
    )
  end

  @doc false
  def handle_search_stop(_event, _measurements, meta, target),
    do: send(target, {:bench_search_meta, meta})

  defp detach_telemetry, do: :telemetry.detach(handler_id())

  defp handler_id, do: {__MODULE__, self()}

  defp receive_search_meta do
    receive do
      {:bench_search_meta, meta} -> meta
    after
      0 -> raise "no [:encode, :search] :stop telemetry received — did the search run?"
    end
  end

  # --- synthetic source ------------------------------------------------------

  # Deterministic high-frequency zone-plate (chirp), scaled to a full-range 8-bit
  # sRGB 3-band image. The frequency sweeps to Nyquist across the frame at every
  # size, so the content is adversarial for JPEG at all resolutions — the ssim2
  # search never reaches its target band and spends its full iteration budget,
  # giving worst-case cost as a clean function of pixel count.
  defp zone_plate(w, h) do
    {:ok, z} = Operation.zone(w, h)
    {:ok, scaled} = Operation.linear(z, [127.5], [127.5])
    {:ok, uchar} = Operation.cast(scaled, :VIPS_FORMAT_UCHAR)
    {:ok, rgb} = Operation.bandjoin([uchar, uchar, uchar])
    {:ok, srgb} = Operation.copy(rgb, interpretation: :VIPS_INTERPRETATION_sRGB)
    srgb
  end

  defp zone_plate_for(mp) do
    {w, h} = square_dims(mp)
    zone_plate(w, h)
  end

  defp square_dims(mp) do
    side = round(:math.sqrt(mp * 1_000_000))
    {side, side}
  end

  # --- findings --------------------------------------------------------------

  defp print_findings(a_rows, b_rows, c_rows, e_rows, f_rows, format) do
    IO.puts("\n== Findings ==\n")

    if a_rows, do: findings_part_a(a_rows)
    if b_rows, do: findings_part_b(b_rows)
    if c_rows, do: findings_part_c(c_rows)
    if e_rows, do: findings_part_e(e_rows)

    if f_rows do
      findings_part_f(f_rows.variants)
      findings_part_f_agg(f_rows.agg)
    end

    IO.puts("\n(format: #{format}; numbers vary with CPU + libvips build — re-run locally)")
  end

  defp findings_part_a(rows) do
    avg_metric_pct = rows |> Enum.map(& &1.metric_pct) |> avg() |> round()

    over_500 = Enum.find(rows, &(&1.total_us > 500_000))
    over_1000 = Enum.find(rows, &(&1.total_us > 1_000_000))
    over_2000 = Enum.find(rows, &(&1.total_us > 2_000_000))

    IO.puts("Part A — cost curve:")
    IO.puts("  * metric dominates: ~#{avg_metric_pct}% of total wall-clock on average")
    IO.puts("  * first size over 500ms total:  #{budget_note(over_500)}")
    IO.puts("  * first size over 1000ms total: #{budget_note(over_1000)}")
    IO.puts("  * first size over 2000ms total: #{budget_note(over_2000)}")
    IO.puts("  -> recommended autoquality_max_resolution: pick the MP under your")
    IO.puts("     per-request budget from the column above (full 6x pass cost).\n")
  end

  defp budget_note(nil), do: "none in tested range"
  defp budget_note(row), do: "#{row.mp} MP (#{ms(row.total_us)} ms, #{row.iters} iters)"

  defp findings_part_b(rows) do
    scored = Enum.filter(rows, &(&1.score != nil))
    hits = Enum.count(scored, & &1.hit?)
    avg_q = scored |> Enum.map(& &1.quality) |> avg() |> round()
    avg_save = scored |> Enum.map(& &1.savings) |> avg() |> round()
    avg_iters = scored |> Enum.map(& &1.iters) |> avg() |> Float.round(1)
    avg_ssim2_ms = scored |> Enum.map(& &1.ssim2_us) |> avg() |> ms()
    avg_size_ms = rows |> Enum.map(& &1.size_us) |> avg() |> ms()
    avg_mb_ms = rows |> Enum.map(& &1.mb_us) |> avg() |> ms()

    speedup = ratio(avg(Enum.map(scored, & &1.ssim2_us)), avg(Enum.map(rows, & &1.size_us)))

    IO.puts("Part B — accuracy + behavior:")
    IO.puts("  * ssim2 hit target #{@target}: #{hits}/#{length(scored)} scored sources")

    IO.puts(
      "  * typical chosen quality ~#{avg_q}, avg savings vs q#{@baseline_quality} ~#{avg_save}%"
    )

    IO.puts("  * avg iterations: #{avg_iters} (cap #{@max_iter})")

    IO.puts(
      "  * avg cost: ssim2 #{avg_ssim2_ms} ms vs size #{avg_size_ms} ms vs max_bytes #{avg_mb_ms} ms"
    )

    IO.puts("  * ssim2 is ~#{speedup}x the cost of size (the decode+metric overhead)\n")
  end

  # Two error directions, judged against the FULL-res search (the achievable
  # ground truth — not the absolute target, which the full search itself may miss
  # at the bracket ceiling):
  #   * q_proxy > q_full: the downscaled proxy needs a higher quality to clear the
  #     SAME score (SSIMULACRA2 is harsher on downscaled images), so the encode is
  #     LARGER than the optimal full-res pick — savings erode. The expensive-to-fix
  #     direction (recovering it needs a downward full-res search).
  #   * q_proxy < q_full: the proxy under-picks → delivered score regresses below
  #     full. Only a true proxy regression when the full search HIT (otherwise the
  #     target was unreachable regardless). Cheap to fix (bump q + one confirm).
  defp findings_part_c(rows) do
    IO.puts("Part C — downscaled-proxy-seed method + accuracy:")

    rows
    |> Enum.group_by(& &1.k)
    |> Enum.sort_by(fn {k, _} -> k end)
    |> Enum.each(fn {k, group} ->
      full_hit = Enum.filter(group, &(&1.full_score >= @target))
      regressions = Enum.count(full_hit, &(not &1.hit?))

      worst_drop =
        group |> Enum.map(&Float.round(&1.delivered_score - &1.full_score, 2)) |> Enum.min()

      worst_overpick = group |> Enum.map(& &1.dq) |> Enum.max()
      worst_bytes = group |> Enum.map(&byte_overshoot/1) |> Enum.max()
      mean_speedup = group |> Enum.map(& &1.speedup) |> avg() |> Float.round(1)
      mean_proxy_ms = group |> Enum.map(& &1.proxy_total_us) |> avg() |> ms()

      IO.puts(
        "  k=#{k}: proxy-caused undershoots #{regressions}/#{length(full_hit)} (of full-hit)  |  " <>
          "worst Δscore vs full #{worst_drop}  |  worst over-pick +#{worst_overpick}q / +#{worst_bytes}% bytes  |  " <>
          "~#{mean_speedup}x (#{mean_proxy_ms} ms)"
      )
    end)

    IO.puts("  -> SSIMULACRA2 is resolution-dependent: a given q scores LOWER on a")
    IO.puts("     downscaled proxy, so the search systematically OVER-picks q on real")
    IO.puts("     content (bigger images → bigger over-pick → more savings lost). That")
    IO.puts("     direction is the expensive one to undo; a cheap confirm-and-adjust")
    IO.puts("     only rescues undershoot. Naive downscale+margin is not viable — a")
    IO.puts("     correct proxy needs the target calibrated across resolution.\n")
  end

  defp byte_overshoot(%{bytes_proxy: bp, bytes_full: bf}) when bf > 0,
    do: round((bp - bf) / bf * 100)

  defp byte_overshoot(_), do: 0

  # --- CSV -------------------------------------------------------------------

  defp write_part_a_csv(rows) do
    path = "/tmp/autoquality_bench_part_a.csv"

    head =
      "mp,width,height,iters,total_us,ref_us,encode_us,decode_us,metric_us,per_iter_us,metric_pct,score,quality\n"

    body =
      Enum.map_join(rows, fn r ->
        "#{r.mp},#{r.w},#{r.h},#{r.iters},#{r.total_us},#{r.ref_us},#{r.encode_us}," <>
          "#{r.decode_us},#{r.metric_us},#{r.per_iter_us},#{r.metric_pct},#{fmt_score(r.score)},#{r.quality}\n"
      end)

    File.write!(path, head <> body)
    IO.puts("\nwrote #{path}")
  end

  defp write_part_b_csv(rows) do
    path = "/tmp/autoquality_bench_part_b.csv"

    head =
      "source,width,height,mp,quality,score,hit,bytes,baseline_bytes,savings,iters," <>
        "ssim2_us,size_us,size_iters,mb_us,mb_iters\n"

    body =
      Enum.map_join(rows, fn r ->
        "#{r.source},#{r.w},#{r.h},#{r.mp},#{r.quality},#{fmt_score(r.score)},#{r.hit?}," <>
          "#{r.bytes},#{r.baseline_bytes},#{r.savings},#{r.iters},#{r.ssim2_us}," <>
          "#{r.size_us},#{r.size_iters},#{r.mb_us},#{r.mb_iters}\n"
      end)

    File.write!(path, head <> body)
    IO.puts("wrote #{path}")
  end

  defp write_part_e_csv(rows) do
    path = "/tmp/autoquality_bench_part_e.csv"

    head =
      "source,label,mp,hit,quality,full_score,bytes,savings,iters," <>
        "het,n_tiles,worst,p10,mean,sub_worst,sub_p10,worst_smooth,full_us,per_tile_us\n"

    body =
      Enum.map_join(rows, fn r ->
        "#{r.source},#{r.label},#{r.mp},#{r.hit?},#{r.quality},#{fmt_score(r.full_score)}," <>
          "#{r.bytes},#{r.savings},#{r.iters}," <>
          "#{e_cell(r, :het)},#{e_cell(r, :n_tiles)},#{e_cell(r, :worst, &fmt_score/1)}," <>
          "#{e_cell(r, :p10, &fmt_score/1)},#{e_cell(r, :mean, &fmt_score/1)}," <>
          "#{e_cell(r, :sub_worst, &fmt_score/1)},#{e_cell(r, :sub_p10, &fmt_score/1)}," <>
          "#{e_cell(r, :worst_smooth?)},#{e_cell(r, :full_us)},#{e_cell(r, :per_tile_us)}\n"
      end)

    File.write!(path, head <> body)
    IO.puts("wrote #{path}")
  end

  # E fields are absent on miss rows (no boundary); render those cells blank.
  defp e_cell(row, key, fmt \\ &to_string/1) do
    case Map.get(row, key) do
      nil -> ""
      value -> fmt.(value)
    end
  end

  defp write_part_c_csv(rows) do
    path = "/tmp/autoquality_bench_part_c.csv"

    head =
      "source,mp,k,proxy_mp,q_full,q_proxy,dq,full_score,delivered_score,delta_target,hit," <>
        "bytes_full,bytes_proxy,full_us,proxy_total_us,speedup\n"

    body =
      Enum.map_join(rows, fn r ->
        "#{r.source},#{r.mp},#{r.k},#{r.proxy_mp},#{r.q_full},#{r.q_proxy},#{r.dq}," <>
          "#{fmt_score(r.full_score)},#{fmt_score(r.delivered_score)},#{Float.round(r.delta_target, 2)}," <>
          "#{r.hit?},#{r.bytes_full},#{r.bytes_proxy},#{r.full_us},#{r.proxy_total_us},#{r.speedup}\n"
      end)

    File.write!(path, head <> body)
    IO.puts("wrote #{path}")
  end

  defp write_part_f_csv(rows) do
    path = "/tmp/autoquality_bench_part_f.csv"

    head =
      "source,label,mp,strategy,k,base_q,base_deliv,base_hit,base_confirm_passes," <>
        "q_sel,deliv,deliv_err,regress,sampling_err,systematic_err,n_tiles,ktile_us,full_us,diff_map_us\n"

    body =
      Enum.map_join(rows, fn r ->
        "#{r.source},#{r.label},#{r.mp},#{r.strategy},#{r.k},#{r.base_q}," <>
          "#{fmt_score(r.base_deliv)},#{r.base_hit?},#{r.base_confirm_passes}," <>
          "#{r.q_sel},#{fmt_score(r.deliv)},#{Float.round(r.deliv_err, 3)},#{r.regress?}," <>
          "#{Float.round(r.sampling_err, 3)},#{Float.round(r.systematic_err, 3)}," <>
          "#{r.n_tiles},#{r.ktile_us},#{r.full_us},#{r.diff_map_us}\n"
      end)

    File.write!(path, head <> body)
    IO.puts("wrote #{path}")
  end

  defp write_part_f_agg_csv(rows) do
    path = "/tmp/autoquality_bench_part_f_agg.csv"

    head =
      "source,label,mp,full_score,p10_k16,p25_k16,med_k16,mean_k16," <>
        "p10_full,p25_full,med_full,mean_full\n"

    body =
      Enum.map_join(rows, fn r ->
        "#{r.source},#{r.label},#{r.mp},#{fmt_score(r.full_score)}," <>
          "#{Float.round(r.p10_k16, 3)},#{Float.round(r.p25_k16, 3)}," <>
          "#{Float.round(r.med_k16, 3)},#{Float.round(r.mean_k16, 3)}," <>
          "#{Float.round(r.p10_full, 3)},#{Float.round(r.p25_full, 3)}," <>
          "#{Float.round(r.med_full, 3)},#{Float.round(r.mean_full, 3)}\n"
      end)

    File.write!(path, head <> body)
    IO.puts("wrote #{path}")
  end

  # --- helpers ---------------------------------------------------------------

  defp timed(fun) do
    t0 = System.monotonic_time(:microsecond)
    result = fun.()
    {System.monotonic_time(:microsecond) - t0, result}
  end

  defp parse_format("jpeg"), do: :jpeg
  defp parse_format("webp"), do: :webp
  defp parse_format("avif"), do: :avif
  defp parse_format(other), do: raise("unsupported --format #{inspect(other)} (jpeg|webp|avif)")

  defp parse_mps(nil), do: @default_mps

  defp parse_mps(str) do
    str
    |> String.split(",", trim: true)
    |> Enum.map(&(&1 |> String.trim() |> parse_number()))
  end

  defp parse_number(s) do
    case Integer.parse(s) do
      {int, ""} -> int
      _ -> s |> Float.parse() |> elem(0)
    end
  end

  defp parse_factors(nil), do: @default_factors

  defp parse_factors(str) do
    str
    |> String.split(",", trim: true)
    |> Enum.map(&(&1 |> String.trim() |> String.to_integer()))
  end

  defp parse_files(nil), do: []
  defp parse_files(str), do: str |> String.split(",", trim: true) |> Enum.map(&String.trim/1)

  defp ms(us) when is_integer(us), do: Float.round(us / 1000, 1)
  defp ms(us), do: Float.round(us / 1000, 1)

  defp pct(_part, 0), do: 0
  defp pct(part, whole), do: round(part / whole * 100)

  defp ratio(_a, 0), do: 0.0
  defp ratio(a, b), do: Float.round(a / b, 1)

  defp avg([]), do: 0
  defp avg(list), do: Enum.sum(list) / length(list)

  defp median([]), do: 0.0

  defp median(list) do
    sorted = Enum.sort(list)
    n = length(sorted)
    mid = div(n, 2)

    if rem(n, 2) == 1,
      do: Enum.at(sorted, mid),
      else: (Enum.at(sorted, mid - 1) + Enum.at(sorted, mid)) / 2
  end

  defp max_or_zero([]), do: 0
  defp max_or_zero(list), do: Enum.max(list)

  defp spread_note([]), do: "n/a"

  defp spread_note(vals) do
    "#{Float.round(Enum.min(vals), 2)}…#{Float.round(Enum.max(vals), 2)} " <>
      "(range #{Float.round(Enum.max(vals) - Enum.min(vals), 2)})"
  end

  defp fmt_score(nil), do: "-"
  defp fmt_score(score), do: Float.round(score, 2)

  defp pad([value, width]), do: value |> to_string() |> String.pad_trailing(width)
end
