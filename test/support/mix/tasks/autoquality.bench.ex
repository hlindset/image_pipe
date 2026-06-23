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
      mise exec -- mix autoquality.bench --part g --corpus DIR  # early-stop vs full search, per format cap
      mise exec -- mix autoquality.bench --part h --corpus DIR  # crop+confirm vs full-frame target-hit confidence
      mise exec -- mix autoquality.bench --part i --corpus DIR  # raise max_quality: under-target vs bytes vs latency
      mise exec -- mix autoquality.bench --part j --corpus DIR  # sweep allowed_error: on-target vs byte cost
      mise exec -- mix autoquality.bench --part k --corpus DIR  # sweep crop→full offset on the confirm-skipped large-image verdict
      mise exec -- mix autoquality.bench --part k --corpus DIR --offsets 0,0.5,1.5,2.5  # custom offset ladder
      mise exec -- mix autoquality.bench --part all      # A + B + C + D + E + F + G + H + I + J + K
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

  ## Part G — early-stop vs lowest-satisfying on the narrow format caps

  The shipped `:ssim2` search runs to the **lowest-satisfying** quality (lowest q in
  the bracket scoring `≥ target − allowed_error`). On the narrow per-format caps —
  AVIF `[60,65]`, WebP / JPEG `[70,80]` — the bracket holds only a handful of integer
  qualities, so the question is whether the extra metric probes the full search spends
  narrowing down to the *lowest* satisfying q buy enough bytes to be worth their cost,
  or whether an early stop (or no search at all) ships essentially the same bytes far
  cheaper. The metric dominates the search cost (Part A), and the cost is paid once per
  **cache miss** while the bytes save on **every hit**, so a small ΔkB can still justify
  the search for cacheable traffic — the early stop only clearly wins when ΔkB ≈ 0 or
  the content is low-hit / unique.

  Measurement only — `EncodeSearch` is untouched; each stop policy is replicated in the
  bench over a shared per-`(subject, format, q)` encode+decode+score cache (Part F's
  memoization), so every variant's probe count / metric ms / delivered bytes is its own
  even though work is reused. Brackets resolve through the **real** production per-format
  caps (`autoquality_format_min/max_quality`, base `[#{70},#{80}]`, `avif [#{60},#{65}]`),
  target #{78}, allowed_error #{1} (band `≥ #{77}`), scorer = full-frame ssim2 (the
  default for normal-size images), per format (jpeg, webp, avif) over the corpus.

  Variants vs the full-search baseline (1):

    1. **full** — lowest-satisfying binary search (production today). Baseline.
    2. **wguard≤N** — if `max−min ≤ N`, skip the search entirely and encode at
       `max_quality` (1 encode, no metric, no reference). N ∈ #{inspect([1, 2, 3, 5, 10])}
       (AVIF's width-5 bracket trips at N=5, WebP/JPEG's width-10 at N=10).
    3. **itercap=M** — full search capped at M distinct encodes, ship best-so-far.
       M ∈ #{inspect([2, 3])}.
    4. **first-accept** — binary search, ship the first probed q clearing the band
       instead of narrowing down to the lowest satisfying.
    5. **two-sided** — binary search, ship the first probe inside `[target−ae, target+ae]`
       (`[#{77},#{79}]`); overshoot → go lower, undershoot → go higher.
    6. **floor-first** — probe `min_quality` first; ship it if it clears the band,
       else fall back to the full search.

  Per `(source, format)` and macro-averaged per format, each variant reports probes,
  metric ms (and total ms), delivered bytes (kB), Δms and ΔkB (absolute + %) vs the
  full-search baseline (the extra time the full search spends / the extra bytes it
  saves by continuing), and how often it ships under target. Verdict per format: where
  ΔkB is negligible relative to Δms the early-stop / width-guard wins; where continuing
  saves real kB keep the full search (caching amortizes its once-per-miss cost).

  Needs `--corpus DIR` (assemble one spanning smooth / busy / text / photographic
  content); falls back to the committed high-detail sources + a synthetic anchor when
  absent.

  ## Part H — crop+confirm vs full-frame target-hit confidence

  Crop scoring (#354) only runs above the 6 MP crossover, where it estimates the
  full-frame score from K tiles and then **confirms on the full frame** (+ bump). Part H
  asks how reliably that shipped path hits the target vs the full-frame search, on the
  same images, by running BOTH real production searches (`EncodeSearch.run` with scorer
  `:full` / `:crop`) per image at the production per-format brackets + target #{78}. The
  meaningful cohort is the >6 MP images (where crop actually engages); below the
  crossover production uses full-frame and the comparison is moot. Reports, over the
  crop-regime cohort: full-frame vs crop+confirm target-hit rate, **regressions** (full
  hit, crop missed), the delivered `crop − full` score delta (median + worst), and how
  often the bump fired / exhausted. A low absolute hit rate is the bracket ceiling on
  hard content (large photos / screenshots can't reach #{78} in the bracket), not crop
  error — the crop-vs-full *delta* is the confidence signal.

  ## Part I — raising `max_quality`: under-target drop vs byte cost vs latency

  Parts G/H surfaced that most images ship *under* target because the bracket ceiling
  (`max_quality`) is too low to reach #{78}, not because the search is wrong. Part I
  quantifies the lever: per format, sweep candidate `max_quality` values (jpeg/webp
  `[80,85,90,95]`, avif `[65,70,75,80]`; the first is the
  shipped default) keeping `min_quality`, and run the real lowest-satisfying search at
  each over a shared per-`(image, q)` cache. For each candidate, vs the shipped-default
  bracket on the *same* image, it reports: target-hit rate and its lift, the byte cost
  (median Δ% + kB), and the added search latency (probes + metric ms from the wider
  bracket). Turns "raise the cap" into the bytes/quality/latency price of each step.
  Uses full-frame scoring as the where-does-it-land ground truth (Part H showed crop
  reproduces it). Same `--corpus DIR` + fallback as E/F/G.

  ## Part J — sweeping `allowed_error`: on-target rate vs byte cost

  Part I's other half. The cap only rescues ceiling-pinned images; the larger "under
  target" population ships *in-band below the ceiling* because `allowed_error` accepts
  the lowest quality scoring `≥ target − allowed_error` and takes it. The lever for THAT
  population is the acceptance band. Part J sweeps `allowed_error`
  `#{inspect([0, 0.5, 1.0, 1.5, 2.0])}` at fixed target #{78} (default `1.0`), per
  format, keeping the shipped brackets, over a shared per-`(image, q)` cache (the score
  is band-independent, so one cache serves every candidate). For each `allowed_error`, vs
  the default on the same image, it reports the on-target rate (delivered full-frame
  score `≥ #{78}`), the median delivered score (quality), and the byte / latency cost.
  `allowed_error = 0` forces every non-ceiling-pinned image on-target at max byte cost;
  higher values ship smaller, more under-target files — a continuous bytes↔quality dial
  whose cost is **broad** (nudges almost every image), unlike the cap's ceiling-pinned-
  only effect. Same `--corpus DIR` + fallback as E/F/G.

  ## Part K — confirm-skipped crop verdict: global crop→full offset sweep

  The timeout autopsy that motivated this part: a 37 MP no-resize request runs the
  crop path, the crop estimate clears the band while the full-frame confirm keeps
  failing it, and the bump loop fires a fresh O(pixels) full-frame metric per pass
  until the request deadline kills it (a 500). Part F established the residual is
  *systematic* (a global p10→full bias), not sampling, so tile selection can't retire
  the confirm; the only source-agnostic, deterministic lever left is the **global
  offset** `@crop_macro_offset` (today 0.22). Part K asks: if we ship the crop
  objective winner WITHOUT the full-frame confirm (so the search is flat ~4.2 MP and
  can never time out), what global offset minimizes the target miss and its
  worst-undershoot tail, and what byte cost does it carry?

  Method (no production change): on the >#{6} MP cohort (where crop engages) per
  `(source, format)`, build Part F's per-image encode + full-frame + tile cache, then
  (a) run the production crop+confirm search once as the baseline, and (b) for each
  candidate offset run the pure search core with the K=#{16} even crop `score_fun`
  (`p10 − offset`) and NO `confirm_fun` — the confirm-skipped verdict — taking ONE
  full-frame score at the winner as ground truth. Because encode/decode/metric are
  memoized, sweeping offsets reuses all heavy work; only the cheap `p10 − offset`
  arithmetic and the search control flow re-run.

  Reports, over the crop-regime cohort across formats: the per-image systematic
  residual (`even-K16 p10 − full_frame` at the baseline pick) summarized as
  median / p90 / worst — the distribution an offset must cover — plus the
  full-frame confirm cost dropped (the prize). Then per offset: on-target rate
  (delivered full-frame `≥ #{78}`), median delivered error, **worst undershoot**
  (the safety tail), median byte delta vs the crop+confirm baseline (a larger offset
  ships higher quality → fewer savings), and regressions (baseline hit, this offset
  missed). The verdict leads with the regression count — the actual "is it safe to
  drop the confirm?" signal — then suggests the offset near the p90 systematic
  residual, since the deep undershooters are bracket-ceiling-bound (a Part I lever, not
  a confirm one). Same `--corpus DIR` + fallback as E/F/G; the committed fallback is
  mostly ≤6 MP, so supply large photos (or the synthetic anchor) to populate the cohort.

  Finding (full corpus, 46 crop-regime subject×format cases): dropping the confirm
  caused **0 target-hit regressions** at every swept offset — the deep undershooters
  (worst ~−14) are bracket-ceiling-bound (can't reach the target at max_quality), which
  the confirm couldn't fix either, so it only re-confirmed hits and ceiling-bound
  misses. The systematic residual is ~0 on the median (shipped 0.22 is about right) but
  has a tail (p90 ~2.4, worst ~5.8) **concentrated in screen content** (text/UI tiles
  diverge most from the whole frame); large photos sit near 0. Raising the global offset
  0→3 nudged on-target only a few points at ~0% byte cost, because the misses are
  ceiling-bound, not offset-bound. Read: for large images a confirm-skipped crop verdict
  is safe against baseline regressions and removes the unbounded full-frame cost, but a
  conservative offset (≈p90, not the median) is needed to cover the screen-content tail,
  and the residual under-target is a Part I (raise-the-cap) lever, not a confirm one.
  """
  use Mix.Task
  use Boundary, top_level?: true, check: [out: false]

  alias ImagePipe.Output.ContentClassifier
  alias ImagePipe.Output.Encoder
  alias ImagePipe.Output.EncodeSearch
  alias ImagePipe.Output.Resolved
  alias ImagePipe.Output.ResolvedQualitySearch, as: RQS
  alias ImagePipe.Output.Ssim2Metric
  alias ImagePipe.Output.Ssim2Metric.CropScore
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

  # Part M classifier downsample default (long-edge px); overridable with --downsample.
  @m_downsample 1024

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
          offsets: :string,
          k: :string,
          tile: :string,
          corpus: :string,
          corpus_cap: :integer,
          downsample: :integer
        ]
      )

    part = Keyword.get(opts, :part, "both")
    csv? = Keyword.get(opts, :csv, false)
    format = opts |> Keyword.get(:format, "jpeg") |> parse_format()
    mps = parse_mps(Keyword.get(opts, :mps))
    factors = parse_factors(Keyword.get(opts, :proxy_factors))
    proxy_files = parse_files(Keyword.get(opts, :proxy_files))
    offsets = parse_offsets(Keyword.get(opts, :offsets))
    ks = parse_ks(Keyword.get(opts, :k))
    tiles = parse_tiles(Keyword.get(opts, :tile))
    proxy_mp = Keyword.get(opts, :proxy_mp, 16)

    {:ok, _} = Application.ensure_all_started(:image_pipe)
    warmup(format)

    run_ctx = %{
      part: part,
      mps: mps,
      factors: factors,
      proxy_mp: proxy_mp,
      proxy_files: proxy_files,
      offsets: offsets,
      ks: ks,
      tiles: tiles,
      corpus_dir: Keyword.get(opts, :corpus),
      corpus_cap: Keyword.get(opts, :corpus_cap, 24),
      downsample: Keyword.get(opts, :downsample, @m_downsample),
      format: format
    }

    parts = run_selected_parts(run_ctx)
    if csv?, do: write_csvs(parts)
    print_findings(parts, format)
  end

  defp run_selected_parts(%{part: part, format: format} = ctx) do
    run = fn names, fun -> if part in names, do: fun.() end

    # Part D prints inline and returns nil — run it for its side effect, drop the result.
    run.(["d", "all"], fn -> run_part_d(ctx.proxy_files, ctx.proxy_mp, format) end)

    corpus = fn fun ->
      fun.(ctx.corpus_dir, ctx.proxy_files, ctx.corpus_cap, ctx.proxy_mp)
    end

    %{
      a: run.(["a", "both", "all"], fn -> run_part_a(ctx.mps, format) end),
      b: run.(["b", "both", "all"], fn -> run_part_b(format) end),
      c:
        run.(["c", "all"], fn ->
          run_part_c(ctx.factors, ctx.proxy_mp, ctx.proxy_files, format)
        end),
      e: run.(["e", "all"], fn -> corpus.(&run_part_e(&1, &2, &3, &4, format)) end),
      f: run.(["f", "all"], fn -> corpus.(&run_part_f(&1, &2, &3, &4, format)) end),
      g: run.(["g", "all"], fn -> corpus.(&run_part_g/4) end),
      h: run.(["h", "all"], fn -> corpus.(&run_part_h/4) end),
      i: run.(["i", "all"], fn -> corpus.(&run_part_i/4) end),
      j: run.(["j", "all"], fn -> corpus.(&run_part_j/4) end),
      k: run.(["k", "all"], fn -> corpus.(&run_part_k(&1, &2, &3, &4, ctx.offsets)) end),
      l: run.(["l", "all"], fn -> corpus.(&run_part_l(&1, &2, &3, &4, ctx.ks, ctx.tiles)) end),
      m: run.(["m", "all"], fn -> corpus.(&run_part_m(&1, &2, &3, &4, ctx.downsample)) end)
    }
  end

  defp write_csvs(parts) do
    [
      {parts.a, &write_part_a_csv/1},
      {parts.b, &write_part_b_csv/1},
      {parts.c, &write_part_c_csv/1},
      {parts.e, &write_part_e_csv/1},
      {parts.f,
       fn f ->
         write_part_f_csv(f.variants)
         write_part_f_agg_csv(f.agg)
       end},
      {parts.g, &write_part_g_csv/1},
      {parts.h, &write_part_h_csv/1},
      {parts.i, &write_part_i_csv/1},
      {parts.j, &write_part_j_csv/1},
      {parts.k, &write_part_k_csv/1},
      {parts.l, &write_part_l_csv/1},
      {parts.m, &write_part_m_csv/1}
    ]
    |> Enum.each(fn {rows, writer} -> if rows, do: writer.(rows) end)
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

  # --- Part G: early-stop vs lowest-satisfying on the narrow format caps ------

  # Production autoquality defaults (the imgproxy parser), distinct from Parts A/B's
  # adversarial wide bracket: target 78, base [70,80], avif [60,65], allowed_error 1.
  # Brackets resolve per format exactly as Output.Policy.resolve_search/2 does
  # (format_min/max with per-side fallback to the base bracket).
  @g_target 78
  @g_min_q 70
  @g_max_q 80
  @g_allowed_error 1
  @g_format_min %{avif: 60}
  @g_format_max %{avif: 65}
  @g_band @g_target - @g_allowed_error
  @g_band_hi @g_target + @g_allowed_error
  @g_formats [:jpeg, :webp, :avif]
  @g_width_guard_ns [1, 2, 3, 5, 10]
  @g_iter_caps [2, 3]

  defp run_part_g(corpus_dir, fallback_files, cap, synth_mp) do
    IO.puts("\n== Part G — early-stop vs lowest-satisfying on the narrow format caps ==")
    IO.puts("baseline = full search (lowest-satisfying)  target #{@g_target} band ≥#{@g_band}  ")

    IO.puts(
      "brackets: jpeg #{inspect(g_bracket(:jpeg))} webp #{inspect(g_bracket(:webp))} " <>
        "avif #{inspect(g_bracket(:avif))}  scorer full-frame  ≤#{cap}/source\n"
    )

    sources = discover_sources(corpus_dir, fallback_files, cap, synth_mp)

    Enum.flat_map(sources, fn {sname, subjects} ->
      rows = Enum.flat_map(subjects, &g_bench_subject(sname, &1))
      Enum.each(@g_formats, fn fmt -> print_g_source_table(sname, fmt, rows) end)
      rows
    end)
  end

  # Per-format bracket via the real per-side fallback: format_min[fmt] else base min,
  # format_max[fmt] else base max (Output.Policy.resolve_search/2).
  defp g_bracket(format),
    do: {Map.get(@g_format_min, format, @g_min_q), Map.get(@g_format_max, format, @g_max_q)}

  defp g_bench_subject(source, {label, base}) do
    {ref_us, {:ok, ref}} = timed(fn -> Ssim2Metric.reference(base) end)

    Enum.flat_map(@g_formats, fn fmt ->
      g_bench_subject_format(source, label, base, ref, ref_us, fmt)
    end)
  end

  # All variants for one (subject, format), reusing one memoized encode+decode+score
  # cache. A format the local libvips can't encode is skipped with a note (the throw
  # from g_compute is caught here, not left to abort the whole run).
  defp g_bench_subject_format(source, label, base, ref, ref_us, format) do
    {lo, hi} = g_bracket(format)
    {:ok, cache} = Agent.start_link(fn -> %{} end)
    id = %{source: source, label: label, format: format}

    try do
      score_of = fn q -> g_probe(cache, base, ref, format, q).score end

      Enum.map(g_variants(), fn {variant, vfun} ->
        {chosen, probed, mode} = vfun.(lo, hi, score_of)
        # Ensure the delivered q is in the cache so its bytes/score are measurable
        # even for the skip path (which scores nothing toward its cost).
        _ = g_probe(cache, base, ref, format, chosen)
        g_row(id, variant, chosen, probed, mode, Agent.get(cache, & &1), ref_us)
      end)
    catch
      {:g_unsupported, ^format, _reason} ->
        IO.puts("  #{label}/#{format}: skipped (encode unsupported)")
        []
    after
      Agent.stop(cache)
    end
  end

  # {label, fun/3}. fun.(lo, hi, score_of) → {chosen_q, scored_probes, :search | :skip}.
  # :search scores every distinct encoded q (incl. chosen, like the real ssim2 path);
  # :skip (width-guard trip) encodes once and scores nothing.
  defp g_variants do
    [{"full", &g_full/3}] ++
      Enum.map(@g_width_guard_ns, fn n -> {"wguard<=#{n}", g_width_guard(n)} end) ++
      Enum.map(@g_iter_caps, fn m -> {"itercap=#{m}", g_iter_cap(m)} end) ++
      [
        {"first-accept", &g_first_acceptable/3},
        {"two-sided", &g_two_sided/3},
        {"floor-first", &g_floor_first/3}
      ]
  end

  # Lowest q in [lo, hi] with score ≥ band; ceiling (max_q) when none clear.
  defp g_full(lo, hi, score_of) do
    {chosen, probed} = g_full_core(lo, hi, score_of)
    {chosen, Enum.uniq([chosen | probed]), :search}
  end

  defp g_full_core(lo, hi, score_of), do: do_g_lowest(lo, hi, score_of, hi, nil, [])

  defp do_g_lowest(lo, hi, _score_of, ceiling, best, probed) when lo > hi,
    do: {best || ceiling, probed}

  defp do_g_lowest(lo, hi, score_of, ceiling, best, probed) do
    mid = div(lo + hi, 2)
    probed = [mid | probed]

    if score_of.(mid) >= @g_band,
      do: do_g_lowest(lo, mid - 1, score_of, ceiling, mid, probed),
      else: do_g_lowest(mid + 1, hi, score_of, ceiling, best, probed)
  end

  # Skip the search and encode at max_q when the bracket is narrow enough; else full.
  defp g_width_guard(n) do
    fn lo, hi, score_of ->
      if hi - lo <= n, do: {hi, [], :skip}, else: g_full(lo, hi, score_of)
    end
  end

  # Full search capped at m distinct encodes; ship best-so-far (else ceiling).
  defp g_iter_cap(m) do
    fn lo, hi, score_of ->
      {chosen, probed} = do_g_capped(lo, hi, score_of, hi, nil, [], m)
      {chosen, Enum.uniq([chosen | probed]), :search}
    end
  end

  defp do_g_capped(lo, hi, _score_of, ceiling, best, probed, _m) when lo > hi,
    do: {best || ceiling, probed}

  defp do_g_capped(_lo, _hi, _score_of, ceiling, best, probed, m) when length(probed) >= m,
    do: {best || ceiling, probed}

  defp do_g_capped(lo, hi, score_of, ceiling, best, probed, m) do
    mid = div(lo + hi, 2)
    probed = [mid | probed]

    if score_of.(mid) >= @g_band,
      do: do_g_capped(lo, mid - 1, score_of, ceiling, mid, probed, m),
      else: do_g_capped(mid + 1, hi, score_of, ceiling, best, probed, m)
  end

  # Ship the first probed q clearing the band; never narrow below it. Ceiling if none.
  defp g_first_acceptable(lo, hi, score_of) do
    {chosen, probed} = do_g_first(lo, hi, score_of, hi, [])
    {chosen, Enum.uniq([chosen | probed]), :search}
  end

  defp do_g_first(lo, hi, _score_of, ceiling, probed) when lo > hi, do: {ceiling, probed}

  defp do_g_first(lo, hi, score_of, ceiling, probed) do
    mid = div(lo + hi, 2)
    probed = [mid | probed]

    if score_of.(mid) >= @g_band,
      do: {mid, probed},
      else: do_g_first(mid + 1, hi, score_of, ceiling, probed)
  end

  # Ship the first probe inside [target-ae, target+ae]; overshoot → lower, under → higher.
  defp g_two_sided(lo, hi, score_of) do
    {chosen, probed} = do_g_two(lo, hi, score_of, hi, nil, [])
    {chosen, Enum.uniq([chosen | probed]), :search}
  end

  defp do_g_two(lo, hi, _score_of, ceiling, best, probed) when lo > hi,
    do: {best || ceiling, probed}

  defp do_g_two(lo, hi, score_of, ceiling, best, probed) do
    mid = div(lo + hi, 2)
    probed = [mid | probed]
    score = score_of.(mid)

    cond do
      score >= @g_band and score <= @g_band_hi -> {mid, probed}
      score > @g_band_hi -> do_g_two(lo, mid - 1, score_of, ceiling, mid, probed)
      true -> do_g_two(mid + 1, hi, score_of, ceiling, best, probed)
    end
  end

  # Probe the floor first; ship it if it clears the band, else fall back to full.
  defp g_floor_first(lo, hi, score_of) do
    if score_of.(lo) >= @g_band do
      {lo, [lo], :search}
    else
      {chosen, probed} = g_full_core(lo, hi, score_of)
      {chosen, Enum.uniq([lo | [chosen | probed]]), :search}
    end
  end

  # Memoized per (subject, format) encode + decode + score for one quality. The heavy
  # work runs outside the agent critical section (access is sequential per subject).
  defp g_probe(cache, base, ref, format, q) do
    case Agent.get(cache, &Map.get(&1, q)) do
      nil ->
        data = g_compute(base, ref, format, q)
        Agent.update(cache, &Map.put(&1, q, data))
        data

      data ->
        data
    end
  end

  defp g_compute(base, ref, format, q) do
    {enc_us, enc} = timed(fn -> Encoder.encode_to_buffer(base, plain_resolved(format, q), q) end)
    bin = g_unwrap_encode(enc, format)
    {dec_us, {:ok, cand}} = timed(fn -> Image.from_binary(bin) end)
    {met_us, {:ok, score}} = timed(fn -> Ssim2Metric.score(ref, cand) end)

    %{
      bytes: byte_size(bin),
      encode_us: enc_us,
      decode_us: dec_us,
      metric_us: met_us,
      score: score
    }
  end

  defp g_unwrap_encode({:ok, bin}, _format), do: bin
  defp g_unwrap_encode({:error, reason}, format), do: throw({:g_unsupported, format, reason})

  # One variant's outcome priced from the cache. enc = distinct encodes (incl. chosen);
  # a :search variant scores all of them + pays the reference once, a :skip variant
  # pays only the single delivery encode (no metric, no reference).
  defp g_row(id, variant, chosen, probed, mode, cache, ref_us) do
    enc = Enum.uniq([chosen | probed])
    score_qs = if mode == :skip, do: [], else: enc
    encode_us = g_sum(cache, enc, :encode_us)
    decode_us = g_sum(cache, score_qs, :decode_us)
    metric_us = g_sum(cache, score_qs, :metric_us)
    ref = if score_qs == [], do: 0, else: ref_us
    delivered = Map.fetch!(cache, chosen)

    %{
      source: id.source,
      label: id.label,
      format: id.format,
      variant: variant,
      probes: length(enc),
      metric_us: metric_us,
      total_us: encode_us + decode_us + metric_us + ref,
      bytes: delivered.bytes,
      score: delivered.score,
      under_target?: delivered.score < @g_target,
      chosen: chosen
    }
  end

  defp g_sum(_cache, [], _field), do: 0

  defp g_sum(cache, qs, field),
    do: qs |> Enum.map(&Map.fetch!(Map.fetch!(cache, &1), field)) |> Enum.sum()

  # --- Part G reporting ------------------------------------------------------

  defp print_g_source_table(source, format, all_rows) do
    rows = Enum.filter(all_rows, &(&1.source == source and &1.format == format))
    if rows != [], do: do_print_g_source_table(source, format, rows)
  end

  defp do_print_g_source_table(source, format, rows) do
    n = rows |> Enum.map(& &1.label) |> Enum.uniq() |> length()
    IO.puts("  #{source} / #{format}  (#{n} imgs)")

    header =
      "    " <>
        pad(["variant", 14]) <>
        pad(["probes", 7]) <>
        pad(["metric_ms", 11]) <>
        pad(["total_ms", 10]) <>
        pad(["kB", 8]) <>
        pad(["Δms", 9]) <>
        pad(["ΔkB", 9]) <>
        pad(["Δ%", 7]) <>
        pad(["under", 7])

    IO.puts(header)
    Enum.each(g_aggregate(rows), &print_g_agg_row/1)
  end

  defp print_g_agg_row(a) do
    IO.puts(
      "    " <>
        pad([a.variant, 14]) <>
        pad([Float.round(a.probes, 1), 7]) <>
        pad([Float.round(a.metric_ms, 1), 11]) <>
        pad([Float.round(a.total_ms, 1), 10]) <>
        pad([Float.round(a.kb, 1), 8]) <>
        pad([Float.round(a.dms, 1), 9]) <>
        pad([Float.round(a.dkb, 2), 9]) <>
        pad(["#{Float.round(a.dpct, 1)}%", 7]) <>
        pad(["#{a.under}/#{a.n}", 7])
    )
  end

  # Aggregate a set of (label, variant) rows for one format into one line per variant:
  # each metric averaged over labels, and Δ computed per-label against THAT label's own
  # full-search baseline before averaging (so Δ pairs like with like).
  defp g_aggregate(rows) do
    base_by_label =
      rows |> Enum.filter(&(&1.variant == "full")) |> Map.new(&{&1.label, &1})

    order = g_variants() |> Enum.map(&elem(&1, 0)) |> Enum.with_index() |> Map.new()

    rows
    |> Enum.group_by(& &1.variant)
    |> Enum.map(fn {variant, vrows} -> g_variant_summary(variant, vrows, base_by_label) end)
    |> Enum.sort_by(&Map.get(order, &1.variant, 99))
  end

  defp g_variant_summary(variant, vrows, base_by_label) do
    per = Enum.map(vrows, &g_variant_deltas(&1, base_by_label[&1.label]))

    %{
      variant: variant,
      n: length(per),
      probes: avg(Enum.map(per, & &1.probes)),
      metric_ms: avg(Enum.map(per, & &1.metric_ms)),
      total_ms: avg(Enum.map(per, & &1.total_ms)),
      kb: avg(Enum.map(per, & &1.kb)),
      dms: avg(Enum.map(per, & &1.dms)),
      dkb: avg(Enum.map(per, & &1.dkb)),
      dpct: avg(Enum.map(per, & &1.dpct)),
      under: Enum.count(per, & &1.under)
    }
  end

  defp g_variant_deltas(r, base) do
    %{
      probes: r.probes,
      metric_ms: r.metric_us / 1000,
      total_ms: r.total_us / 1000,
      kb: r.bytes / 1024,
      dms: (r.total_us - base.total_us) / 1000,
      dkb: (r.bytes - base.bytes) / 1024,
      dpct: if(base.bytes > 0, do: (r.bytes - base.bytes) / base.bytes * 100, else: 0.0),
      under: r.under_target?
    }
  end

  defp findings_part_g([]),
    do: IO.puts("Part G — early-stop vs full search: no subjects processed\n")

  defp findings_part_g(rows) do
    IO.puts("Part G — early-stop vs lowest-satisfying (macro-average per format):")

    IO.puts(
      "  Δms/ΔkB are per-image vs the same image's full search, macro-averaged over " <>
        "sources; cost is paid once per cache miss, bytes save on every hit.\n"
    )

    Enum.each(@g_formats, fn format -> findings_part_g_format(format, rows) end)
  end

  defp findings_part_g_format(format, rows) do
    fmt_rows = Enum.filter(rows, &(&1.format == format))

    if fmt_rows == [] do
      IO.puts("  #{format}: no data\n")
    else
      IO.puts("  #{format} (bracket #{inspect(g_bracket(format))}):")
      by_source = Enum.group_by(fmt_rows, & &1.source)
      summaries = g_macro_over_sources(by_source)
      Enum.each(summaries, fn s -> IO.puts("    #{g_format_verdict_line(s)}") end)
      IO.puts("")
    end
  end

  # Macro-average each variant's per-image deltas within a source, then across sources.
  defp g_macro_over_sources(by_source) do
    order = g_variants() |> Enum.map(&elem(&1, 0)) |> Enum.with_index() |> Map.new()

    by_source
    |> Enum.map(fn {_src, rs} -> g_aggregate(rs) end)
    |> List.flatten()
    |> Enum.group_by(& &1.variant)
    |> Enum.map(fn {variant, aggs} ->
      %{
        variant: variant,
        metric_ms: avg(Enum.map(aggs, & &1.metric_ms)),
        dms: avg(Enum.map(aggs, & &1.dms)),
        dkb: avg(Enum.map(aggs, & &1.dkb)),
        dpct: avg(Enum.map(aggs, & &1.dpct)),
        under_rate: avg(Enum.map(aggs, &(&1.under / max(&1.n, 1))))
      }
    end)
    |> Enum.sort_by(&Map.get(order, &1.variant, 99))
  end

  defp g_format_verdict_line(%{variant: "full"} = s) do
    "#{String.pad_trailing(s.variant, 14)} metric #{Float.round(s.metric_ms, 1)}ms  " <>
      "(baseline)  under-target #{pct_str(s.under_rate)}"
  end

  defp g_format_verdict_line(s) do
    "#{String.pad_trailing(s.variant, 14)} Δms #{Float.round(s.dms, 1)}  " <>
      "ΔkB #{Float.round(s.dkb, 2)} (#{Float.round(s.dpct, 1)}%)  " <>
      "under #{pct_str(s.under_rate)}  → #{g_verdict(s.dms, s.dkb)}"
  end

  # Early stop wins when it saves time (Δms < 0) without shipping meaningfully more
  # bytes (|ΔkB| negligible); keep the full search when it recovers real bytes.
  defp g_verdict(dms, dkb) when abs(dms) <= 0.5 and abs(dkb) < 0.5, do: "≡ baseline (no-op)"
  defp g_verdict(dms, _dkb) when dms > 0.5, do: "slower, no win"
  defp g_verdict(_dms, dkb) when abs(dkb) < 0.5, do: "EARLY-STOP WINS (ΔkB≈0)"
  defp g_verdict(_dms, dkb) when dkb < 2.0, do: "marginal (small ΔkB)"
  defp g_verdict(_dms, _dkb), do: "keep full search (real ΔkB)"

  defp pct_str(rate), do: "#{round(rate * 100)}%"

  # --- Part H: crop+confirm vs full-frame target-hit confidence ---------------

  # How reliably does the shipped crop path (crop estimate + full-frame confirm +
  # bump) hit the target vs the full-frame search, on the SAME images? Runs both real
  # production searches (`EncodeSearch.run` with scorer :full / :crop) per image, using
  # the production per-format brackets + target 78 (Part G's @g_* config). Crop only
  # runs above the 6 MP crossover in production, so the meaningful cohort is the >6 MP
  # images — below it production uses full-frame and the comparison is moot.
  defp run_part_h(corpus_dir, fallback_files, cap, synth_mp) do
    IO.puts("\n== Part H — crop+confirm vs full-frame target-hit confidence ==")
    IO.puts("both real searches (scorer :full / :crop)  target #{@g_target} band ≥#{@g_band}  ")

    IO.puts(
      "crop crossover #{CropScore.crossover_megapixels()} MP (crop active above it)  " <>
        "≤#{cap}/source  formats #{inspect(@g_formats)}\n"
    )

    sources = discover_sources(corpus_dir, fallback_files, cap, synth_mp)

    Enum.flat_map(sources, fn {sname, subjects} ->
      rows = Enum.flat_map(subjects, &h_bench_subject(sname, &1))
      print_h_source_row(sname, rows)
      rows
    end)
  end

  defp h_bench_subject(source, {label, base}) do
    mp = Float.round(Image.width(base) * Image.height(base) / 1_000_000, 1)
    Enum.flat_map(@g_formats, fn format -> h_run(source, label, base, mp, format) end)
  end

  # Run the production search both ways. A format the local libvips can't encode (e.g.
  # a >16383 px screenshot to webp/avif) returns {:error, _} from run/3 and is skipped.
  defp h_run(source, label, base, mp, format) do
    resolved = h_resolved(format)

    with {:ok, _fb, full} <- EncodeSearch.run(base, resolved, scorer: :full, telemetry_opts: []),
         {:ok, _cb, crop} <- EncodeSearch.run(base, resolved, scorer: :crop, telemetry_opts: []) do
      [h_row(source, label, format, mp, full, crop)]
    else
      {:error, _reason} ->
        IO.puts("  #{label}/#{format}: skipped (search/encode unsupported)")
        []
    end
  end

  defp h_row(source, label, format, mp, full, crop) do
    %{
      source: source,
      label: label,
      format: format,
      mp: mp,
      crop_regime?: mp > CropScore.crossover_megapixels(),
      full_hit?: full.score >= @g_target,
      crop_hit?: crop.score >= @g_target,
      full_q: full.quality,
      crop_q: crop.quality,
      full_score: full.score,
      crop_score: crop.score,
      score_delta: crop.score - full.score,
      byte_delta: crop.bytes - full.bytes,
      confirm_passes: crop.confirm_passes,
      bump_exhausted?: crop.limiting_factor == :bump_exhausted
    }
  end

  # Production RQS for one format: target 78, the real per-format bracket, allowed_error
  # 1, no resolution skip (we WANT crop to run on big images here).
  defp h_resolved(format) do
    {lo, hi} = g_bracket(format)

    %Resolved{
      base_resolved(format)
      | quality: :default,
        quality_search: %RQS{
          objective: :ssim2,
          target: @g_target,
          min_quality: lo,
          max_quality: hi,
          allowed_error: @g_allowed_error,
          max_resolution: 0
        }
    }
  end

  defp print_h_source_row(source, rows) do
    crop = Enum.filter(rows, & &1.crop_regime?)
    n = length(rows)

    if crop == [] do
      IO.puts("  #{String.pad_trailing(source, 14)} #{n} imgs, 0 in crop regime (>6 MP)")
    else
      regress = Enum.count(crop, &(&1.full_hit? and not &1.crop_hit?))
      deltas = Enum.map(crop, & &1.score_delta)

      IO.puts(
        "  #{String.pad_trailing(source, 14)} #{n} imgs, #{length(crop)} crop-regime: " <>
          "full hit #{Enum.count(crop, & &1.full_hit?)}/#{length(crop)}, " <>
          "crop hit #{Enum.count(crop, & &1.crop_hit?)}/#{length(crop)}, " <>
          "regress #{regress}, Δscore med #{Float.round(median(deltas), 2)} worst #{Float.round(Enum.min(deltas), 2)}"
      )
    end
  end

  defp findings_part_h([]),
    do: IO.puts("Part H — crop+confirm vs full-frame: no subjects processed\n")

  defp findings_part_h(rows) do
    crop = Enum.filter(rows, & &1.crop_regime?)
    IO.puts("Part H — crop+confirm vs full-frame target-hit confidence:")
    findings_part_h_cohort(crop)
  end

  defp findings_part_h_cohort([]) do
    IO.puts(
      "  no images above the #{CropScore.crossover_megapixels()} MP crossover in this corpus — " <>
        "crop never engages, so there is nothing to compare (below it production uses full-frame).\n"
    )
  end

  defp findings_part_h_cohort(crop) do
    n = length(crop)
    full_hits = Enum.count(crop, & &1.full_hit?)
    crop_hits = Enum.count(crop, & &1.crop_hit?)
    regress = Enum.filter(crop, &(&1.full_hit? and not &1.crop_hit?))
    improve = Enum.count(crop, &(&1.crop_hit? and not &1.full_hit?))
    deltas = Enum.map(crop, & &1.score_delta)
    bumped = Enum.count(crop, &(&1.confirm_passes > 1))
    exhausted = Enum.count(crop, & &1.bump_exhausted?)

    IO.puts(
      "  over #{n} crop-regime images (>#{CropScore.crossover_megapixels()} MP), all formats:"
    )

    IO.puts("    full-frame hit target:   #{full_hits}/#{n} (#{pct_int(full_hits, n)}%)")
    IO.puts("    crop+confirm hit target: #{crop_hits}/#{n} (#{pct_int(crop_hits, n)}%)")

    IO.puts(
      "    crop regressions (full hit, crop missed): #{length(regress)}/#{n} " <>
        "(#{pct_int(length(regress), n)}%)  |  crop improvements: #{improve}"
    )

    IO.puts(
      "    delivered Δscore (crop − full): median #{Float.round(median(deltas), 2)}, " <>
        "worst undershoot #{Float.round(Enum.min(deltas), 2)}, worst over #{Float.round(Enum.max(deltas), 2)}"
    )

    IO.puts(
      "    bump fired (>1 confirm pass): #{bumped}/#{n}  |  bump exhausted (best-effort under): #{exhausted}/#{n}"
    )

    h_verdict(regress, deltas)
  end

  defp h_verdict(regress, deltas) do
    worst = Enum.min(deltas)

    cond do
      regress == [] and worst >= -1.0 ->
        IO.puts(
          "  -> crop+confirm reproduces the full-frame target-hit decision; the confirm " <>
            "absorbs the crop residual (worst undershoot within ~1 pt).\n"
        )

      regress == [] ->
        IO.puts(
          "  -> no target-hit regressions; crop ships a few images further below where full " <>
            "would, but never crosses the target the full search cleared.\n"
        )

      true ->
        IO.puts(
          "  -> #{length(regress)} image(s) the full search hit but crop+confirm shipped " <>
            "best-effort under target — the bounded tail the docs describe (large/screen content).\n"
        )
    end
  end

  defp pct_int(_part, 0), do: 0
  defp pct_int(part, whole), do: round(part / whole * 100)

  defp write_part_h_csv(rows) do
    path = "/tmp/autoquality_bench_part_h.csv"

    head =
      "source,label,format,mp,crop_regime,full_hit,crop_hit,full_q,crop_q," <>
        "full_score,crop_score,score_delta,byte_delta,confirm_passes,bump_exhausted\n"

    body =
      Enum.map_join(rows, fn r ->
        "#{r.source},#{r.label},#{r.format},#{r.mp},#{r.crop_regime?},#{r.full_hit?}," <>
          "#{r.crop_hit?},#{r.full_q},#{r.crop_q},#{fmt_score(r.full_score)}," <>
          "#{fmt_score(r.crop_score)},#{Float.round(r.score_delta, 3)},#{r.byte_delta}," <>
          "#{r.confirm_passes},#{r.bump_exhausted?}\n"
      end)

    File.write!(path, head <> body)
    IO.puts("wrote #{path}")
  end

  # --- Part I: raising max_quality — under-target drop vs byte cost vs latency -

  # Candidate max_quality per format (first = shipped default). min_quality stays put.
  defp i_maxes(:avif), do: [65, 70, 75, 80]
  defp i_maxes(_format), do: [80, 85, 90, 95]
  defp i_default_max(:avif), do: 65
  defp i_default_max(_format), do: 80

  defp run_part_i(corpus_dir, fallback_files, cap, synth_mp) do
    IO.puts("\n== Part I — raising max_quality: under-target drop vs byte cost vs latency ==")

    IO.puts(
      "real lowest-satisfying search, full-frame scorer  target #{@g_target} band ≥#{@g_band}  "
    )

    IO.puts(
      "sweep jpeg/webp #{i_fmt_list(i_maxes(:jpeg))} avif #{i_fmt_list(i_maxes(:avif))} " <>
        "(first = shipped default)  ≤#{cap}/source\n"
    )

    sources = discover_sources(corpus_dir, fallback_files, cap, synth_mp)

    Enum.flat_map(sources, fn {sname, subjects} ->
      Enum.flat_map(subjects, &i_bench_subject(sname, &1))
    end)
  end

  defp i_bench_subject(source, {label, base}) do
    {ref_us, {:ok, ref}} = timed(fn -> Ssim2Metric.reference(base) end)

    Enum.flat_map(@g_formats, fn format ->
      i_bench_format(source, label, base, ref, ref_us, format)
    end)
  end

  # Sweep every candidate max over one shared per-(image, q) cache, so the overlapping
  # brackets reuse encodes (the whole sweep costs ≈ one widest-bracket search).
  defp i_bench_format(source, label, base, ref, ref_us, format) do
    {min_q, _} = g_bracket(format)
    {:ok, cache} = Agent.start_link(fn -> %{} end)
    id = %{source: source, label: label, format: format}

    try do
      score_of = fn q -> g_probe(cache, base, ref, format, q).score end

      Enum.map(i_maxes(format), fn max_q ->
        {chosen, probed} = g_full_core(min_q, max_q, score_of)
        _ = g_probe(cache, base, ref, format, chosen)
        i_row(id, max_q, chosen, probed, Agent.get(cache, & &1), ref_us)
      end)
    catch
      {:g_unsupported, ^format, _reason} ->
        IO.puts("  #{label}/#{format}: skipped (encode unsupported)")
        []
    after
      Agent.stop(cache)
    end
  end

  defp i_row(id, max_q, chosen, probed, cache, ref_us) do
    enc = Enum.uniq([chosen | probed])
    delivered = Map.fetch!(cache, chosen)

    %{
      source: id.source,
      label: id.label,
      format: id.format,
      max_q: max_q,
      chosen: chosen,
      score: delivered.score,
      hit?: delivered.score >= @g_target,
      bytes: delivered.bytes,
      probes: length(enc),
      metric_us: g_sum(cache, enc, :metric_us),
      total_us:
        g_sum(cache, enc, :encode_us) + g_sum(cache, enc, :decode_us) +
          g_sum(cache, enc, :metric_us) + ref_us
    }
  end

  defp findings_part_i([]), do: IO.puts("Part I — raising max_quality: no subjects processed\n")

  defp findings_part_i(rows) do
    IO.puts("Part I — raising max_quality (macro-average per format, vs shipped default cap):")

    IO.puts(
      "  Δ vs each image's own default-cap result; byte/latency cost is the price of the " <>
        "extra quality. hit = delivered full-frame score ≥ #{@g_target}.\n"
    )

    Enum.each(@g_formats, fn format -> findings_part_i_format(format, rows) end)
  end

  defp findings_part_i_format(format, rows) do
    fmt_rows = Enum.filter(rows, &(&1.format == format))

    if fmt_rows == [] do
      IO.puts("  #{format}: no data\n")
    else
      default = i_default_max(format)

      baseline =
        Map.new(Enum.filter(fmt_rows, &(&1.max_q == default)), &{{&1.source, &1.label}, &1})

      n = baseline |> map_size()
      {lo, _} = g_bracket(format)

      IO.puts("  #{format} (min #{lo}, default max #{default}, n=#{n} imgs):")

      header =
        "    " <>
          pad(["max_q", 7]) <>
          pad(["hit%", 7]) <>
          pad(["Δhit", 7]) <>
          pad(["Δbytes%", 9]) <>
          pad(["ΔkB", 8]) <>
          pad(["Δprobes", 9]) <>
          pad(["Δmetric_ms", 11])

      IO.puts(header)

      fmt_rows
      |> Enum.group_by(& &1.max_q)
      |> Enum.sort_by(&elem(&1, 0))
      |> Enum.each(fn {max_q, mrows} ->
        print_part_i_row(format, max_q, mrows, baseline, default)
      end)

      IO.puts("")
    end
  end

  defp print_part_i_row(_format, max_q, mrows, baseline, default) do
    n = length(mrows)
    hit_rate = Enum.count(mrows, & &1.hit?) / max(n, 1) * 100

    base_hit_rate =
      baseline
      |> Map.values()
      |> Enum.count(& &1.hit?)
      |> Kernel./(max(map_size(baseline), 1))
      |> Kernel.*(100)

    deltas = Enum.map(mrows, &i_delta(&1, baseline[{&1.source, &1.label}]))

    IO.puts(
      "    " <>
        pad([max_q, 7]) <>
        pad([Float.round(hit_rate, 0), 7]) <>
        pad([i_signed(hit_rate - base_hit_rate), 7]) <>
        pad([i_signed(median(Enum.map(deltas, & &1.bytes_pct))), 9]) <>
        pad([i_signed(avg(Enum.map(deltas, & &1.kb))), 8]) <>
        pad([i_signed(avg(Enum.map(deltas, & &1.probes))), 9]) <>
        pad([i_signed(avg(Enum.map(deltas, & &1.metric_ms))), 11]) <>
        if(max_q == default, do: " (default)", else: "")
    )
  end

  defp i_delta(row, base) do
    %{
      bytes_pct: if(base.bytes > 0, do: (row.bytes - base.bytes) / base.bytes * 100, else: 0.0),
      kb: (row.bytes - base.bytes) / 1024,
      probes: row.probes - base.probes,
      metric_ms: (row.metric_us - base.metric_us) / 1000
    }
  end

  defp i_signed(value) when value >= 0, do: "+#{Float.round(value / 1, 1)}"
  defp i_signed(value), do: "#{Float.round(value / 1, 1)}"

  # `[80, 85, 90, 95]` is a printable charlist, so plain inspect renders ~c"PUZ_".
  defp i_fmt_list(list), do: "[" <> Enum.join(list, ",") <> "]"

  defp write_part_i_csv(rows) do
    path = "/tmp/autoquality_bench_part_i.csv"
    head = "source,label,format,max_q,chosen,score,hit,bytes,probes,metric_us,total_us\n"

    body =
      Enum.map_join(rows, fn r ->
        "#{r.source},#{r.label},#{r.format},#{r.max_q},#{r.chosen},#{fmt_score(r.score)}," <>
          "#{r.hit?},#{r.bytes},#{r.probes},#{r.metric_us},#{r.total_us}\n"
      end)

    File.write!(path, head <> body)
    IO.puts("wrote #{path}")
  end

  # --- Part J: sweeping allowed_error — on-target rate vs byte cost ------------

  @j_allowed_errors [0, 0.5, 1.0, 1.5, 2.0]
  @j_default_ae 1.0

  defp run_part_j(corpus_dir, fallback_files, cap, synth_mp) do
    IO.puts("\n== Part J — sweeping allowed_error: on-target rate vs byte cost ==")
    IO.puts("real lowest-satisfying search, full-frame scorer  fixed target #{@g_target}  ")

    IO.puts(
      "sweep allowed_error #{i_fmt_list(@j_allowed_errors)} (default #{@j_default_ae})  " <>
        "shipped brackets  ≤#{cap}/source\n"
    )

    sources = discover_sources(corpus_dir, fallback_files, cap, synth_mp)

    Enum.flat_map(sources, fn {sname, subjects} ->
      Enum.flat_map(subjects, &j_bench_subject(sname, &1))
    end)
  end

  defp j_bench_subject(source, {label, base}) do
    {ref_us, {:ok, ref}} = timed(fn -> Ssim2Metric.reference(base) end)

    Enum.flat_map(@g_formats, fn format ->
      j_bench_format(source, label, base, ref, ref_us, format)
    end)
  end

  # Sweep every allowed_error over one shared per-(image, q) cache — the score is
  # band-independent, so the cache serves every candidate (only the accept band moves).
  defp j_bench_format(source, label, base, ref, ref_us, format) do
    {lo, hi} = g_bracket(format)
    {:ok, cache} = Agent.start_link(fn -> %{} end)
    id = %{source: source, label: label, format: format}

    try do
      score_of = fn q -> g_probe(cache, base, ref, format, q).score end

      Enum.map(@j_allowed_errors, fn ae ->
        {chosen, probed} = j_search(lo, hi, score_of, @g_target - ae)
        _ = g_probe(cache, base, ref, format, chosen)
        j_row(id, ae, chosen, probed, Agent.get(cache, & &1), ref_us)
      end)
    catch
      {:g_unsupported, ^format, _reason} ->
        IO.puts("  #{label}/#{format}: skipped (encode unsupported)")
        []
    after
      Agent.stop(cache)
    end
  end

  # Lowest q in [lo, hi] scoring ≥ band; ceiling when none clear (band-parameterized).
  defp j_search(lo, hi, score_of, band), do: do_j_lowest(lo, hi, score_of, hi, nil, [], band)

  defp do_j_lowest(lo, hi, _score_of, ceiling, best, probed, _band) when lo > hi,
    do: {best || ceiling, probed}

  defp do_j_lowest(lo, hi, score_of, ceiling, best, probed, band) do
    mid = div(lo + hi, 2)
    probed = [mid | probed]

    if score_of.(mid) >= band,
      do: do_j_lowest(lo, mid - 1, score_of, ceiling, mid, probed, band),
      else: do_j_lowest(mid + 1, hi, score_of, ceiling, best, probed, band)
  end

  defp j_row(id, ae, chosen, probed, cache, ref_us) do
    enc = Enum.uniq([chosen | probed])
    delivered = Map.fetch!(cache, chosen)

    %{
      source: id.source,
      label: id.label,
      format: id.format,
      allowed_error: ae,
      chosen: chosen,
      score: delivered.score,
      hit?: delivered.score >= @g_target,
      bytes: delivered.bytes,
      probes: length(enc),
      metric_us: g_sum(cache, enc, :metric_us),
      total_us:
        g_sum(cache, enc, :encode_us) + g_sum(cache, enc, :decode_us) +
          g_sum(cache, enc, :metric_us) + ref_us
    }
  end

  defp findings_part_j([]),
    do: IO.puts("Part J — sweeping allowed_error: no subjects processed\n")

  defp findings_part_j(rows) do
    IO.puts("Part J — sweeping allowed_error (macro-average per format, vs default ae=1):")

    IO.puts(
      "  fixed target #{@g_target}; tightening ae raises the band toward the target → more " <>
        "on-target, more bytes (a broad cost). hit = delivered score ≥ #{@g_target}.\n"
    )

    Enum.each(@g_formats, fn format -> findings_part_j_format(format, rows) end)
  end

  defp findings_part_j_format(format, rows) do
    fmt_rows = Enum.filter(rows, &(&1.format == format))

    if fmt_rows == [] do
      IO.puts("  #{format}: no data\n")
    else
      baseline =
        fmt_rows
        |> Enum.filter(&(&1.allowed_error == @j_default_ae))
        |> Map.new(&{{&1.source, &1.label}, &1})

      IO.puts(
        "  #{format} (bracket #{inspect(g_bracket(format))}, n=#{map_size(baseline)} imgs):"
      )

      header =
        "    " <>
          pad(["allowed_err", 12]) <>
          pad(["hit%", 7]) <>
          pad(["Δhit", 7]) <>
          pad(["med_score", 11]) <>
          pad(["Δbytes%", 9]) <>
          pad(["ΔkB", 8]) <>
          pad(["Δmetric_ms", 11])

      IO.puts(header)

      fmt_rows
      |> Enum.group_by(& &1.allowed_error)
      |> Enum.sort_by(&elem(&1, 0))
      |> Enum.each(fn {ae, arows} -> print_part_j_row(ae, arows, baseline) end)

      IO.puts("")
    end
  end

  defp print_part_j_row(ae, arows, baseline) do
    n = length(arows)
    hit_rate = Enum.count(arows, & &1.hit?) / max(n, 1) * 100

    base_hit =
      baseline
      |> Map.values()
      |> Enum.count(& &1.hit?)
      |> Kernel./(max(map_size(baseline), 1))
      |> Kernel.*(100)

    med_score = arows |> Enum.map(& &1.score) |> median()
    deltas = Enum.map(arows, &i_delta(&1, baseline[{&1.source, &1.label}]))

    IO.puts(
      "    " <>
        pad([ae, 12]) <>
        pad([Float.round(hit_rate, 0), 7]) <>
        pad([i_signed(hit_rate - base_hit), 7]) <>
        pad([Float.round(med_score, 2), 11]) <>
        pad([i_signed(median(Enum.map(deltas, & &1.bytes_pct))), 9]) <>
        pad([i_signed(avg(Enum.map(deltas, & &1.kb))), 8]) <>
        pad([i_signed(avg(Enum.map(deltas, & &1.metric_ms))), 11]) <>
        if(ae == @j_default_ae, do: " (default)", else: "")
    )
  end

  defp write_part_j_csv(rows) do
    path = "/tmp/autoquality_bench_part_j.csv"
    head = "source,label,format,allowed_error,chosen,score,hit,bytes,probes,metric_us,total_us\n"

    body =
      Enum.map_join(rows, fn r ->
        "#{r.source},#{r.label},#{r.format},#{r.allowed_error},#{r.chosen}," <>
          "#{fmt_score(r.score)},#{r.hit?},#{r.bytes},#{r.probes},#{r.metric_us},#{r.total_us}\n"
      end)

    File.write!(path, head <> body)
    IO.puts("wrote #{path}")
  end

  # --- Part K: confirm-skipped crop verdict, global offset sweep -------------

  # Default offset ladder. 0.22 is the shipped @crop_macro_offset; the rest probe up
  # toward the systematic residual the confirm exists to absorb (the timeout autopsy
  # image sat at ~2.2). Override with --offsets a,b,c.
  @k_offsets [0.0, 0.22, 0.5, 1.0, 1.5, 2.0, 2.5, 3.0]

  defp run_part_k(corpus_dir, fallback_files, cap, synth_mp, offsets) do
    crossover = CropScore.crossover_megapixels()
    IO.puts("\n== Part K — confirm-skipped crop verdict: global crop→full offset sweep ==")

    IO.puts(
      "ship the crop objective winner WITHOUT the full-frame confirm  target #{@g_target} band ≥#{@g_band}  "
    )

    IO.puts(
      "offsets #{inspect(offsets)}  K=#{@subsample_k} even  formats #{inspect(@g_formats)}  " <>
        ">#{crossover} MP cohort  ≤#{cap}/source\n"
    )

    sources = discover_sources(corpus_dir, fallback_files, cap, synth_mp)

    Enum.flat_map(sources, fn {sname, subjects} ->
      cohort = Enum.filter(subjects, fn {_l, base} -> mp_of(base) > crossover end)
      rows = Enum.flat_map(cohort, &k_bench_subject(sname, &1, offsets))

      IO.puts(
        "  #{String.pad_trailing(sname, 14)} #{length(subjects)} imgs, #{length(cohort)} crop-regime done"
      )

      rows
    end)
  end

  defp mp_of(base), do: Image.width(base) * Image.height(base) / 1_000_000

  defp k_bench_subject(source, {label, base}, offsets) do
    mp = Float.round(mp_of(base), 1)
    Enum.flat_map(@g_formats, fn format -> k_run(source, label, base, mp, format, offsets) end)
  end

  # The bracket ceiling is dimension-bound, not quality-bound: if max_quality encodes,
  # every lower q does too. One probe at the ceiling is a complete guard for the
  # formats whose pixel limits (e.g. webp/avif >16383 px) the large-image cohort trips.
  defp k_run(source, label, base, mp, format, offsets) do
    {_lo, hi} = g_bracket(format)

    case Encoder.encode_to_buffer(base, plain_resolved(format, hi), hi) do
      {:error, _reason} ->
        IO.puts("  #{label}/#{format}: skipped (encode unsupported)")
        []

      {:ok, _bytes} ->
        k_measure(source, label, base, mp, format, hi, offsets)
    end
  end

  defp k_measure(source, label, base, mp, format, hi, offsets) do
    {:ok, full_ref} = Ssim2Metric.reference(base)
    {:ok, cache} = Agent.start_link(fn -> %{enc: %{}, rev: %{}, data: %{}} end)

    encode_fun = partf_encode_fun(cache, base, format)
    qdata = partf_qdata_fun(cache, base, full_ref)

    funs = %{
      resolved: h_resolved(format),
      encode_fun: encode_fun,
      qdata: qdata,
      d_at: fn q ->
        {:ok, bytes} = encode_fun.(q)
        {qdata.(bytes), byte_size(bytes)}
      end,
      hi: hi
    }

    subj = %{source: source, label: label, format: format, mp: mp}
    base_ctx = k_baseline(subj, funs)
    rows = Enum.map(offsets, &k_offset_row(base_ctx, funs, &1))

    Agent.stop(cache)
    rows
  end

  # Production crop path: even-K16 estimate at the shipped offset + full-frame confirm
  # and bump. Establishes the byte/quality/target baseline each offset is measured
  # against, and the raw systematic residual (p10 − full at the pick) an offset covers.
  defp k_baseline(subj, funs) do
    {:ok, _b, bmeta} =
      EncodeSearch.search(funs.resolved.quality_search, nil,
        encode_fun: funs.encode_fun,
        score_fun: k_crop_score_fun(funs.qdata, @crop_macro_offset),
        confirm_fun: fn bytes -> funs.qdata.(bytes).full_score end,
        confirm_band: @g_band,
        confirm_max_quality: funs.hi,
        max_bump_passes: 2,
        scorer: :crop,
        scorer_tiles: @subsample_k,
        max_iterations: @max_iter + 3,
        telemetry_opts: []
      )

    {bd, bbytes} = funs.d_at.(bmeta.quality)

    Map.merge(subj, %{
      base_q: bmeta.quality,
      base_deliv: bd.full_score,
      base_bytes: bbytes,
      base_hit?: bd.full_score >= @g_target,
      base_passes: bmeta.confirm_passes,
      base_full_us: bd.full_us,
      base_resid: even_p10(bd) - bd.full_score
    })
  end

  defp k_offset_row(base_ctx, funs, offset) do
    {:ok, _v, vmeta} =
      EncodeSearch.search(funs.resolved.quality_search, nil,
        encode_fun: funs.encode_fun,
        score_fun: k_crop_score_fun(funs.qdata, offset),
        max_iterations: @max_iter,
        telemetry_opts: []
      )

    {d, bytes} = funs.d_at.(vmeta.quality)
    deliv = d.full_score

    Map.merge(base_ctx, %{
      offset: offset,
      q: vmeta.quality,
      deliv: deliv,
      deliv_err: deliv - @g_target,
      under?: deliv < @g_target,
      regress?: base_ctx.base_hit? and deliv < @g_target,
      bytes: bytes,
      byte_delta_pct: k_pct_delta(bytes, base_ctx.base_bytes)
    })
  end

  # Even-K16 crop estimate at the candidate offset — the production estimator with the
  # offset as the swept knob.
  defp k_crop_score_fun(qdata, offset), do: fn bytes -> even_p10(qdata.(bytes)) - offset end

  defp even_p10(d) do
    d.tiles
    |> TileSelection.select(@subsample_k, :even)
    |> Enum.map(& &1.score)
    |> Enum.sort()
    |> percentile(0.10)
  end

  defp k_pct_delta(_bytes, 0), do: 0.0
  defp k_pct_delta(bytes, base), do: Float.round((bytes - base) / base * 100, 1)

  defp findings_part_k([]) do
    IO.puts(
      "Part K — confirm-skipped crop verdict: no crop-regime (>#{CropScore.crossover_megapixels()} MP) " <>
        "subjects in this corpus — supply large photos or the synthetic anchor to populate the cohort.\n"
    )
  end

  defp findings_part_k(rows) do
    bases = Enum.uniq_by(rows, &{&1.source, &1.label, &1.format})
    n = length(bases)
    base_hit = Enum.count(bases, & &1.base_hit?)
    resid = bases |> Enum.map(& &1.base_resid) |> Enum.sort()
    confirm_ms = bases |> Enum.map(&(&1.base_full_us * max(&1.base_passes, 1))) |> avg() |> ms()

    IO.puts("Part K — confirm-skipped crop verdict, global crop→full offset sweep:")

    IO.puts(
      "  over #{n} crop-regime (subject×format) cases (>#{CropScore.crossover_megapixels()} MP), all formats:"
    )

    IO.puts(
      "    baseline crop+confirm on-target: #{base_hit}/#{n} (#{pct_int(base_hit, n)}%)  |  " <>
        "full-frame confirm dropped ≈ #{confirm_ms} ms/case (the prize)"
    )

    IO.puts(
      "    systematic residual (even-K16 p10 − full): median #{Float.round(median(resid), 2)}  " <>
        "p90 #{Float.round(percentile(resid, 0.90), 2)}  worst #{Float.round(List.last(resid), 2)}\n"
    )

    offsets = rows |> Enum.map(& &1.offset) |> Enum.uniq() |> Enum.sort()
    print_part_k_header()

    Enum.each(offsets, fn off -> print_part_k_row(off, Enum.filter(rows, &(&1.offset == off))) end)

    k_verdict(rows, offsets)
  end

  defp print_part_k_header do
    IO.puts(
      "    " <>
        pad(["offset", 8]) <>
        pad(["on-target", 11]) <>
        pad(["deliv_err", 11]) <>
        pad(["worst_under", 13]) <>
        pad(["Δbytes%", 9]) <>
        pad(["regress", 9])
    )
  end

  defp print_part_k_row(offset, g) do
    n = length(g)
    on = Enum.count(g, &(not &1.under?))
    errs = Enum.map(g, & &1.deliv_err)

    IO.puts(
      "    " <>
        pad([Float.round(offset, 2), 8]) <>
        pad(["#{on}/#{n} (#{pct_int(on, n)}%)", 11]) <>
        pad([Float.round(median(errs), 2), 11]) <>
        pad([Float.round(Enum.min(errs), 2), 13]) <>
        pad([Float.round(median(Enum.map(g, & &1.byte_delta_pct)), 1), 9]) <>
        pad([Enum.count(g, & &1.regress?), 9]) <>
        if(offset == @crop_macro_offset, do: " (shipped)", else: "")
    )
  end

  # The decision the part exists to make is "is it safe to drop the confirm?" — that
  # is regressions vs the crop+confirm baseline, NOT an absolute band, because the deep
  # undershooters are bracket-ceiling-bound (the baseline misses them too; a Part I
  # lever, not a confirm-skip artifact). Lead with the regression count, then suggest
  # the offset near the p90 systematic residual as the source-agnostic operating point.
  defp k_verdict(rows, offsets) do
    by_off = fn off -> Enum.filter(rows, &(&1.offset == off)) end

    max_regress =
      offsets |> Enum.map(fn off -> Enum.count(by_off.(off), & &1.regress?) end) |> Enum.max()

    resid =
      rows |> Enum.uniq_by(&{&1.source, &1.label, &1.format}) |> Enum.map(& &1.base_resid)

    p90 = Float.round(percentile(Enum.sort(resid), 0.90), 2)

    IO.puts("\n  -> #{k_safety_line(max_regress)}")

    IO.puts(
      "     set the global offset near the p90 systematic residual (#{p90}) to cover the " <>
        "over-prediction tail; with the residual median ~0 here this barely moves bytes."
    )

    IO.puts(
      "     the deep undershooters are bracket-ceiling-bound (can't reach #{@g_target} at " <>
        "max_quality) — a Part I lever (raise the cap), not something the confirm could fix.\n"
    )
  end

  defp k_safety_line(0),
    do:
      "0 target-hit regressions vs crop+confirm at every swept offset: dropping the confirm " <>
        "(the ~1 s/case prize) re-confirms only hits and ceiling-bound misses here — safe on this corpus."

  defp k_safety_line(max_regress),
    do:
      "#{max_regress} image(s) the baseline hit but the confirm-skipped verdict missed — those " <>
        "rely on the confirm (per-content correction is ruled out), so dropping it is not free."

  defp write_part_k_csv(rows) do
    path = "/tmp/autoquality_bench_part_k.csv"

    head =
      "source,label,format,mp,offset,q,deliv,deliv_err,under,regress,bytes," <>
        "byte_delta_pct,base_q,base_deliv,base_bytes,base_hit,base_resid\n"

    body =
      Enum.map_join(rows, fn r ->
        "#{r.source},#{r.label},#{r.format},#{r.mp},#{r.offset},#{r.q}," <>
          "#{fmt_score(r.deliv)},#{Float.round(r.deliv_err, 3)},#{r.under?},#{r.regress?}," <>
          "#{r.bytes},#{r.byte_delta_pct},#{r.base_q},#{fmt_score(r.base_deliv)}," <>
          "#{r.base_bytes},#{r.base_hit?},#{Float.round(r.base_resid, 3)}\n"
      end)

    File.write!(path, head <> body)
    IO.puts("wrote #{path}")
  end

  # --- Part L: crop operating-point sweep (K × tile grid) --------------------

  # #359 (post-#369): K and tile size shipped as fixed constants (K=16 / 512px,
  # Part E) at a single never-swept operating point. Since #369 dropped the
  # full-frame confirm above the crossover, K/tile + the confirm-skipped offset
  # are the ONLY accuracy levers there, so this sweep is a correctness lever, not
  # just efficiency. Part L sweeps a K × tile grid and, per combo, reports the
  # three decision axes the issue asks for:
  #
  #   accuracy — systematic residual (even-K p10 @ tile − full-frame score) at the
  #              production-delivered pick: median/p90/worst. The p90 IS the offset
  #              the combo would need (mirrors the Part K recalibration rule), so
  #              the sweep and the offset recalibration are reported as one unit.
  #   cost     — MP-scored = K·tile² (flat per-combo pixel budget, size-independent)
  #              and the implied crossover (where a full frame costs that budget).
  #   miss     — the decisive post-#369 metric: target-hit REGRESSIONS vs the
  #              crop+confirm baseline when the confirm is skipped. Probed at
  #              offset 0 (the most aggressive estimate — Part K showed regressions
  #              are bracket-ceiling-bound, hence ≈offset-independent), so a 0 here
  #              means the combo is safe at any offset ≥ 0.
  #
  # The baseline (production crop+confirm at the shipped K=16/512 operating point)
  # is computed once per case and shared across combos; tile coverage is memoized
  # per (tile, q) so the K axis is free (re-select from full coverage) and only the
  # tile axis re-scores. Crop-regime cohort only (>crossover MP), all g_formats.
  @l_ks [8, 16, 32]
  @l_tiles [384, 512, 768]

  # The shipped operating point (Part E) and the production confirm-skipped offset
  # (mirrors `ImagePipe.Output.EncodeSearch`'s `@crop_confirm_skipped_offset`). The
  # verdict measures every swept combo against these.
  @l_ship_k 16
  @l_ship_tile 512
  @l_ship_offset 2.4

  # Tile-size floor for the knee pick. SSIMULACRA2's multiscale pyramid downsamples
  # ~5 octaves, so a 512px tile is already ~16px at the coarsest scale; below that the
  # metric loses its low-frequency band and the estimate gets unreliable. The grid
  # confirms it — every tile<512 combo that over-predicts regresses (a tile<512 combo
  # that *escapes* does so only by an accidentally-conservative residual, not safety),
  # so the cost knee is constrained to tile >= 512.
  @l_tile_floor 512

  defp run_part_l(corpus_dir, fallback_files, cap, synth_mp, ks, tiles) do
    crossover = CropScore.crossover_megapixels()
    combos = for t <- tiles, k <- ks, do: {t, k}

    IO.puts("\n== Part L — crop operating-point sweep: K × tile grid (#359) ==")

    IO.puts(
      "confirm-skipped (offset 0 safety probe) vs crop+confirm baseline @ K=#{@l_ship_k}/#{@l_ship_tile}  " <>
        "target #{@g_target} band ≥#{@g_band}  "
    )

    IO.puts(
      "K∈#{inspect(ks)} × tile∈#{inspect(tiles)} (#{length(combos)} combos)  " <>
        "formats #{inspect(@g_formats)}  >#{crossover} MP cohort  ≤#{cap}/source\n"
    )

    sources = discover_sources(corpus_dir, fallback_files, cap, synth_mp)

    Enum.flat_map(sources, fn {sname, subjects} ->
      cohort = Enum.filter(subjects, fn {_l, base} -> mp_of(base) > crossover end)
      rows = Enum.flat_map(cohort, &l_case_rows(sname, &1, combos))

      IO.puts(
        "  #{String.pad_trailing(sname, 14)} #{length(subjects)} imgs, #{length(cohort)} crop-regime done"
      )

      rows
    end)
  end

  defp l_case_rows(source, {label, base}, combos) do
    mp = Float.round(mp_of(base), 1)

    Enum.flat_map(@g_formats, fn format ->
      l_case_format(source, label, base, mp, format, combos)
    end)
  end

  defp l_case_format(source, label, base, mp, format, combos) do
    {_lo, hi} = g_bracket(format)

    case Encoder.encode_to_buffer(base, plain_resolved(format, hi), hi) do
      {:error, _reason} ->
        IO.puts("  #{label}/#{format}: skipped (encode unsupported)")
        []

      {:ok, _bytes} ->
        l_measure(source, label, base, mp, format, hi, combos)
    end
  end

  defp l_measure(source, label, base, mp, format, hi, combos) do
    {:ok, full_ref} = Ssim2Metric.reference(base)
    {:ok, cache} = Agent.start_link(fn -> %{enc: %{}, rev: %{}, full: %{}, cov: %{}} end)

    funs = %{
      resolved: h_resolved(format),
      encode_fun: partf_encode_fun(cache, base, format),
      full_at: l_full_fun(cache, full_ref),
      cov_at: l_cov_fun(cache, base),
      hi: hi
    }

    subj = %{source: source, label: label, format: format, mp: mp}
    base_ctx = l_baseline(funs)

    rows =
      Enum.map(combos, fn {t, k} ->
        Map.merge(Map.merge(subj, base_ctx), l_combo(funs, base_ctx, t, k))
      end)

    Agent.stop(cache)
    rows
  end

  # Full-frame ssim2 score (+ wall-clock) of a candidate, memoized by quality. Like
  # the partf qdata, the heavy compute runs OUTSIDE the agent so the call never trips
  # the call timeout.
  defp l_full_fun(cache, full_ref) do
    fn bytes -> l_fetch_full(cache, full_ref, bytes) end
  end

  defp l_fetch_full(cache, full_ref, bytes) do
    q = Agent.get(cache, &Map.fetch!(&1.rev, bytes))

    case Agent.get(cache, &Map.get(&1.full, q)) do
      nil ->
        {:ok, cand} = Image.from_binary(bytes)
        {us, {:ok, s}} = timed(fn -> Ssim2Metric.score(full_ref, cand) end)
        v = %{score: s, us: us}
        Agent.update(cache, fn st -> %{st | full: Map.put(st.full, q, v)} end)
        v

      v ->
        v
    end
  end

  # Full tile-coverage scores (one ssim2 per tile) at tile size `t`, memoized by
  # {t, q}. The K axis re-selects from this list, so only the tile axis re-scores.
  defp l_cov_fun(cache, base) do
    fn t, bytes -> l_fetch_cov(cache, base, t, bytes) end
  end

  defp l_fetch_cov(cache, base, t, bytes) do
    q = Agent.get(cache, &Map.fetch!(&1.rev, bytes))
    key = {t, q}

    case Agent.get(cache, &Map.get(&1.cov, key)) do
      nil ->
        scores = l_coverage(base, bytes, t)
        Agent.update(cache, fn st -> %{st | cov: Map.put(st.cov, key, scores)} end)
        scores

      scores ->
        scores
    end
  end

  defp l_coverage(base, bytes, t) do
    {:ok, cand} = Image.from_binary(bytes)

    Image.width(base)
    |> tile_coords(Image.height(base), t)
    |> Enum.map(fn {x, y, w, h} ->
      {:ok, bt} = Operation.extract_area(base, x, y, w, h)
      {:ok, ct} = Operation.extract_area(cand, x, y, w, h)
      {:ok, ref} = Ssim2Metric.reference(bt)
      {:ok, s} = Ssim2Metric.score(ref, ct)
      %{score: s}
    end)
  end

  # even-K p10 of a coverage-score list (the shipped Part E estimator at arbitrary K).
  defp l_even_p10(scores, k) do
    scores
    |> TileSelection.select(k, :even)
    |> Enum.map(& &1.score)
    |> Enum.sort()
    |> percentile(0.10)
  end

  # full-coverage p10 — the estimate with no sub-sampling; sub_pen measures it against.
  defp l_cov_p10(scores), do: scores |> Enum.map(& &1.score) |> Enum.sort() |> percentile(0.10)

  # Production crop path at the shipped operating point: even-K16/512 + offset +
  # full-frame confirm/bump. The fixed reference each combo's confirm-skipped
  # verdict is measured against. Shared across combos for the case.
  defp l_baseline(funs) do
    {:ok, _b, m} =
      EncodeSearch.search(funs.resolved.quality_search, nil,
        encode_fun: funs.encode_fun,
        score_fun: fn bytes ->
          l_even_p10(funs.cov_at.(@l_ship_tile, bytes), @l_ship_k) - @crop_macro_offset
        end,
        confirm_fun: fn bytes -> funs.full_at.(bytes).score end,
        confirm_band: @g_band,
        confirm_max_quality: funs.hi,
        max_bump_passes: 2,
        scorer: :crop,
        scorer_tiles: @l_ship_k,
        max_iterations: @max_iter + 3,
        telemetry_opts: []
      )

    {:ok, bytes} = funs.encode_fun.(m.quality)
    full = funs.full_at.(bytes)

    %{
      base_q: m.quality,
      base_full: full.score,
      base_hit?: full.score >= @g_target,
      base_bytes: byte_size(bytes),
      base_full_us: full.us,
      base_passes: m.confirm_passes
    }
  end

  defp l_combo(funs, base_ctx, t, k) do
    {:ok, base_bytes} = funs.encode_fun.(base_ctx.base_q)
    cov = funs.cov_at.(t, base_bytes)
    even = l_even_p10(cov, k)

    {:ok, _v, vm} =
      EncodeSearch.search(funs.resolved.quality_search, nil,
        encode_fun: funs.encode_fun,
        score_fun: fn bytes -> l_even_p10(funs.cov_at.(t, bytes), k) end,
        max_iterations: @max_iter,
        telemetry_opts: []
      )

    {:ok, vbytes} = funs.encode_fun.(vm.quality)
    deliv = funs.full_at.(vbytes).score

    %{
      tile: t,
      k: k,
      mp_scored: Float.round(k * t * t / 1_000_000, 2),
      residual: even - base_ctx.base_full,
      sub_pen: even - l_cov_p10(cov),
      q: vm.quality,
      deliv: deliv,
      regress?: base_ctx.base_hit? and deliv < @g_target,
      bytes: byte_size(vbytes),
      byte_delta_pct: k_pct_delta(byte_size(vbytes), base_ctx.base_bytes)
    }
  end

  defp findings_part_l([]) do
    IO.puts(
      "Part L — crop operating-point sweep: no crop-regime (>#{CropScore.crossover_megapixels()} MP) " <>
        "subjects in this corpus — supply large photos or the synthetic anchor to populate the cohort.\n"
    )
  end

  defp findings_part_l(rows) do
    cases = Enum.uniq_by(rows, &{&1.source, &1.label, &1.format})
    n = length(cases)
    base_hit = Enum.count(cases, & &1.base_hit?)
    confirm_ms = cases |> Enum.map(&(&1.base_full_us * max(&1.base_passes, 1))) |> avg() |> ms()

    IO.puts(
      "Part L — crop operating-point sweep (K × tile), confirm-skipped vs crop+confirm baseline:"
    )

    IO.puts(
      "  over #{n} crop-regime (subject×format) cases (>#{CropScore.crossover_megapixels()} MP), all formats:"
    )

    IO.puts(
      "    baseline crop+confirm on-target: #{base_hit}/#{n} (#{pct_int(base_hit, n)}%)  |  " <>
        "full-frame confirm dropped ≈ #{confirm_ms} ms/case (the prize)\n"
    )

    combos =
      rows
      |> Enum.group_by(&{&1.tile, &1.k})
      |> Enum.map(fn {{t, k}, g} -> l_combo_agg(t, k, g) end)
      |> Enum.sort_by(& &1.mp_scored)

    print_part_l_header()
    Enum.each(combos, &print_part_l_row/1)
    l_verdict(combos)
  end

  defp l_combo_agg(t, k, g) do
    resid = g |> Enum.map(& &1.residual) |> Enum.sort()

    # The offset must cover the residual of the population it can actually protect:
    # baseline-HIT cases (an over-predicting estimate ships them below target). The
    # ALL-cases p90 is dominated by ceiling-bound screen-content misses the offset
    # can't rescue anyway (a Part I cap lever, not a confirm-skip concern) — pooling
    # those in would over-state the needed offset. Both are reported (p90all vs
    # p90hit) so that inflation is visible; rec.off is the worst-source p90hit.
    hits = Enum.filter(g, & &1.base_hit?)
    {_ws_all, p90_all} = l_worst_source_p90(g)
    {worst_src, rec_off} = l_worst_source_p90(hits)

    %{
      tile: t,
      k: k,
      mp_scored: hd(g).mp_scored,
      resid_med: median(resid),
      p90_all: p90_all,
      rec_off: rec_off,
      worst_src: worst_src,
      sub_pen: g |> Enum.map(& &1.sub_pen) |> avg(),
      regress: Enum.count(g, & &1.regress?),
      n: length(g)
    }
  end

  # Per-source residual p90, then the WORST source — a global production offset must
  # cover the hardest content, and pooling lets the easy/abundant sources mask a hard
  # one (screen content tracks far looser than photos).
  defp l_worst_source_p90([]), do: {"none", 0.0}

  defp l_worst_source_p90(rows) do
    rows
    |> Enum.group_by(& &1.source)
    |> Enum.map(fn {s, rs} -> {s, percentile(Enum.sort(Enum.map(rs, & &1.residual)), 0.90)} end)
    |> Enum.max_by(&elem(&1, 1))
  end

  defp print_part_l_header do
    IO.puts(
      "    " <>
        pad(["K/tile", 10]) <>
        pad(["MPscore", 9]) <>
        pad(["xover", 7]) <>
        pad(["resid med", 11]) <>
        pad(["p90all*", 9]) <>
        pad(["p90hit*", 9]) <>
        pad(["subPen", 8]) <>
        pad(["regress", 9]) <>
        pad(["binds", 9])
    )
  end

  defp print_part_l_row(c) do
    shipped? = c.tile == @l_ship_tile and c.k == @l_ship_k

    IO.puts(
      "    " <>
        pad(["#{c.k}/#{c.tile}", 10]) <>
        pad([c.mp_scored, 9]) <>
        pad([l_crossover(c.mp_scored), 7]) <>
        pad([Float.round(c.resid_med, 2), 11]) <>
        pad([Float.round(c.p90_all, 2), 9]) <>
        pad([Float.round(c.rec_off, 2), 9]) <>
        pad([Float.round(c.sub_pen, 2), 8]) <>
        pad(["#{c.regress}/#{c.n}", 9]) <>
        pad([c.worst_src, 9]) <>
        if(shipped?, do: " (shipped)", else: "")
    )
  end

  # The MP at which a full-frame score costs the combo's flat budget — i.e. where
  # crop scoring starts to win. Scales with MPscore; the shipped K16/512 (4.2 MP)
  # sits at the current ~6 MP crossover.
  defp l_crossover(mp_scored), do: Float.round(mp_scored / 4.2 * 6, 1)

  # The decision: the Pareto knee is the cheapest combo (lowest MPscore) that is both
  # SAFE (0 confirm-skipped regressions) and whose worst-source baseline-hit p90
  # residual (rec.off = p90hit) fits under the shipped confirm-skipped offset — i.e.
  # needs no offset bump to cover the hardest *protectable* content.
  defp l_verdict(combos) do
    safe =
      Enum.filter(
        combos,
        &(&1.regress == 0 and &1.rec_off <= @l_ship_offset and &1.tile >= @l_tile_floor)
      )

    knee = if safe == [], do: nil, else: Enum.min_by(safe, & &1.mp_scored)
    shipped = Enum.find(combos, &(&1.tile == @l_ship_tile and &1.k == @l_ship_k))
    max_regress = combos |> Enum.map(& &1.regress) |> Enum.max()

    IO.puts("\n  -> #{l_safety_line(max_regress)}")
    IO.puts("     #{l_shipped_line(shipped)}")

    cond do
      knee == nil ->
        IO.puts(
          "     no swept combo is both regression-free and covers its worst source within the shipped " <>
            "offset (#{@l_ship_offset}) — keep K=#{@l_ship_k}/#{@l_ship_tile} and raise the offset via --part k."
        )

      knee.tile == @l_ship_tile and knee.k == @l_ship_k ->
        IO.puts(
          "     the shipped K=#{@l_ship_k}/#{@l_ship_tile} (#{shipped.mp_scored} MP scored) IS the knee: " <>
            "no cheaper combo stays regression-free within the #{@l_ship_offset} offset — confirmed, not retuned."
        )

      true ->
        IO.puts(
          "     cost knee = K=#{knee.k}/#{knee.tile} (#{knee.mp_scored} MP scored, p90hit #{Float.round(knee.rec_off, 2)} " <>
            "on #{knee.worst_src}) — #{l_knee_delta(knee, shipped)} vs shipped K=#{@l_ship_k}/#{@l_ship_tile}, " <>
            "0 regressions, within the #{@l_ship_offset} offset. Retune + re-derive the offset via --part k --k #{knee.k}."
        )
    end

    IO.puts(
      "     p90all* = worst-source p90 over ALL cases; p90hit* (=rec.off) restricts to baseline-hit cases " <>
        "(what the offset protects) — the gap is the ceiling-bound tail. tile<512 is the multiscale floor.\n"
    )
  end

  # Whether the shipped operating point's current offset still covers its worst
  # protectable (baseline-hit) source.
  defp l_shipped_line(nil), do: "shipped K=#{@l_ship_k}/#{@l_ship_tile} not in this grid."

  defp l_shipped_line(s) when s.rec_off > @l_ship_offset,
    do:
      "shipped K=#{@l_ship_k}/#{@l_ship_tile}: worst-source baseline-hit p90 residual #{Float.round(s.rec_off, 2)} " <>
        "(#{s.worst_src}) EXCEEDS the #{@l_ship_offset} offset — raise the offset or grow the tile."

  defp l_shipped_line(s),
    do:
      "shipped K=#{@l_ship_k}/#{@l_ship_tile}: worst-source baseline-hit p90 residual #{Float.round(s.rec_off, 2)} " <>
        "(#{s.worst_src}) is within the #{@l_ship_offset} offset — adequately offset."

  defp l_knee_delta(knee, nil), do: "#{Float.round(knee.mp_scored, 1)} MP scored"

  defp l_knee_delta(knee, shipped) do
    pct = round((1 - knee.mp_scored / shipped.mp_scored) * 100)

    cond do
      pct > 0 -> "#{pct}% cheaper metric"
      pct < 0 -> "#{-pct}% more metric"
      true -> "same metric cost"
    end
  end

  defp l_safety_line(0),
    do:
      "0 target-hit regressions at any swept K/tile (offset 0, the aggressive probe): the grid is " <>
        "safe — the operating point is a pure cost choice, accuracy is not at risk above the crossover."

  defp l_safety_line(max_regress),
    do:
      "#{max_regress} image(s) the baseline hit but a confirm-skipped combo missed — some K/tile " <>
        "combos are NOT safe above the crossover; the safe set bounds how cheap the operating point can go."

  defp write_part_l_csv(rows) do
    path = "/tmp/autoquality_bench_part_l.csv"

    head =
      "source,label,format,mp,tile,k,mp_scored,residual,sub_pen,q,deliv,regress," <>
        "bytes,byte_delta_pct,base_q,base_full,base_bytes,base_hit\n"

    body =
      Enum.map_join(rows, fn r ->
        "#{r.source},#{r.label},#{r.format},#{r.mp},#{r.tile},#{r.k},#{r.mp_scored}," <>
          "#{Float.round(r.residual, 3)},#{Float.round(r.sub_pen, 3)},#{r.q}," <>
          "#{fmt_score(r.deliv)},#{r.regress?},#{r.bytes},#{r.byte_delta_pct}," <>
          "#{r.base_q},#{fmt_score(r.base_full)},#{r.base_bytes},#{r.base_hit?}\n"
      end)

    File.write!(path, head <> body)
    IO.puts("wrote #{path}")
  end

  # --- Part M: content-classifier feasibility (#359 Part L follow-up) --------
  #
  # The Part L follow-up found the confirm-skipped residual is FORMAT × CONTENT
  # dependent: above the crossover, AVIF on dense text overshoots full-frame by ~6
  # (so the search ships ~3.7 ssim2 under target), while AVIF photos need ~1. A flat
  # offset raise over-inflates every AVIF photo to rescue a content slice; the better
  # shape is a {format, content-class} → offset policy driven by a cheap classifier.
  #
  # Part M is FEASIBILITY, not pipeline: it asks only whether ≤5 cheap libvips
  # features separate :photo from :screen_or_other cleanly enough to key that policy.
  # It builds no classifier module and no Plan.Output table — that waits on these
  # numbers. Two verdicts:
  #
  #   (a) separation — PRIMARY, over the full labeled cohort (features computed on a
  #       fixed-size downsample, so they are MP-independent; sub-crossover photos count
  #       too). Per feature: photo/screen medians, a threshold-free AUC and Cohen's d,
  #       and the user's AND-rule (photo iff ALL photo-conditions hold; else the safe
  #       fallback :screen_or_other) as a combined classifier. Each feature's
  #       photo-condition is auto-oriented from the observed class medians, so the rule
  #       degrades only on genuine overlap, not on a mis-guessed direction.
  #   (b) residual confirmation — SECONDARY, >6 MP only (where the residual exists).
  #       Re-confirms the ~6 AVIF×screen vs ~1 AVIF×photo magnitude on the enriched
  #       cohort and Spearman-correlates each feature with the AVIF residual. Reuses
  #       Part L's shipped-combo baseline; the photo side above the crossover is thin
  #       (only `large`), so this is confirmatory, not the gate. It also runs the
  #       tile-dispersion probe — whether the crop scorer's OWN per-tile score spread
  #       predicts the overshoot, which would be a near-free *sliding* offset with no
  #       classifier at all (the alternative to the binary {format,class} policy).
  #
  # `--downsample N` overrides the feature downsample (default 1024 px); the
  # separation verdict is near-invariant from 256–1024 px (`palette_ent` is a histogram
  # measure), so a smaller downsample is cheaper at no safety cost — the residual is
  # downsample-independent, so a size sweep only moves the (a) numbers.
  #
  # Run: `--part m --corpus $(mix autoquality.corpus --path)` (materialize the screen
  # half first with `mix autoquality.corpus` + `mix autoquality.corpus.capture`).

  @m_photo_sources ~w(large clic clic_holdout cid22 gb82)
  @m_screen_sources ~w(web_sc grafana_sc gb82_sc qoi_web)
  @m_flat_thresh 8.0
  @m_hard_thresh 64.0
  @m_strong_sep 0.75

  # 3×3 Sobel directional kernels: axis (0°/90°) vs diagonal (45°/135°).
  @m_k0 [[1.0, 0.0, -1.0], [2.0, 0.0, -2.0], [1.0, 0.0, -1.0]]
  @m_k90 [[1.0, 2.0, 1.0], [0.0, 0.0, 0.0], [-1.0, -2.0, -1.0]]
  @m_k45 [[0.0, -1.0, -2.0], [1.0, 0.0, -1.0], [2.0, 1.0, 0.0]]
  @m_k135 [[-2.0, -1.0, 0.0], [-1.0, 0.0, 1.0], [0.0, 1.0, 2.0]]

  # Features in report order, with the hypothesised screen direction (for reference
  # against the data-observed direction — see the axis_aligned finding in the doc).
  @m_features [
    {:flat_frac, "flat_frac", :high},
    {:hard_edge_frac, "hard_edge", :high},
    {:palette_entropy, "palette_ent", :low},
    {:natural_variation, "nat_var", :low},
    {:axis_aligned, "axis_align", :high}
  ]

  # Dispersion stats over the residual's own even-K tile scores — candidate near-free
  # sliding-offset signals (does the crop scorer's per-tile spread predict the overshoot?).
  @m_dispersion_stats [
    {:tile_std, "tile_std"},
    {:tile_med_p10, "med−p10"},
    {:tile_mean_p10, "mean−p10"},
    {:tile_p10_min, "p10−min"},
    {:tile_iqr, "iqr"}
  ]

  defp run_part_m(corpus_dir, fallback_files, cap, synth_mp, downsample) do
    IO.puts("\n== Part M — content-classifier feasibility (#359) ==")

    IO.puts(
      "downsample #{downsample}px long-edge  classes :photo / :screen_or_other  ≤#{cap}/source"
    )

    IO.puts(
      "features: flat_frac, hard_edge, palette_ent, nat_var, axis_align  " <>
        "(feat_us = classifier marginal cost, excludes decode)\n"
    )

    sources = discover_sources(corpus_dir, fallback_files, cap, synth_mp)
    feat_rows = Enum.flat_map(sources, &m_source_rows(&1, downsample))
    resid_rows = m_residual_rows(sources)

    m_report_separation(feat_rows, downsample)
    m_report_residual(feat_rows, resid_rows)

    %{feat: feat_rows, resid: resid_rows}
  end

  defp m_source_rows({sname, subjects}, downsample) do
    case m_class_of(sname) do
      nil ->
        IO.puts(
          "  #{String.pad_trailing(sname, 14)} #{length(subjects)} imgs (unlabeled — skipped)"
        )

        []

      class ->
        rows = Enum.map(subjects, &m_feature_row(sname, class, &1, downsample))
        med_us = rows |> Enum.map(& &1.feat_us) |> median() |> round()

        IO.puts(
          "  #{String.pad_trailing(sname, 14)} #{length(rows)} imgs  " <>
            "#{String.pad_trailing(to_string(class), 16)} #{med_us}µs/img"
        )

        rows
    end
  end

  defp m_class_of(source) do
    cond do
      source in @m_photo_sources -> :photo
      source in @m_screen_sources -> :screen_or_other
      true -> nil
    end
  end

  # `base` is already a decoded, in-memory sRGB image (base_image_at), so the timed
  # region — downsample + grayscale + the feature convolutions — is the classifier's
  # MARGINAL cost over an already-decoded request, not the source decode.
  defp m_feature_row(source, class, {label, base}, downsample) do
    {us, feats} = timed(fn -> m_features(base, downsample) end)

    Map.merge(
      %{source: source, label: label, class: class, mp: Float.round(mp_of(base), 1), feat_us: us},
      feats
    )
  end

  defp m_features(base, downsample) do
    scale = min(1.0, downsample / max(Image.width(base), Image.height(base)))
    {:ok, small} = Operation.resize(base, scale)
    {:ok, g8lazy} = Operation.colourspace(small, :VIPS_INTERPRETATION_B_W)
    # Pull the downsample + grayscale once into RAM so the convolutions and the
    # histogram all read the ~1 MP buffer rather than re-evaluating the resize over
    # the full-res input per terminal consumer.
    {:ok, g8} = VixImage.copy_memory(g8lazy)
    {:ok, gf} = Operation.cast(g8, :VIPS_FORMAT_FLOAT)

    c0 = m_conv(gf, @m_k0)
    c90 = m_conv(gf, @m_k90)
    c45 = m_conv(gf, @m_k45)
    c135 = m_conv(gf, @m_k135)

    {:ok, sq0} = Operation.multiply(c0, c0)
    {:ok, sq90} = Operation.multiply(c90, c90)
    {:ok, sumsq} = Operation.add(sq0, sq90)
    {:ok, mag} = Operation.math2_const(sumsq, :VIPS_OPERATION_MATH2_POW, [0.5])

    flat = m_frac(mag, :VIPS_OPERATION_RELATIONAL_LESS, @m_flat_thresh)
    hard = m_frac(mag, :VIPS_OPERATION_RELATIONAL_MORE, @m_hard_thresh)

    {:ok, hist} = Operation.hist_find(g8)
    {:ok, ent} = Operation.hist_entropy(hist)

    %{
      flat_frac: flat,
      hard_edge_frac: hard,
      natural_variation: max(0.0, 1.0 - flat - hard),
      palette_entropy: ent / 8.0,
      axis_aligned: (m_abs_mean(c0) + m_abs_mean(c90)) / (m_abs_mean(c45) + m_abs_mean(c135))
    }
  end

  defp m_conv(gf, kernel) do
    {:ok, mask} = VixImage.new_from_list(kernel)
    {:ok, c} = Operation.conv(gf, mask)
    c
  end

  # Fraction of pixels passing a relational test on the gradient magnitude. The
  # boolean image is 255 where true, so its mean / 255 is the fraction.
  defp m_frac(mag, op, t) do
    {:ok, b} = Operation.relational_const(mag, op, [t])
    {:ok, a} = Operation.avg(b)
    a / 255.0
  end

  defp m_abs_mean(img) do
    {:ok, a} = Operation.abs(img)
    {:ok, m} = Operation.avg(a)
    m
  end

  # --- Part M (a): separation reporting --------------------------------------

  defp m_report_separation([], _downsample),
    do: IO.puts("\nPart M (a): no labeled images in cohort.")

  defp m_report_separation(rows, downsample) do
    photos = Enum.filter(rows, &(&1.class == :photo))
    screens = Enum.filter(rows, &(&1.class == :screen_or_other))

    IO.puts(
      "\n  (a) class separation — #{length(photos)} photo / #{length(screens)} screen images"
    )

    IO.puts(
      "  " <>
        pad(["feature", 13]) <>
        pad(["photo med", 11]) <>
        pad(["screen med", 12]) <>
        pad(["AUC↑scr", 9]) <>
        pad(["cohen-d", 9]) <>
        pad(["θ", 8]) <> pad(["sep", 7]) <> "errs@θ (scr→photo)"
    )

    stats = Enum.map(@m_features, &m_feature_stat(&1, photos, screens))

    m_rule_report("user AND-rule (all 5 features)", rows, stats)

    strong = Enum.filter(stats, &(&1.sep >= @m_strong_sep))

    case strong do
      [] ->
        IO.puts(
          "\n  no feature reaches sep ≥ #{@m_strong_sep} — classifier infeasible on this cohort."
        )

      _ ->
        names = Enum.map_join(strong, ",", & &1.name)
        m_rule_report("strong-features AND-rule (sep≥#{@m_strong_sep}: #{names})", rows, strong)
    end

    # The exact rule production ships (#380): :photo iff palette_ent ≥ θ AND nat_var ≥ θ
    # at the FROZEN `ContentClassifier` thresholds (not the Youden θ above — those leak
    # 1 screen→photo on this cohort). screen→photo must be 0.
    m_production_rule_report(rows, downsample)
  end

  # Evaluate the shipped rule at `ContentClassifier`'s own frozen thresholds (no
  # hand-synced duplicate) over the labeled cohort; the screen→photo count is the
  # safety evidence for the pair. The thresholds are calibrated for the 512 px
  # downsample, so the safety verdict is only printed (and only valid) at 512 — a
  # ≠512 run shows the rule but withholds the ✓/✗ so it can't be misread as
  # certifying the wrong regime.
  defp m_production_rule_report(rows, 512) do
    {palette_t, nat_t} = ContentClassifier.photo_thresholds()
    photo_pred = fn r -> r.palette_entropy >= palette_t and r.natural_variation >= nat_t end

    photos = Enum.filter(rows, &(&1.class == :photo))
    screens = Enum.filter(rows, &(&1.class == :screen_or_other))
    recall = Enum.count(photos, photo_pred)
    leak = Enum.count(screens, photo_pred)

    IO.puts(
      "\n  PRODUCTION rule (palette_ent ≥ #{palette_t} ∧ nat_var ≥ #{nat_t}) — " <>
        "frozen ContentClassifier thresholds @ downsample 512 (certifying)"
    )

    IO.puts(
      "    photo→photo #{recall}/#{length(photos)}   photo→screen #{length(photos) - recall}"
    )

    IO.puts(
      "    screen→screen #{length(screens) - leak}/#{length(screens)}   " <>
        "screen→photo #{leak} (TEXT DAMAGE)" <> if(leak == 0, do: "  ✓ safe", else: "  ✗")
    )
  end

  defp m_production_rule_report(_rows, downsample) do
    {palette_t, nat_t} = ContentClassifier.photo_thresholds()

    IO.puts(
      "\n  PRODUCTION rule (palette_ent ≥ #{palette_t} ∧ nat_var ≥ #{nat_t}) @ downsample " <>
        "#{downsample} — NOT certifying; the safety verdict only holds at 512, " <>
        "rerun `--downsample 512`."
    )
  end

  defp m_feature_stat({key, name, _hyp}, photos, screens) do
    pv = Enum.map(photos, &Map.fetch!(&1, key))
    sv = Enum.map(screens, &Map.fetch!(&1, key))
    auc = m_auc(sv, pv)
    {theta, photo_low?} = m_youden(pv, sv)
    stat = %{key: key, name: name, theta: theta, photo_low?: photo_low?, sep: max(auc, 1.0 - auc)}
    errs = Enum.count(screens, &m_predict_photo(Map.fetch!(&1, key), stat))

    IO.puts(
      "  " <>
        pad([name, 13]) <>
        pad([Float.round(median(pv), 3), 11]) <>
        pad([Float.round(median(sv), 3), 12]) <>
        pad([Float.round(auc, 3), 9]) <>
        pad([Float.round(m_cohen_d(sv, pv), 2), 9]) <>
        pad([Float.round(theta, 3), 8]) <>
        pad([Float.round(stat.sep, 3), 7]) <> "#{errs}/#{length(screens)}"
    )

    stat
  end

  # Predict :photo for this feature iff the value is on the photo side of θ. Direction
  # comes from the observed class medians (photo_low?), so a feature whose real
  # direction is opposite the hypothesis is still oriented correctly.
  defp m_predict_photo(value, %{theta: t, photo_low?: true}), do: value <= t
  defp m_predict_photo(value, %{theta: t, photo_low?: false}), do: value >= t

  # Youden-J optimal split: orientation from medians, θ from the candidate midpoints
  # maximizing TPR_screen + TNR_screen − 1 (balance-robust under class imbalance).
  defp m_youden(pv, sv) do
    photo_low? = median(sv) >= median(pv)
    np = length(pv)
    ns = length(sv)

    {theta, _j} =
      (pv ++ sv)
      |> Enum.sort()
      |> m_midpoints()
      |> Enum.map(fn t ->
        stat = %{theta: t, photo_low?: photo_low?}
        tnr = Enum.count(sv, &(not m_predict_photo(&1, stat))) / ns
        tpr = Enum.count(pv, &m_predict_photo(&1, stat)) / np
        {t, tpr + tnr - 1.0}
      end)
      |> Enum.max_by(&elem(&1, 1))

    {theta, photo_low?}
  end

  defp m_midpoints(sorted) do
    sorted
    |> Enum.uniq()
    |> Enum.chunk_every(2, 1, :discard)
    |> Enum.map(fn [a, b] -> (a + b) / 2.0 end)
    |> case do
      [] -> [hd(sorted)]
      mids -> mids
    end
  end

  # Combined AND-rule: predict :photo iff EVERY feature in the rule predicts photo;
  # else the safe fallback :screen_or_other. Reports both error directions, but the
  # one that matters is scr→photo (a screenshot classified photo → the lean offset →
  # visible text damage); photo→scr only costs a slightly bigger file.
  defp m_rule_report(title, rows, feat_stats) do
    photo_pred = fn r -> Enum.all?(feat_stats, &m_predict_photo(Map.fetch!(r, &1.key), &1)) end
    photos = Enum.filter(rows, &(&1.class == :photo))
    screens = Enum.filter(rows, &(&1.class == :screen_or_other))

    tp = Enum.count(photos, photo_pred)
    fp = Enum.count(screens, photo_pred)
    tn = length(screens) - fp
    fn_ = length(photos) - tp

    IO.puts("\n  #{title}")
    IO.puts("    photo→photo #{tp}/#{length(photos)}   photo→screen #{fn_} (bigger file)")

    IO.puts(
      "    screen→screen #{tn}/#{length(screens)}   screen→photo #{fp} (TEXT DAMAGE)" <>
        if(fp == 0, do: "  ✓ safe", else: "  ✗")
    )
  end

  # --- Part M (b): >6 MP residual confirmation -------------------------------

  defp m_residual_rows(sources) do
    crossover = CropScore.crossover_megapixels()

    IO.puts(
      "\n  computing >#{crossover} MP residual confirmation " <>
        "(shipped #{@l_ship_k}/#{@l_ship_tile}, reuses Part L baseline)…"
    )

    Enum.flat_map(sources, &m_source_residuals(&1, crossover))
  end

  defp m_source_residuals({sname, subjects}, crossover) do
    case m_class_of(sname) do
      nil ->
        []

      class ->
        subjects
        |> Enum.filter(fn {_l, base} -> mp_of(base) > crossover end)
        |> Enum.flat_map(fn {label, base} -> m_residual_for(sname, class, label, base) end)
    end
  end

  defp m_residual_for(source, class, label, base) do
    Enum.flat_map(@g_formats, fn format ->
      {_lo, hi} = g_bracket(format)

      case Encoder.encode_to_buffer(base, plain_resolved(format, hi), hi) do
        {:error, _} -> []
        {:ok, _} -> [m_residual_case(source, class, label, base, format, hi)]
      end
    end)
  end

  defp m_residual_case(source, class, label, base, format, hi) do
    {:ok, full_ref} = Ssim2Metric.reference(base)
    {:ok, cache} = Agent.start_link(fn -> %{enc: %{}, rev: %{}, full: %{}, cov: %{}} end)

    funs = %{
      resolved: h_resolved(format),
      encode_fun: partf_encode_fun(cache, base, format),
      full_at: l_full_fun(cache, full_ref),
      cov_at: l_cov_fun(cache, base),
      hi: hi
    }

    base_ctx = l_baseline(funs)
    {:ok, base_bytes} = funs.encode_fun.(base_ctx.base_q)

    # The same even-K tiles the residual's p10 comes from — captured here so their
    # dispersion can be tested as a near-free sliding-offset signal (the crop scorer
    # already computes these scores every search; no extra pixels).
    sel =
      funs.cov_at.(@l_ship_tile, base_bytes)
      |> TileSelection.select(@l_ship_k, :even)
      |> Enum.map(& &1.score)

    Agent.stop(cache)
    tile = m_tile_stats(sel)

    Map.merge(tile, %{
      source: source,
      class: class,
      label: label,
      mp: Float.round(mp_of(base), 1),
      format: format,
      residual: tile.p10 - base_ctx.base_full,
      base_full: base_ctx.base_full,
      base_hit?: base_ctx.base_hit?
    })
  end

  defp m_report_residual(_feat, []),
    do: IO.puts("\n  (b) no >6 MP images in cohort — residual confirmation skipped.")

  defp m_report_residual(feat_rows, resid_rows) do
    IO.puts(
      "\n  (b) residual = even-K#{@l_ship_k}/#{@l_ship_tile} p10 − full-frame  " <>
        "(positive = crop overshoots → ships under target)"
    )

    IO.puts(
      "  mean/p90 over BASELINE-HIT cases (the population an offset protects, matching " <>
        "Part L's p90hit); n = all >6 MP cases, hit = baseline on-target"
    )

    IO.puts(
      "  " <>
        pad(["class", 18]) <>
        pad(["format", 8]) <>
        pad(["n", 4]) <> pad(["hit", 5]) <> pad(["mean_hit", 10]) <> "p90_hit"
    )

    for class <- [:photo, :screen_or_other], format <- @g_formats do
      rs = Enum.filter(resid_rows, &(&1.class == class and &1.format == format))
      if rs != [], do: m_residual_row(class, format, rs)
    end

    m_report_avif_by_source(resid_rows)
    m_report_dispersion(resid_rows)
    m_report_spearman(feat_rows, resid_rows)
  end

  # Tile-dispersion probe: does the crop scorer's OWN per-tile score spread predict the
  # p10→full-frame overshoot? If a dispersion stat correlated tightly, it would be a
  # near-free continuous (sliding) offset — no classifier, no extra pixels, just a
  # statistic over the K tile scores the search already computes.
  defp m_report_dispersion(resid_rows) do
    avif = Enum.filter(resid_rows, &(&1.format == :avif))
    screen = Enum.filter(avif, &(&1.class == :screen_or_other))

    if avif != [] do
      IO.puts("\n  tile-dispersion → AVIF residual (near-free sliding-offset signal?)")

      IO.puts(
        "  Pearson r (stat over the residual's own even-K tiles, residual); r² = variance explained:"
      )

      for {tag, group} <- [
            {"ALL >6MP (#{length(avif)})", avif},
            {"screen (#{length(screen)})", screen}
          ] do
        IO.puts("    #{tag}:")
        Enum.each(@m_dispersion_stats, &m_dispersion_row(&1, group))
      end
    end
  end

  defp m_dispersion_row({key, label}, group) do
    r = m_pearson(Enum.map(group, &Map.fetch!(&1, key)), Enum.map(group, & &1.residual))

    IO.puts(
      "      #{pad([label, 10])} r=#{pad([Float.round(r, 3), 8])}r²=#{Float.round(r * r, 3)}"
    )
  end

  # Per-source AVIF breakdown: the single {avif, :screen_or_other} offset must cover
  # the WORST sub-type in the class, so this shows which content drives the tail
  # (the doc's finding: dense text — web_sc — overshoots ~6, the binding worst case).
  defp m_report_avif_by_source(resid_rows) do
    by_source =
      resid_rows
      |> Enum.filter(&(&1.format == :avif))
      |> Enum.group_by(& &1.source)
      |> Enum.sort_by(fn {src, _} -> src end)

    if by_source != [] do
      IO.puts(
        "\n  AVIF residual by source (>6 MP, baseline-hit only — the per-content offset need):"
      )

      IO.puts(
        "  " <>
          pad(["source", 14]) <>
          pad(["class", 18]) <>
          pad(["n", 4]) <> pad(["hit", 5]) <> pad(["mean_hit", 10]) <> "p90_hit"
      )

      Enum.each(by_source, fn {src, rs} ->
        {n, hit, mean_s, p90_s} = m_resid_stats(rs)

        IO.puts(
          "  " <>
            pad([src, 14]) <>
            pad([hd(rs).class, 18]) <>
            pad([n, 4]) <> pad([hit, 5]) <> pad([mean_s, 10]) <> "#{p90_s}"
        )
      end)
    end
  end

  defp m_residual_row(class, format, rs) do
    {n, hit, mean_s, p90_s} = m_resid_stats(rs)

    IO.puts(
      "  " <>
        pad([class, 18]) <>
        pad([format, 8]) <>
        pad([n, 4]) <> pad([hit, 5]) <> pad([mean_s, 10]) <> "#{p90_s}"
    )
  end

  # n = all >6 MP cases, hit = baseline on-target; mean/p90 over the baseline-hit
  # cases only (the population an offset protects, matching Part L's p90hit).
  defp m_resid_stats(rs) do
    hit = Enum.filter(rs, & &1.base_hit?)
    vals = Enum.map(hit, & &1.residual)

    {mean_s, p90_s} =
      case vals do
        [] -> {"-", "-"}
        _ -> {Float.round(m_mean(vals), 2), Float.round(percentile(Enum.sort(vals), 0.90), 2)}
      end

    {length(rs), length(hit), mean_s, p90_s}
  end

  # Correlate features with the AVIF residual WITHIN the screen class only. Pooling
  # photo+screen is degenerate here — the residual is bimodal by class and every
  # class-separating feature trivially scores ρ≈1, re-stating (a) rather than testing
  # anything new. The informative question is whether the features predict the residual
  # SPREAD inside screen content (web_sc dense-text ~6 vs grafana charts ~0) — i.e.
  # whether a finer-than-2-class offset policy has any cheap signal to key on.
  defp m_report_spearman(feat_rows, resid_rows) do
    feat_by = Map.new(feat_rows, &{{&1.source, &1.label}, &1})

    paired =
      resid_rows
      |> Enum.filter(&(&1.format == :avif and &1.class == :screen_or_other))
      |> Enum.flat_map(fn r ->
        case Map.get(feat_by, {r.source, r.label}) do
          nil -> []
          f -> [{f, r.residual}]
        end
      end)

    IO.puts(
      "\n  Spearman ρ(feature, AVIF residual) WITHIN screen class, #{length(paired)} >6 MP imgs " <>
        "(finer-policy signal; pooled photo+screen is degenerate at ρ≈1):"
    )

    resids = Enum.map(paired, &elem(&1, 1))

    Enum.each(@m_features, fn {key, name, _} ->
      rho = m_spearman(Enum.map(paired, fn {f, _} -> Map.fetch!(f, key) end), resids)
      IO.puts("    #{pad([name, 13])} ρ=#{Float.round(rho, 3)}")
    end)
  end

  # --- Part M: statistics helpers --------------------------------------------

  # AUC = P(value from `hi` group > value from `lo` group), ties half-credited. As a
  # threshold-free 1-D separation score oriented "high ⇒ screen": >0.5 means the
  # feature reads higher on screens, <0.5 higher on photos, 0.5 no separation.
  defp m_auc([], _lo), do: 0.5
  defp m_auc(_hi, []), do: 0.5

  defp m_auc(hi, lo) do
    wins = Enum.reduce(hi, 0.0, fn h, acc -> acc + m_auc_wins(h, lo) end)
    wins / (length(hi) * length(lo))
  end

  defp m_auc_wins(h, lo) do
    Enum.reduce(lo, 0.0, fn l, a ->
      cond do
        h > l -> a + 1.0
        h == l -> a + 0.5
        true -> a
      end
    end)
  end

  defp m_cohen_d(a, b) do
    sd = m_pooled_sd(a, b)
    if sd == 0.0, do: 0.0, else: (m_mean(a) - m_mean(b)) / sd
  end

  defp m_pooled_sd(a, b) do
    na = length(a)
    nb = length(b)

    if na < 2 or nb < 2 do
      0.0
    else
      :math.sqrt(((na - 1) * m_var(a) + (nb - 1) * m_var(b)) / (na + nb - 2))
    end
  end

  defp m_mean([]), do: 0.0
  defp m_mean(list), do: Enum.sum(list) / length(list)

  defp m_var(list) do
    mean = m_mean(list)
    Enum.reduce(list, 0.0, fn x, acc -> acc + (x - mean) * (x - mean) end) / (length(list) - 1)
  end

  defp m_std(list) when length(list) < 2, do: 0.0
  defp m_std(list), do: :math.sqrt(m_var(list))

  # Dispersion of the selected even-K tile scores the residual's p10 comes from. Each
  # stat is a candidate cheap proxy for the p10→full-frame overshoot (the residual),
  # available for free from the crop scorer's existing per-tile scores.
  defp m_tile_stats(scores) do
    sorted = Enum.sort(scores)
    p10 = percentile(sorted, 0.10)

    %{
      p10: p10,
      tile_std: m_std(scores),
      tile_med_p10: percentile(sorted, 0.50) - p10,
      tile_mean_p10: m_mean(scores) - p10,
      tile_p10_min: p10 - List.first(sorted),
      tile_iqr: percentile(sorted, 0.75) - percentile(sorted, 0.25)
    }
  end

  defp m_pearson(xs, _ys) when length(xs) < 2, do: 0.0

  defp m_pearson(xs, ys) do
    mx = m_mean(xs)
    my = m_mean(ys)
    cov = Enum.zip(xs, ys) |> Enum.reduce(0.0, fn {a, b}, acc -> acc + (a - mx) * (b - my) end)
    dx = Enum.reduce(xs, 0.0, fn a, acc -> acc + (a - mx) * (a - mx) end)
    dy = Enum.reduce(ys, 0.0, fn b, acc -> acc + (b - my) * (b - my) end)
    denom = :math.sqrt(dx * dy)
    if denom == 0.0, do: 0.0, else: cov / denom
  end

  # Spearman = Pearson on ranks (average ranks for ties).
  defp m_spearman(xs, _ys) when length(xs) < 2, do: 0.0

  defp m_spearman(xs, ys), do: m_pearson(m_ranks(xs), m_ranks(ys))

  # Average ranks (ties shared), returned in the ORIGINAL element order so the pairing
  # with the other series survives. `Enum.with_index` yields {value, index}; rank by
  # value, then restore index order.
  defp m_ranks(values) do
    values
    |> Enum.with_index()
    |> Enum.sort_by(&elem(&1, 0))
    |> Enum.chunk_by(&elem(&1, 0))
    |> rank_chunks(1)
    |> Enum.sort_by(&elem(&1, 0))
    |> Enum.map(&elem(&1, 1))
  end

  defp rank_chunks([], _pos), do: []

  defp rank_chunks([chunk | rest], pos) do
    n = length(chunk)
    avg = (pos + (pos + n - 1)) / 2.0
    Enum.map(chunk, fn {_value, index} -> {index, avg} end) ++ rank_chunks(rest, pos + n)
  end

  defp write_part_m_csv(%{feat: feat_rows, resid: resid_rows}) do
    feat_path = "/tmp/autoquality_bench_part_m_features.csv"

    feat_head =
      "source,label,class,mp,feat_us,flat_frac,hard_edge_frac," <>
        "palette_entropy,natural_variation,axis_aligned\n"

    feat_body =
      Enum.map_join(feat_rows, fn r ->
        "#{r.source},#{r.label},#{r.class},#{r.mp},#{r.feat_us}," <>
          "#{Float.round(r.flat_frac, 4)},#{Float.round(r.hard_edge_frac, 4)}," <>
          "#{Float.round(r.palette_entropy, 4)},#{Float.round(r.natural_variation, 4)}," <>
          "#{Float.round(r.axis_aligned, 4)}\n"
      end)

    File.write!(feat_path, feat_head <> feat_body)
    IO.puts("wrote #{feat_path}")

    resid_path = "/tmp/autoquality_bench_part_m_residual.csv"

    resid_head =
      "source,label,class,mp,format,residual,base_full,base_hit," <>
        "tile_std,tile_med_p10,tile_mean_p10,tile_p10_min,tile_iqr\n"

    resid_body =
      Enum.map_join(resid_rows, fn r ->
        "#{r.source},#{r.label},#{r.class},#{r.mp},#{r.format}," <>
          "#{Float.round(r.residual, 3)},#{fmt_score(r.base_full)},#{r.base_hit?}," <>
          "#{Float.round(r.tile_std, 3)},#{Float.round(r.tile_med_p10, 3)}," <>
          "#{Float.round(r.tile_mean_p10, 3)},#{Float.round(r.tile_p10_min, 3)}," <>
          "#{Float.round(r.tile_iqr, 3)}\n"
      end)

    File.write!(resid_path, resid_head <> resid_body)
    IO.puts("wrote #{resid_path}")
  end

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

  defp print_findings(parts, format) do
    IO.puts("\n== Findings ==\n")

    [
      {parts.a, &findings_part_a/1},
      {parts.b, &findings_part_b/1},
      {parts.c, &findings_part_c/1},
      {parts.e, &findings_part_e/1},
      {parts.f,
       fn f ->
         findings_part_f(f.variants)
         findings_part_f_agg(f.agg)
       end},
      {parts.g, &findings_part_g/1},
      {parts.h, &findings_part_h/1},
      {parts.i, &findings_part_i/1},
      {parts.j, &findings_part_j/1},
      {parts.k, &findings_part_k/1},
      {parts.l, &findings_part_l/1}
    ]
    |> Enum.each(fn {rows, finder} -> if rows, do: finder.(rows) end)

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

  defp write_part_g_csv(rows) do
    path = "/tmp/autoquality_bench_part_g.csv"

    head =
      "source,label,format,variant,probes,metric_us,total_us,bytes,score,under_target,chosen\n"

    body =
      Enum.map_join(rows, fn r ->
        "#{r.source},#{r.label},#{r.format},#{r.variant},#{r.probes},#{r.metric_us}," <>
          "#{r.total_us},#{r.bytes},#{fmt_score(r.score)},#{r.under_target?},#{r.chosen}\n"
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

  defp parse_offsets(nil), do: @k_offsets

  defp parse_offsets(str) do
    str
    |> String.split(",", trim: true)
    |> Enum.map(&(&1 |> String.trim() |> Float.parse() |> elem(0)))
  end

  defp parse_ks(nil), do: @l_ks
  defp parse_ks(str), do: parse_int_list(str)

  defp parse_tiles(nil), do: @l_tiles
  defp parse_tiles(str), do: parse_int_list(str)

  defp parse_int_list(str) do
    str
    |> String.split(",", trim: true)
    |> Enum.map(&(&1 |> String.trim() |> String.to_integer()))
  end

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
