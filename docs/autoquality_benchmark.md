# Autoquality (ssim2) search — benchmark + findings

Follow-up to #351. The `:ssim2` autoquality objective runs a binary search over
encoder quality at the output/encode boundary
([`ImagePipe.Output.EncodeSearch`](../lib/image_pipe/output/encode_search.ex)).
For `:ssim2`, **every distinct iteration does a full-resolution encode + decode +
SSIMULACRA2 metric** on the result, and the metric dominates. #351 shipped this
correctness-verified only, with no performance data. This documents the
benchmark tool and the numbers it produced.

## Running it

```shell
mise exec -- mix autoquality.bench            # parts A+B, default sizes, prints tables
mise exec -- mix autoquality.bench --part a   # cost curve only
mise exec -- mix autoquality.bench --part b   # accuracy/behavior only
mise exec -- mix autoquality.bench --part c   # downscaled-proxy-seed method + accuracy
mise exec -- mix autoquality.bench --part d   # cheap full-res metric narrowing
mise exec -- mix autoquality.corpus           # fetch the Part E corpus (one-time)
mise exec -- mix autoquality.bench --part e --corpus DIR  # crop-based scoring, per source
mise exec -- mix autoquality.bench --part f --corpus DIR  # saliency tile selection vs confirm
mise exec -- mix autoquality.bench --part g --corpus DIR  # early-stop vs full search, per format cap
mise exec -- mix autoquality.bench --part all # A + B + C + D + E + F + G
mise exec -- mix autoquality.bench --mps 1,4  # custom Part A megapixels
mise exec -- mix autoquality.bench --proxy-factors 2,4 --proxy-mp 25  # Part C knobs
mise exec -- mix autoquality.bench --csv      # also write /tmp/autoquality_bench_part_{a,b,c,e,f,g}.csv
```

> **Part E corpus.** Part E needs content-diverse, license-clean images the
> committed sources can't provide (they're synthetic/uniform). `mix
> autoquality.corpus` fetches pinned subsets of
> [`imazen/codec-corpus`](https://github.com/imazen/codec-corpus) — CLIC 2025
> (photographic, train/holdout), CID22 (diverse), GB82 (hard photographic), GB82-SC
> (screen content), QOI web screenshots — plus a fixed set of ~15 MP photos for the
> size-dependent regime, into a shared worktree-independent cache via the GitHub
> raw API (no git/LFS). Each `--corpus` subdirectory is a per-source group; the
> bench reports per source then macro-averages. Pinned codec-corpus SHA
> `bb1da43`.

[`mix autoquality.bench`](../test/support/mix/tasks/autoquality.bench.ex) is
gated off the default `mix test` lane: it is a `test/support` Mix task (compiled
only under `MIX_ENV=test`, auto-selected via `mix.exs` `preferred_envs`), never a
test the lane runs. It needs no Docker — it measures our algorithm only, over the
committed differential sources and a synthetic zone-plate. The `ssimulacra2` Rust
NIF builds from source on first compile (slow once).

It reuses the public surface only — `ImagePipe.Output.Encoder`, `EncodeSearch`,
`Ssim2Metric` — and reads achieved scores from the search's own
`[:encode, :search]` `:stop` telemetry (`final_score`, the score against the
correct pre-encode finalized reference), never an ad-hoc baseline.

### What each part measures

- **Part A — cost curve.** The real `:ssim2` search (target 88, bracket
  `[40,95]`, `max_iterations 6`) on a deterministic high-frequency zone-plate
  (chirp) generated at each target megapixel count. The injected
  `encode_fun`/`score_fun` are wrapped to accumulate per-phase time
  (`encode` = `Encoder.encode_to_buffer`; `decode` = `Image.from_binary`;
  `metric` = `Ssim2Metric.score`), and the one-time reference build is timed
  separately. Output: where the wall-clock goes as a function of pixel count.
- **Part B — accuracy + behavior.** The production encode path
  (`Encoder.stream_output/3`, which finalizes exactly as a real request) over the
  committed sources at native size, for three configs each: `ssim2:88:40:95`,
  `size`, and `max_bytes` (the latter two to `round(q90 bytes * 0.6)`). Output:
  whether ssim2 lands at/above target, typical quality/savings/iterations, and
  how much cheaper the metric-free objectives are.
- **Part C — downscaled-proxy-seed method + accuracy.** For each subject and
  downscale factor `k`: run the full-res search (ground truth `q_full`), then
  downscale by `1/k`, run the search on the proxy (`q_proxy`), encode the
  **full-res** image once at `q_proxy`, and score that delivered output against
  the full-res reference. Subjects: the committed sRGB high-detail sources at
  native size (genuine content, modest scale) plus an adversarial zone-plate at
  16 MP (large-scale + worst-case for the metric). Output: does the proxy's
  quality choice still hit the target at full res, how the bytes move, and the
  measured speedup. **Caveat:** no large *real* sources exist in-repo, so
  cross-scale generalization to 16–36 MP photos is inferred from the ≤2 MP real
  signal; the only large subject is the adversarial synthetic.

> The bracket used here (`[40,95]`, target 88) is a deliberate **worst-case**: it
> is wide, so the binary search spends close to its full 6-iteration budget, and
> the target is high enough that the search keeps probing. The *shipped* imgproxy
> autoquality defaults are narrower — `min_quality 70`, `max_quality 80` (11
> candidate qualities ⇒ ~4 probes), and `autoquality_target` is required. So
> real-world ssim2 cost is roughly **⅔** of the per-iteration numbers below
> (~4 metric passes instead of 6).

## Results (reference machine: Apple Silicon, libvips 8.18.2)

Absolute numbers are machine- and libvips-dependent; **the shape and ratios are
the portable conclusions**. Re-run locally to calibrate a host's budget.

### Part A — ssim2 search cost vs. megapixels (zone-plate, 6 iterations)

| MP  | dims      | iters | total ms | ref ms | encode ms | decode ms | metric ms | /iter ms | metric % |
|-----|-----------|-------|----------|--------|-----------|-----------|-----------|----------|----------|
| 1   | 1000×1000 | 6     | 323      | 31     | 29        | 2         | 257       | 48       | 80%      |
| 4   | 2000×2000 | 6     | 1179     | 118    | 92        | 2         | 967       | 177      | 82%      |
| 9   | 3000×3000 | 6     | 2634     | 251    | 203       | 5         | 2175      | 397      | 83%      |
| 16  | 4000×4000 | 6     | 4730     | 486    | 348       | 6         | 3890      | 707      | 82%      |
| 25  | 5000×5000 | 6     | 8095     | 786    | 546       | 19        | 6744      | 1218     | 83%      |
| 36  | 6000×6000 | 6     | 20405    | 1488   | 855       | 43        | 18019     | 3153     | 88%      |

- **The metric is the cost.** SSIMULACRA2 scoring is ~80–88% of total wall-clock
  at every size; encode is ~5%, decode is negligible (<1%), and the one-time
  reference build is ~6–10%.
- **Roughly linear in pixels through 16 MP, then superlinear.** Per-iteration
  cost tracks pixel count closely up to ~16 MP (≈44 ms/MP for the full
  encode+decode+metric step); 25→36 MP jumps disproportionately (8.1 s → 20.4 s),
  consistent with memory-bandwidth/cache pressure on the larger float buffers.
- **A full 6× pass is expensive fast.** At default `max_resolution: 0`
  (unbounded, see below) a 16 MP request adds ~4.7 s of pure CPU, 25 MP ~8 s,
  36 MP ~20 s — enough to blow typical HTTP timeouts and pin a scheduler.

### Part B — accuracy + behavior over real sources (native size)

27 committed sources, `ssim2:88:40:95` vs a fixed `q90` baseline:

- **ssim2 hits its target: 26/27 sources scored ≥ 88.** The one miss is
  `small.png` (120×90), which tops out at q95 = 87.43 — it physically cannot reach
  88 within the bracket, so the search correctly returns the ceiling (best-effort).
- **Iterations: 5.9 avg** (almost always the full 6 on the wide `[40,95]` bracket;
  a couple of sources converge in 5).
- **Savings are content-dependent and substantial on high-detail content:**
  high-frequency photographic sources save **40–58%** vs q90 (`high_freq` 58%,
  `marker`/`border` 40–42%) at a chosen quality of 40–74. Already-compact or
  already-optimized sources save ~0% (the search lands at q90) or slightly
  *negative* on tiny files (`small.png`, `cmyk.jpg` at −6%, where q95 is chosen
  and re-encode overhead exceeds the baseline). Average across all 27: ~18%.
- **The metric-free objectives are ~15× cheaper.** Average per-source cost:
  **ssim2 147 ms vs size 9.8 ms vs max_bytes 9.8 ms.** `size` and `max_bytes`
  skip the decode+metric entirely, so their cost is just the encode probes; the
  ~15× gap *is* the decode+metric overhead and matches Part A's ~83% metric share.

### Part C — downscaled-proxy-seed method + accuracy

Full-res search vs. proxy-seed, per subject × downscale factor. `Δq = q_proxy −
q_full`; `delivered` is the true full-res SSIMULACRA2 score of the full-res encode
at `q_proxy`; `bytesΔ` is delivered bytes vs. the full-res optimum. Ground truth is
the **full-res search**, not the absolute target (which the full search itself can
miss at the bracket ceiling — see `aq_157`).

**Committed sources (≤2 MP) + adversarial synthetic:**

| source        | MP   | k | q_full | q_proxy | Δq  | delivered | hit | bytesΔ | speedup |
|---------------|------|---|--------|---------|-----|-----------|-----|--------|---------|
| high_freq.jpg | 1.92 | 2 | 40     | 41      | +1  | 90.03     | yes | +2%    | 3.1×    |
| high_freq.jpg | 1.92 | 4 | 40     | 75      | +35 | 93.64     | yes | +49%   | 9.8×    |
| marker.png    | 1.92 | 2 | 74     | 83      | +9  | 90.26     | yes | +1%    | 3.5×    |
| placement.png | 1.92 | 4 | 90     | 90      | 0   | 88.85     | yes | 0%     | 8.9×    |
| zone-16MP     | 16.0 | 3 | 95     | 91      | −4  | 82.85     | **NO** | −19% | 7.0× |

**Large real photos (16–20 MP, Unsplash via Lorem Picsum, `--proxy-files`):**

| source     | MP    | k | q_full | q_proxy | Δq  | full_score | delivered | vs target | bytesΔ | speedup |
|------------|-------|---|--------|---------|-----|------------|-----------|-----------|--------|---------|
| aq_146.jpg | 16.66 | 2 | 74     | 92      | +18 | 90.82      | 90.58     | hit       | **+56%** | 3.8×  |
| aq_146.jpg | 16.66 | 4 | 74     | 93      | +19 | 90.82      | 90.87     | hit       | **+69%** | 14.8× |
| aq_201.jpg | 16.66 | 2 | 93     | 95      | +2  | 88.02      | 88.32     | hit       | +14%   | 3.9×    |
| aq_201.jpg | 16.66 | 4 | 93     | 92      | −1  | 88.02      | 87.64     | miss −0.36| −8%    | 12.7×   |
| aq_157.jpg | 19.57 | 2 | 95     | 95      | 0   | 86.47      | 86.47     | full also misses | 0% | 4.9× |

Aggregated over the large-photo run (3 real + synthetic):

| k | proxy-caused undershoots (of full-hit) | worst Δscore vs full | worst over-pick | speedup |
|---|----------------------------------------|----------------------|-----------------|---------|
| 2 | 1/3 | −1.13 | +18q / +56% bytes | ~3.9× |
| 3 | 1/3 | −5.75 | +19q / +69% bytes | ~7.9× |
| 4 | 2/3 | −1.13 | +19q / +69% bytes | ~12.0× |

**The speedup is real (~3.9× at k=2 up to ~12× at k=4), but the large-scale test
overturns the optimistic read from the ≤2 MP sources. The method is not a clean
win:**

- **SSIMULACRA2 is resolution-dependent — a given quality scores *lower* on a
  downscaled image** — so the search on the proxy systematically **over-picks
  quality** to clear the same score. Crucially, the over-pick **grows with image
  size**: it was +1–2q on the ≤2 MP sources but **+18q on a 16 MP photo**, where
  the proxy shipped **+56–69% more bytes** than the optimal full-res pick (`aq_146`:
  q92 vs. the correct q74, for the same delivered ~90.6 score). This erodes — often
  erases — the savings autoquality exists to capture, and it is the *expensive*
  direction to undo (recovering it needs a downward full-res search).
- **Undershoot still happens on real content** when the full score sits right on
  the target band (`aq_201` k=4: delivered 87.64 vs. 88). The adversarial chirp
  undershoots hard (k=3: 82.85). This direction is cheap to fix (bump q + one
  confirm) — but the over-pick is not.
- **A single additive margin can't help** — it only addresses undershoot, and
  worsens the dominant over-pick.
- **The ≤2 MP "k=2 sweet spot" does not generalize:** at 16 MP, even k=2 over-shot
  bytes by +56%. The earlier caveat (no large real sources) was the right one to
  flag — the cross-scale signal reverses the conclusion.

### Part D — cheap full-res metric narrowing (#6)

Can a *cheap* full-res metric (PSNR — no XYB/multiscale-SSIM cost) narrow the
search so SSIMULACRA2 runs ~once instead of ~4–6×, while the final decision stays
full-res SSIMULACRA2 (no resolution bias)? Viability hinges on one statistic:
**is the cheap metric's value at the SSIMULACRA2 boundary stable across images?**
If yes, a single calibrated threshold locates the boundary; if it drifts per image,
a global threshold mis-picks.

It drifts — badly. The cheap value at the boundary spans **11–22 dB**:

| corpus | metric | cheap@boundary spread | exact-q | underpick (worst) | overpick byte waste (worst) | cheaper |
|--------|--------|------------------------|---------|-------------------|-----------------------------|---------|
| committed ≤2 MP | PSNR-RGB  | 38.8 … 50.0 dB (11 dB) | 2/6 | 3/6 (−28q) | +87%  | 9.2× |
| committed ≤2 MP | PSNR-luma | 38.8 … 58.3 dB (20 dB) | 1/6 | 3/6 (−27q) | +136% | 9.2× |
| large 16 MP     | PSNR-RGB  | 43.9 … 65.9 dB (22 dB) | 2/3 | 0/3       | +27%  | 11.3× |

A high-frequency photo clears SSIMULACRA2 = 88 at ~39 dB PSNR; clean line-art
(`marker`) needs ~50 dB; a 16 MP photo ~66 dB. So any single PSNR threshold either
**underpicks** (ships visibly under-compressed images — up to −28q) or **overpicks**
(wastes >100% bytes), depending on content. The metric *is* genuinely ~9–11×
cheaper than SSIMULACRA2 (the cost premise holds) — it just doesn't track the
*perceptual* boundary, which is exactly the gap SSIMULACRA2 exists to close.

**Conclusion:** PSNR-class narrowing is a non-starter with a global threshold. The
only ways forward both have caveats: a cheaper *perceptual* metric (MS-SSIM,
butteraugli) that tracks the boundary — **not in our stack** today — or per-image
SSIMULACRA2 anchoring (2 anchors + cheap interpolation + 1 confirm), which saves
~0 probes on the shipped narrow `[70,80]` bracket and only ~2–3 on a wide one.

### Part E — crop-based scoring vs full-frame (#1)

Score SSIMULACRA2 on native-resolution tiles of the *actual full-res encode*, not
the whole frame. Unlike Part C's proxy this keeps native resolution, so per-pixel
artifact statistics match — the only error is *which regions* you look at. Run
**per content source** over the [`imazen/codec-corpus`](https://github.com/imazen/codec-corpus)
subsets fetched by `mix autoquality.corpus` (≤24/source, macro-averaged so no one
content type dominates), 512 px tiles, K=16 sub-sample — **so the scored sample is a
fixed 16 × 512² ≈ 4.2 MP regardless of source resolution** (full coverage would tile
the whole frame; sub-sampling to K=16 tiles is the cost lever). The honest tracking
metric is the *offset* `tile_p10 − full_frame_score` at the boundary — a calibrated global
threshold rides on it (the raw aggregate spread would be inflated by `full_score`'s
integer-quality quantization):

| source | imgs | hit | q̄ | save vs q90 | **p10 offset** (median; spread) | cost full→K16 |
|--------|------|-----|----|----|-----|-----|
| clic (2–4 MP photos) | 24 | 24/24 | 93 | −22% | 0.29; −1.2…2.7 | 129→266 ms (loss) |
| clic_holdout | 24 | 23/24 | 92 | −19% | −0.03; −1.1…1.8 | 125→265 ms (loss) |
| gb82_sc (screen content) | 10 | 9/10 | 91 | −4% | −0.52; −1.2…2.1 | 124→268 ms (loss) |
| qoi_web (huge screenshots) | 14 | 4/14 | 93 | −16% | 0.39; −0.5…2.6 | 299→267 ms (1.1×) |
| **large (15 MP photos)** | 6 | 5/6 | 84 | **+17%** | 1.46; −0.1…3.8 | **682→270 ms (2.5×)** |
| cid22 (512²), gb82 (576²) | 48 | 48/48 | 91 | −3…−9% | ~0 (≈1 tile — B only) | loss |
| **macro-average** | | | | **−8%** | **+0.22** | |

**Tracking generalizes across content types.** p10 offset median stays within ±1.5
on photographs (CLIC), **screen content** (gb82_sc −0.52), huge web screenshots
(qoi 0.39) and large photos (1.46); macro +0.22, residual spreads ~3–4 pts (≈ ±2–4 q)
— versus Part C's ±18 q and Part D's hopeless spread. The screen-content
generalization risk that motivated the diverse corpus is resolved: it tracks. A
single threshold `≈ target + macro-offset` reproduces the full-frame decision; a
one-pass full-frame confirm covers the residual. (`cid22`/`gb82` are ≤576 px → one
tile, so they only exercise the B-refresh below, not crop-tracking.)

**Cost win is large-image-only, confirmed.** Because K=16 always scores the same
~4.2 MP sample (16 × 512²) no matter the source size, it's a **flat ~265 ms budget**;
full-frame scores the whole image and grows ~linearly. So crops only beat full-frame
above a **~6 MP crossover** (≈ where the full frame's area passes the 4.2 MP sample
plus per-tile overhead), and the win ≈ source-MP ÷ 4.2: `large` (15 MP) wins **2.5×**,
CLIC at 2–4 MP and smaller is a *loss*, extrapolating to ~9× at 36 MP — collapsing
Part A's superlinear blow-up. Sub-sampling penalty is small
(`large`: +0.62 worst), and the worst tile sat in a smooth region in only **3/113**
subjects (banding-in-smooth is a low-quality phenomenon, below this regime).

**B-refresh (free byproduct — and a correction).** Because the run does a full-frame
ssim2 search per image, it doubles as Part B on real content. The result corrects
the earlier fixture-based savings: at **target 88**, real photos land at **q91–93**,
*above* q90 → **negative savings** vs a q90 baseline on most sources (macro −8%),
positive only on `large` (15 MP, +17%, where camera detail needs only q84). The
40–58 % I reported on the synthetic fixtures was an artifact of that content.
**Caveat:** this is the benchmark's wide `[40,95]` bracket + target 88; the shipped
`[70,80]` caps at 80, so the *defaults recommendation is unchanged* — but "target 88
≈ q93 on photos" is real, and only a diverse corpus surfaced it. Side finding:
`qoi_web` hit target only 4/14 — JPEG can't reach SSIM 88 on text-heavy screenshots
(prefer WebP/PNG there).

**Conclusion:** crop-based scoring is the one shortcut that survives, now validated
across photographic, screen, and large content. It keeps the *real* metric at
*native resolution* and only sub-samples *space*, so it tracks the full-frame
boundary (p10, ±~1.5 pts) while making per-probe cost size-independent — a genuine
speedup for large images (above ~6 MP), the regime where the full search is
unaffordable. Caveats: calibrate the p10 threshold on `clic_holdout` (kept aside);
raise K or use saliency-guided tiles only if targeting very low quality.

### Part F — saliency tile selection vs the full-frame confirm (#359)

Part E flattens the *objective* search to a fixed ~4.2 MP budget but leaves the
**full-frame confirm + bump** (1–3 `O(pixels)` full-frame scores on the winner) — the
surviving size-dependent cost. Part F tests the high-value question: can a smarter
tile *selection* make the crop estimate accurate enough to **retire that confirm**,
making the whole search size-independent? Method (no production change): per image ×
selector × K, run the real search core (`EncodeSearch.search/3`) with a
selector-parameterized crop `score_fun` and **no `confirm_fun`** — that *is* the
confirm-skipped path — then take one full-frame score at the winner as ground truth.
Baseline = production-today (even + full-frame confirm @ K=16). The residual is
decomposed into the two parts that decide whether selection can help at all:

  * **sampling** = `selected_p10 − full_coverage_p10` — selection *can* shrink this.
  * **systematic** = `(full_coverage_p10 − offset) − full_frame_score` — the
    p10→full-frame mapping; selection *cannot* fix it (only per-content offset
    recalibration would).

Selectors: `even` (shipped), `source_detail` (source edge energy, candidate-independent),
`mixed` (half coverage + half source-detail), `diff_aware` (adds candidate-dependent
|source−candidate| + its high-pass energy — a per-probe upper bound, not
production-plausible). K ∈ {8,12,16,24}. Corpus subset (`clic`, `clic_holdout`,
`gb82_sc`, `qoi_web`, `large`; ≤10/source; 34 images where the confirm-backed baseline
hit target). `deliv_err`/`|samp|`/`|sys|` are macro-medians; `worst` is the global
undershoot tail; `regress` counts images that ship **below** target once the confirm
is skipped.

| K  | selector       | deliv_err | worst  | \|samp\| | \|sys\| | regress |
|----|----------------|-----------|--------|----------|---------|---------|
| 8  | even           | 0.47      | −1.86  | 0.26     | 0.50    | 9/34    |
| 8  | source_detail  | 0.44      | −2.61  | 0.43     | 0.48    | 8/34    |
| 8  | mixed          | 0.52      | −1.86  | 0.29     | 0.42    | 7/34    |
| 8  | diff_aware     | 0.88      | −1.86  | 0.33     | 0.50    | 7/34    |
| 16 | even           | 0.40      | −1.33  | **0.02** | 0.43    | 9/34    |
| 16 | source_detail  | 0.43      | −1.86  | 0.11     | 0.43    | 9/34    |
| 16 | mixed          | 0.39      | −1.86  | 0.06     | 0.40    | 10/34   |
| 16 | diff_aware     | 0.40      | −1.86  | 0.05     | 0.50    | 9/34    |
| 24 | even           | 0.40      | −1.34  | **0.00** | 0.50    | 9/34    |
| 24 | source_detail  | 0.39      | −1.33  | 0.08     | 0.40    | 10/34   |

(K=12 and the per-image rows are in `/tmp/autoquality_bench_part_f.csv`; the shape is
identical across K.)

**The residual is systematic-dominated, so no selector can retire the confirm.**
Across every K and selector `|systematic|` (~0.4–0.5 SSIM) dominates `|sampling|`, and
with even-spacing at K≥12 the sampling error is already ≈0 (K=24 even: 0.00). There is
essentially nothing for a smarter selector to fix — the gap between the crop p10
estimate and the full-frame score is the **p10→full-frame mapping** (the ±2–4 q
per-image offset spread Part E flagged), not *which* tiles are sampled.

**Saliency selection does not help, and sometimes hurts.** No selector reduces the
worst-undershoot tail or the regression count vs even-spacing; `source_detail` at low
K makes the worst case *worse* (−2.61 at K=8) by trading spatial coverage for
busy-region concentration — *raising* sampling variance, the opposite of the goal.
`diff_aware` adds ~133 ms/probe of candidate-dependent map work for no accuracy gain —
strictly dominated.

**Skipping the confirm is not free for any selector.** ~9/34 (26%) of the images the
confirm-backed baseline hit target ship **below** target with the confirm skipped
(worst −1.2…−2.6 SSIM), regardless of selector — exactly the cases the confirm's bump
rescues, and because their error is *systematic* the crop estimate cannot anticipate
them. On this corpus a single full-frame confirm is ~219 ms (baseline runs ~1.3 confirm
passes); the prize grows with image size, but it is not worth a 26% sub-target rate.

**Can a *cheaper aggregation* be the confirm instead?** If the gap is "p10-of-tiles vs
whole-frame", maybe a coverage **mean** tracks the full-frame score tightly enough to
stand in for the full-frame confirm at K-tile cost. Tested directly (residual =
`aggregate(tiles) − full_frame_score` at the delivered quality, 46 images): **no.**
Every aggregation shares the *same* ~4 SSIM worst-case tail after its own calibration —
aggregation only moves the offset, not the spread:

| aggregate | offset (median) | worst± (post-calibration) |
|-----------|-----------------|---------------------------|
| p10 K16   | 0.38            | 4.29                      |
| p25 K16   | 0.83            | 4.22                      |
| mean K16  | 1.80            | 4.01                      |
| mean full | 1.80            | 4.00                      |

`mean K16` (4.01) barely edges `p10` (4.29) — noise on a ~4-pt floor — and `mean K16` ≈
`mean full` (4.00) confirms **sampling contributes nothing**; the ~4-pt tail is purely
the content-dependent tile-aggregate↔full-frame mapping. A coverage-mean crop confirm
would still misjudge the worst image by ~4 SSIM, far outside the ±~1.5 best-effort band.
So a *crop-based confirm of any aggregation* is **not** viable; the only remaining lever
is **per-content offset calibration** (a learned/source-feature offset — the
"predict-then-verify" direction in the IQA/per-shot literature).

**First probe of the calibration lever — the cheapest rung fails.** Before any
source-feature model, the cheapest possible predictor is an OLS regression of the
full-frame score on the *tile-distribution shape* we already compute every probe
(`p10/p25/median/mean` of the K=16 tile scores, ± megapixels). Fit on the agg CSV (46
images):

| validation | worst± |
|------------|--------|
| in-sample (fit on all 46, optimistic) | **3.1** (vs ~4 single-aggregate) |
| `clic_holdout` only (photos) | 0.9 — *but misleading* |
| **leave-one-source-out (unseen class)** | **6.3–7.7** (driven by `large`) |

The single-class (`clic_holdout` = photos) holdout gives a false green light at 0.9;
**leave-one-source-out** — the honest "generalize to an unseen content class" test —
blows up to 6.3–7.7 SSIM on 15 MP `large` images and ~3.8 on `qoi_web` screenshots (and
adding `mp` makes `large` *worse* — extrapolation). Even *in-sample*, the residual won't
drop below ~3, and it lives specifically in screenshots (3.10) and large photos (2.33);
photographs and screen content already track ~1.3–1.5. So tile-distribution shape cannot
linearly explain the full-frame score for the hard classes. Per-content calibration
therefore needs **actual source/content features, per-class *and* per-size training
coverage, and a confirm fallback for unseen content** — a real calibration/ML project,
not a quick win — which is why it stays filed under "endgame, if needed."

**Conclusion:** even-spacing + p10 is already a near-optimal *spatial* sampler; the
full-frame confirm absorbs a *systematic, content-dependent* tile→full-frame residual
(~4 SSIM worst-case) that **neither tile selection nor a cheaper aggregation can
touch**. Saliency-guided selection does not earn a production change, and a crop-based
confirm cannot replace the full-frame one. The only lever left for cheapening the
confirm on large images is per-content offset calibration (or accepting a bounded
best-effort sub-target rate above the crossover). *Caveat:* capped single-machine run —
the portable conclusion is the **shape** (systematic ≫ sampling; selector- and
aggregation-invariant worst-case tail), not the absolute SSIM values.

### Part G — early-stop vs lowest-satisfying on the narrow format caps

Parts A–F attack the *per-probe* metric cost on **large** images. Part G asks the
opposite question on the **narrow per-format caps**, where the bracket is tiny — AVIF
`[60,65]` (6 qualities, ≤3 probes), WebP / JPEG `[70,80]` (11 qualities, ~4 probes) —
so the search space is small and the ROI of running to the *lowest-satisfying* quality
is in doubt: is the extra metric time worth the bytes it saves vs stopping early (or
not searching at all)? Measurement only — `EncodeSearch` is untouched; each stop policy
is replicated in the bench over a shared per-`(subject, format, q)` encode+decode+score
cache (so each variant's probes / metric ms / delivered bytes are its own), with
brackets resolved through the **real** production per-format caps, target 78,
`allowed_error 1` (band ≥77), full-frame scorer. Run over the pinned codec-corpus
(`--corpus-cap 12`, Apple Silicon, libvips 8.18.2). Δms / ΔkB are per-image vs the
*same image's* full search, macro-averaged over the 7 sources. A negative Δms is time
the full search spends that the variant saves; a positive ΔkB is bytes the full search
saves that the variant ships.

Macro-average per format (baseline = **full**, lowest-satisfying):

| format (bracket) | variant | Δms | ΔkB | Δ% | under-target | verdict |
|---|---|---|---|---|---|---|
| **jpeg** `[70,80]` (full: 1308 ms, 74% under) | wguard≤1–5 | 0 | 0 | 0% | 74% | ≡ baseline (never trips) |
| | wguard≤10 | −1528 | +20.98 | +5.9% | 56% | keep full search |
| | itercap=2 | −395 | +2.85 | +0.7% | 71% | keep full search |
| | itercap=3 | −16 | +0.27 | +0.2% | 74% | early-stop ≈ free |
| | first-accept | −569 | +6.60 | +1.7% | 65% | keep full search |
| | two-sided | −44 | +0.54 | +0.6% | 66% | marginal |
| | floor-first | −387 | 0.00 | 0% | 74% | win (floor clears) |
| **webp** `[70,80]` (full: 1045 ms, 89% under) | wguard≤10 | −1961 | +2.85 | +2.9% | 75% | keep full search |
| | itercap=2 | −554 | +0.32 | +0.5% | 85% | **early-stop wins** |
| | itercap=3 | −35 | +0.12 | +0.1% | 89% | **early-stop wins** |
| | first-accept | −136 | +0.50 | +0.6% | 85% | **early-stop wins** |
| | two-sided | −88 | +0.22 | +0.3% | 87% | **early-stop wins** |
| | floor-first | +432 | 0.00 | 0% | 89% | slower, no win |
| **avif** `[60,65]` (full: 706 ms, 56% under) | wguard≤5 (trips) | −1785 | +16.59 | +5.8% | 34% | keep full search |
| | itercap=2 | −239 | +0.56 | +0.3% | 52% | marginal |
| | itercap=3 | 0 | 0 | 0% | 56% | ≡ baseline (≤3 probes) |
| | first-accept | −904 | +4.96 | +2.0% | 44% | keep full search |
| | two-sided | −549 | +1.73 | +0.8% | 44% | marginal |
| | floor-first | −339 | −0.11 | −0.1% | 56% | win (floor clears) |

Reading:

- **The width guard is the wrong lever wherever it actually trips.** Skipping the
  search and encoding at `max_quality` *looks* free on a tiny bracket, but on real
  photographic / screen content even the narrow AVIF `[60,65]` bracket holds real byte
  spread: the full search recovers **+16.6 kB / +5.8%** on AVIF, **+21 kB / +5.9%** on
  JPEG (`[70,80]`, wguard≤10), **+2.9%** on WebP — and shipping `max_quality` *raises*
  the under-target rate's denominator (more bytes, scores above where needed). The
  width guard only ever "wins" by being a **no-op** — it never trips below the bracket
  width (AVIF at N=5, WebP/JPEG at N=10), and the moment it does trip it ships
  meaningfully bigger files. **A small search space does not imply a small byte
  payoff.**
- **The gentle early-stops (itercap / first-accept / two-sided) are format-dependent.**
  On **WebP** they are genuine wins (save 35–554 ms of metric, ship ≤0.5 kB / ≤0.6%
  more) — because WebP photos are best-effort-*under*-target by design (89% under), so
  the search mostly pins to the bracket edge and stopping early forfeits almost no
  bytes. On **JPEG/AVIF** the same stops recover less cleanly (+0.7–2.0% bytes for the
  aggressive ones), because those brackets more often contain a genuinely-lower
  satisfying quality worth finding. The only universally-free stop is dropping the last
  *confirming* probe (`itercap=3`, ≤0.2% bytes, ≈0 on AVIF), but its time saving is tiny
  (≤35 ms).
- **floor-first** is free when the floor clears the band (AVIF photos: q60 often clears
  → −339 ms, ΔkB ≈ 0) but a wasted probe when it doesn't (WebP/JPEG screenshots where
  q70 never clears → +432 ms, no win).
- **Amortization decides the marginal cases.** Every Δms is paid **once per cache
  miss**; every ΔkB is paid on **every cache hit**. So for cacheable traffic even the
  +0.3–2% ΔkB of the aggressive early-stops argues for keeping the full search (the
  bytes save forever, the probe cost is paid once); the early-stop only clearly wins
  when ΔkB ≈ 0 (WebP, `itercap=3`) or the content is low-hit / unique.
- A real-world aside surfaced by the run: large screenshots (`phoboslab.org.png`,
  >16383 px) **can't encode to WebP/AVIF at all** (codec dimension limit) and were
  skipped — for such sources the narrow-cap question is moot.

*Caveat:* single-machine, `--corpus-cap 12` run — the portable conclusions are the
**signs and rough magnitudes** (width-guard ships real bytes; WebP early-stops are
~free; JPEG/AVIF early-stops cost real bytes), not the exact ms/kB.

### Part H — crop+confirm vs full-frame target-hit confidence

Crop scoring (#354) runs above the 6 MP crossover: it estimates the full-frame score
from K tiles, then **confirms on the full frame** (+ up to 2 bump passes). Part H asks
how reliably that shipped path hits the target vs the full-frame search, by running
**both real production searches** (`EncodeSearch.run`, scorer `:full` / `:crop`) on the
same images at the production per-format brackets + target 78. The meaningful cohort is
the >6 MP images where crop actually engages — only `large` (~15 MP photos) and
`qoi_web` (big screenshots) qualify, **46 image×format cases** (`--corpus-cap 14`).

| | crop-regime cohort (46 cases, all formats) |
|---|---|
| full-frame hit target | 14/46 (**30%**) |
| crop+confirm hit target | 15/46 (**33%**) |
| **crop regressions** (full hit, crop missed) | **0/46 (0%)** |
| crop improvements (crop hit, full missed) | 1 |
| delivered Δscore (crop − full) | median **0.0**, worst undershoot **−0.24**, worst over +1.12 |
| bump fired / bump exhausted | 4/46 / 25/46 |

Reading:

- **Crop+confirm reproduces the full-frame target-hit decision essentially exactly** —
  zero regressions, worst delivered undershoot a quarter of a point, and for most images
  crop and full land on the *same* quality (Δscore median 0.0). The full-frame confirm
  fully absorbs the crop estimate's systematic residual, as designed. This is the
  evidence that crop scoring is safe to lean on harder (e.g. a lower crossover).
- **The low absolute hit rate (30%) is the bracket ceiling on hard content, not crop
  error.** These are large photos and text screenshots that can't reach SSIM 78 within
  `[70,80]`/`[60,65]`, so they ship best-effort under target *regardless of scorer* —
  full-frame also only hits 30%. The crop-vs-full *delta* is the confidence signal, and
  it's ~0.
- **"bump exhausted 25/46" is not crop failing 54% of the time.** Those are images where
  the confirm undershot and the 2-step bump couldn't reach target — but full-frame misses
  the *same* images (regressions = 0). It's the content/bracket ceiling; when crop
  *could* matter, the bump caught it (fired and recovered on 4).

*Caveat:* N = 46 because the corpus is light on >6 MP content, and it's exactly the hard
classes the #354 calibration flagged for the residual tail — so a fair stress test, and
crop still showed **zero target-hit regressions**. Portable conclusion is the shape (no
regressions; confirm absorbs the residual), not the 30/33%.

### Part I — raising `max_quality`: under-target drop vs byte cost vs latency

Parts G/H surfaced that most images ship *under* target because the bracket ceiling is
too low to reach 78, not because the search is wrong. Part I quantifies that lever: per
format, sweep `max_quality` (jpeg/webp `[80,85,90,95]`, avif `[65,70,75,80]`; first =
shipped default), keep `min_quality`, run the real lowest-satisfying search at each over
a shared per-`(image, q)` cache, and compare each candidate to the shipped-default
bracket on the *same* image. Full-frame scorer (Part H showed crop reproduces it),
codec-corpus, `--corpus-cap 12`.

| format (default) | cap | hit% | Δhit | avg ΔkB | Δmetric ms |
|---|---|---|---|---|---|
| **jpeg** (80) | 80 | 20% | — | — | — |
| | 85 | 20% | +0.0 | +26 | +84 |
| | 90 | 26% | **+6.6** | +71 | +108 |
| | 95 | 26% | +6.6 | +84 | +140 |
| **webp** (80) | 80 | 11% | — | — | — |
| | 85 | 13% | +2.7 | +43 (median +11.2%) | +105 |
| | 90 | 19% | **+8.0** | +68 (+12.8%) | +108 |
| | 95 | 20% | +9.3 | +80 (+12.8%) | +161 |
| **avif** (65) | 65 | 41% | — | — | — |
| | 70 | 44% | **+2.7** | +10 | +167 |
| | 75 | 44% | +2.7 | +12 | +295 |
| | 80 | 44% | +2.7 | +13 | +334 |

Reading — the cap is a **smaller lever than "30–89% under target" suggested**:

- **Modest, hard-diminishing lift.** jpeg maxes out by q90 (+6.6 pts), avif by q70
  (+2.7), only webp keeps creeping to q95 (+9.3). Even at the top of the sweep most
  images still miss target (jpeg 26%, webp 20%, avif 44%).
- **The cap only rescues the genuinely ceiling-pinned minority.** `allowed_error = 1`
  lets the search accept any quality scoring ≥ 77 and ship the *lowest* one — so a large
  share of "under target" images ship in-band at e.g. 77.4 *below the ceiling*, and
  raising the ceiling does nothing for them (that's why jpeg/avif median Δbytes is 0
  while the mean ΔkB is driven by the few ceiling-pinned images). webp is the most
  ceiling-starved, so it gains most **and** pays a broad +12.8% median.
- **The real dial for the large in-band-but-under-78 population is `target` /
  `allowed_error`, not the cap** — and `allowed_error = 1` was chosen precisely to ship
  smaller files. That's the doc's existing "target 78 is a high bar" finding (#2),
  re-confirmed from the other direction.

Sweet spots if more on-target is wanted: **webp → 90, jpeg → 90, avif → 70**; beyond
those is pure byte/latency cost. *Caveat:* this corpus is deliberately hard content
(photos/screenshots), so it's a conservative read — easier content (product shots,
graphics) converts more, more cheaply.

### Part J — sweeping `allowed_error`: on-target rate vs byte cost

Part I's other half. The cap only rescues *ceiling-pinned* images; the larger "under
target" population ships *in-band below the ceiling* because `allowed_error` accepts the
lowest quality scoring `≥ target − allowed_error`. The lever for that population is the
acceptance band. Part J sweeps `allowed_error` `[0, 0.5, 1.0, 1.5, 2.0]` at fixed target
78 (default 1.0), shipped brackets, over a shared per-`(image, q)` cache (the score is
band-independent), comparing each candidate to the default on the same image.

| format (bracket) | allowed_error | hit% | Δhit | median delivered score | avg ΔkB | Δmetric ms |
|---|---|---|---|---|---|---|
| **jpeg** `[70,80]` | 0 | 39% | **+19.7** | 77.05 | +1.8 | −1.4 |
| | 0.5 | 25% | +5.3 | 77.05 | +1.1 | −5.1 |
| | 1.0 (default) | 20% | — | 77.03 | — | — |
| | 2.0 | 16% | −3.9 | 76.20 | −4.0 | −21.0 |
| **webp** `[70,80]` | 0 | 25% | **+14.7** | 74.82 | +1.2 | −1.4 |
| | 1.0 (default) | 11% | — | 74.82 | — | — |
| | 2.0 | 8% | −2.7 | 74.82 | −1.3 | −14.2 |
| **avif** `[60,65]` | 0 | 63% | **+21.3** | 78.26 | +2.5 | +20.3 |
| | 0.5 | 52% | +10.7 | 78.04 | +1.1 | +2.0 |
| | 1.0 (default) | 41% | — | 77.50 | — | — |
| | 2.0 | 40% | −1.3 | 77.22 | −2.3 | −40.8 |

The surprise — **tightening `allowed_error` is a far cheaper on-target lever than the cap**:

- **Going `allowed_error` 1 → 0 buys +15–21 points of on-target rate for ~0–2.5 kB** (jpeg
  20→39%, webp 11→25%, avif 41→63%). Compare Part I: the cap bought +6–9 pts for +70 kB
  (jpeg) / +12.8% (webp). For avif the median delivered score crosses the target (77.5 →
  78.26) — the median avif image becomes on-target.
- **Why it's nearly free in bytes:** at `allowed_error = 1` the search deliberately ships
  images scoring 77.x (just under target). Tightening to 0 nudges exactly those
  boundary-sitters over the line — usually a single quality step, a few % each. The
  *median* image is untouched (it either clears both 77 and 78 at the same integer
  quality, or is ceiling-pinned and ships the ceiling regardless), so median Δbytes is 0%
  and the corpus-average cost is small; the lift comes from the ~15–20% of images sitting
  in `[77, 78)`. Latency is flat-to-lower (no extra probes).
- **It composes with the cap, doesn't replace it.** `allowed_error` flips
  *boundary-sitters* (reach 77, not 78); the cap (Part I) rescues *ceiling-pinned* images
  (can't reach 77). webp's median stays at 74.82 across the sweep because most webp images
  are ceiling-pinned below 77 — there `allowed_error` only flips the minority that *can*
  reach the boundary, and the cap is the lever for the rest.

*Caveat:* `allowed_error = 0` removes the band slack the crop confirm/bump leans on
(#354) — on >6 MP content it could raise bump-exhaustion (best-effort just under target)
slightly. And this is the hard-content corpus; the on-target lift is conservative.

## Findings & recommendations

### 1. Ship a non-zero `autoquality_max_resolution` default

Today
[`autoquality_max_resolution` defaults to `0`](../lib/image_pipe/parser/imgproxy.ex)
— i.e. **unbounded**: the ssim2 search runs at any resolution. Part A shows that
is unsafe (16 MP ≈ 4.7 s, 36 MP ≈ 20 s of CPU per request). Pick the cap from the
host's per-request latency budget against the cost curve above, remembering the
shipped `[70,80]` bracket runs ~4 iterations (≈⅔ of the tabulated 6-iteration
cost):

| latency budget for the search | ~MP cap (at shipped `[70,80]`, ~4 iters) |
|-------------------------------|------------------------------------------|
| ~0.8 s                        | ~4 MP                                     |
| ~1.7 s                        | ~9 MP                                     |
| ~3 s                          | ~16 MP                                     |

A conservative cross-host default of **~9 MP** keeps the worst case near
1–2 s on this machine while still covering the vast majority of real delivery
sizes; hosts on slower hardware or with tighter budgets should lower it. The
value should be documented as a latency knob, not left at unbounded.

### 2. The shipped objective/bracket defaults are sound; no change needed

ssim2 reliably lands at or above target across the source set, with sensible
best-effort behavior at the bracket edges. The benchmark's wide `[40,95]`/target-88
stress bracket exercised the search hard and surfaced no accuracy problem;
nothing in the data argues for changing the shipped `target`/bracket/`max_iterations`
defaults. (`max_iterations 6` is already generous for the `[70,80]` default
bracket, which needs only ~4 probes; lowering it would not help the dominant
metric cost on the wide-bracket worst case but would cap pathological brackets.)

Part E's real-content B-refresh adds one nuance, not a defaults change: **target 88
is high.** On clean photographs the search lands at q91–93 (above q90), so with a
wide bracket the *savings vs a q90 baseline are negative* on most sources (macro
−8 %; only 15 MP photos save, +17 %). The 40–58 % savings from the synthetic
fixtures were content-specific. This is correct behavior (88 simply *is* a high
perceptual bar) and the shipped `[70,80]` caps quality at 80 regardless; the
takeaway for hosts is that the **target choice**, not the engine, sets the
quality/size trade-off — pick it per content class (and note JPEG can't reach 88 on
text-heavy screen content at all: `qoi_web` hit 88 on only 4/14).

### 3. The downscaled-proxy-seed optimization is harder than it looks — do not ship the naïve form

The motivation still holds: a resolution cap only *disables* autoquality above the
threshold, forfeiting savings exactly on the large images where they matter, and
the proxy speedup is real (~3.9× at `k=2`, ~12× at `k=4`). **But the large-photo
test (recommendation follow-up) shows the naïve *downscale → search → deliver* form
fails on its own terms at production scale**, because SSIMULACRA2 is
resolution-dependent: the search on the downscaled proxy systematically *over-picks*
quality, and the over-pick grows with image size (+18q / +56–69% bytes on a 16 MP
photo). That inflates the delivered file well beyond the optimal full-res pick —
erasing the savings — and it is the *expensive* direction to correct (a cheap
one-pass confirm-and-adjust only rescues the rarer undershoot, not the over-pick).

So the earlier "ship `k≈2`" read was wrong — it was an artifact of testing only
≤2 MP sources. Revised guidance:

- **Do not ship a fixed-margin / fixed-`k` naïve proxy.** It over-charges bytes on
  real large images, defeating the point.
- **A viable proxy needs its target calibrated across resolution** — i.e. search
  the proxy against a *shifted* score that maps to the true full-res target for
  that downscale factor. That calibration is the actual research problem; this
  benchmark (`--part c --proxy-files …`) is the harness to derive and validate it.
- **In the meantime, the resolution cap (recommendation #1) is the safe shipping
  answer**, accepting that very large images fall back to fixed quality rather than
  paying a 4–20 s search or shipping an over-inflated proxy result.

The benchmark now ships with `--proxy-files` so this can be re-run on any corpus of
large images when the calibrated variant is prototyped.

### 4. Cheap-metric narrowing (#6) doesn't work with PSNR — needs a cheaper *perceptual* metric

Part D tested the other cost lever — keep the decision on full-res SSIMULACRA2 but
use a cheap full-res metric to cut the number of SSIMULACRA2 probes. PSNR is ~9–11×
cheaper but its value at the SSIMULACRA2 boundary varies 11–22 dB across content, so
a global threshold under/over-picks badly (−28q to +136% bytes). PSNR-class
narrowing is therefore not viable. The lever is only worth revisiting with a
cheaper *perceptual* metric (MS-SSIM, butteraugli) — neither is in our stack today —
or per-image SSIMULACRA2 anchoring, which saves ~0 probes on the shipped narrow
`[70,80]` bracket. Net: no change; the cost story stays as Parts A/C describe it.

### 5. Crop-based scoring (#1) is the one real speedup — prototype it for large images

Part E is the lever that works, now **validated per-source across the codec-corpus**
(photographic, screen content, huge screenshots, large photos). Scoring the *real*
SSIMULACRA2 on a *spatial subset* at *native resolution* tracks the full-frame
boundary (p10 offset median within ±1.5 pts on every content type; macro +0.22) —
because it changes *what area* is measured, not *the metric* or *the resolution*,
which is what sank Parts C and D. The screen-content generalization risk is
resolved. With a fixed K≈16-tile budget it makes per-probe cost size-independent: a
loss below the ~6 MP crossover (where full-frame is cheap anyway) but **2.5× at
15 MP** (the `large` source), scaling with size (~9× at 36 MP) — exactly the regime
where the full search is unaffordable.

Recommendation: switch the search to crop-scoring above an **internal ~6 MP
crossover** (full frame below it, where it's cheaper) — K p10-tiles per probe
against a threshold calibrated as `target + macro-offset`, plus one full-frame
confirm on the winner. Calibrate on `clic`, check on the held-out `clic_holdout`.
The crossover is **internal**, *not* the user-facing `max_resolution` cap (#1) —
keep one knob.

This also reshapes the cap's role. Crop-scoring flattens the **metric** (fixed
~4.2 MP scored, any size) but **not** the per-probe full-res **encode** (O(pixels)×N,
~4–5 s of encodes at 36 MP). That residual is bounded by a wall-clock **deadline**
(#355), and decode/memory is already bounded by `max_input_pixels` at the decode
step — so once crop-scoring + the deadline land, `max_resolution` is **redundant as a
cost guard**. It should then *retire* to an optional **policy** knob ("don't attempt
autoquality above X MP" → clean fixed-quality fallback), default high/off — it stays
a must-do *interim* guard only until those land. That is what turns "autoquality off
on big images" into "autoquality on, affordably."

#### Shipped calibration (#354)

Crop-scoring shipped in #354 (`ImagePipe.Output.Ssim2Metric.CropScore` +
`EncodeSearch`/`Encoder`), constants-only at the Part-E operating point
(`@tile 512`, `@subsample_k 16`, `@crossover_megapixels 6`). These are a
**validated single operating point, not a swept optimum** — confirming K/tile sit
at the accuracy↔cost knee is tracked in #359. The p10→full-frame
correction `@crop_macro_offset` was calibrated on a fresh `mix autoquality.bench
--part e` run over the pinned codec-corpus (Apple Silicon, libvips 8.18.2), which
reproduced the Part-E numbers:

| split / role | p10 offset (median) | spread |
|---|---|---|
| `clic` (calibration) | **+0.29** | −1.22…2.73 |
| `clic_holdout` (held-out validation) | **−0.03** | −1.12…1.8 |
| macro-average (all 7 sources) | **+0.22** | per-source −0.52…+1.46 |

- **Chosen `@crop_macro_offset = 0.22`** (the content-diverse macro-average,
  subtracted from the tile p10). The `clic` (+0.29) and held-out `clic_holdout`
  (−0.03) medians *disagree by ~0.3 SSIM*, which shows a photo-only constant would be
  mildly overfit; the macro is the robust global choice across photographic, screen,
  huge-screenshot and large-photo content. The 0.13/0.22/0.29 range is <0.5 q in
  effect, absorbed by the confirm/bump.
- **Confirm + bump cap = 2 (best-effort fallback), no escalation.** The per-image
  offset spread (~±2–4 q) means a small minority of images — chiefly in the `large`
  (+3.8 tail) and screen/screenshot sources — undershoot by more than the 2-step bump
  can recover and ship **best-effort slightly below target**. That is acceptable for a
  best-effort search (the full-frame oracle itself misses `large` 5/6 and `qoi_web`
  4/14 — JPEG cannot reach SSIM 88 on text-heavy screenshots), and the `allowed_error`
  band gives slack. The optional bounded-`[q+1, max]` full-frame escalation on
  cap-exhaustion remains available for hosts wanting stricter target-hitting.
- **Cost:** `large` (15 MP) **2.4× win** (655→268 ms metric per probe), `qoi_web`
  1.1×; a loss below the ~6 MP crossover (where full-frame is cheap), confirming the
  crossover. Sub-sample penalty ≤0.62; worst tile in a smooth region 3/113.

### 6. The narrow format caps don't justify an early-stop — keep the full search

Part G tested whether the tiny per-format brackets (AVIF `[60,65]`, WebP/JPEG
`[70,80]`) make running to the lowest-satisfying quality not worth the metric probes.
**They don't justify a change.** The search space is small but the byte payoff is not:
on real content the full search recovers real bytes even inside AVIF's 6-quality
bracket (+5.8%), and a width guard that skips to `max_quality` ships those bytes back
the moment it trips. The gentler early-stops (first-accept / two-sided / itercap) only
clear their byte cost on WebP — where photos are best-effort-under-target by design, so
stopping early forfeits ~nothing — and cost +0.7–2% bytes on JPEG/AVIF. Since the
metric cost is paid **once per cache miss** while the bytes save on **every cache hit**,
the amortization argues for the full search on any cacheable traffic.

Net: **keep the full binary search — don't skip probes — on the narrow caps.** This is
the opposite regime from #1/#5 — there the bracket is wide *and* the image is large, so
the per-probe metric cost dominates and crop-scoring earns its keep; here the bracket is
already tiny, so there is little metric time to win and a real byte cost to lose by
stopping early. The lone provably-free micro-stop (drop the final confirming probe, ≤0.2%
bytes) saves ≤35 ms and isn't worth the added policy surface.

This finding rejected the **two-sided** variant *on a byte basis only* (it sits among the
"early-stops" above). [#366](https://github.com/hlindset/image_pipe/issues/366) later
**adopted** two-sided as the production acceptance rule — not to save probes (it runs the
same full search) but to deliver the configured quality honestly (#9), accepting the
+0.3–0.8 % byte cost Part G measured. So #6's surviving conclusion is narrow: *don't skip
probes*. It is **not** an endorsement of floor-walking, which #366 replaced.

### 7. Crop scoring is trustworthy — safe to lean on harder

Part H validated the shipped crop path (#354) head-to-head against full-frame on the
same images: on the >6 MP cohort it produced **zero target-hit regressions** and a
worst delivered undershoot of −0.24 pts — the full-frame confirm fully absorbs the crop
estimate's systematic residual. Crop is not a quality risk. That de-risks two follow-ups
already on the table: **lowering the 6 MP crossover** (to capture the size-independent
per-probe metric cost on the 2–6 MP band that's still on full-frame — most real delivery
sizes) and **retiring `max_resolution` toward a policy knob** (#5), both of which lean on
"crop is safe." Validate a lower crossover on more >6 MP content first — Part H's N is
only 46 because the corpus is light on big images. No change to crop itself.

### 8. The bracket cap is a small per-format top-up, not the quality lever

Part I swept `max_quality` per format. Raising it lifts target-hit only **modestly and
with hard diminishing returns** (jpeg +6.6 pts by q90, webp +9.3 by q95, avif +2.7 by
q70; most images still miss target at the top of the sweep), because the cap only
rescues the genuinely *ceiling-pinned* minority. The larger "under target" population
ships *in-band below the ceiling* — under the old lowest-satisfying search by design (it
took the lowest q clearing `target − allowed_error`); #366's walk-to-target now ships that
population nearer the target instead (see #9), so the cap was never the lever for it. Net:
the cap is not a hidden quality win. If a host wants more on-target for a content class, the cheap top-ups are
**webp → 90, jpeg → 90, avif → 70** (beyond is pure byte/latency cost), and the real
quality/size dial remains `target`/`allowed_error` — a deliberate per-host choice, not a
defaults change. (Conservative read: this corpus is hard content; easier content
converts more cheaply.)

### 9. Walk-to-target is the shipped fix for the under-delivery Part J measured

**Superseded by [#366](https://github.com/hlindset/image_pipe/issues/366): the search now
walks to target.** Parts G and J both diagnosed the same defect in the *old*
lowest-satisfying search: it walked **down** to the floor (the lowest quality scoring
`≥ target − allowed_error`), so with `allowed_error = 1` it deliberately shipped boundary
images at ~77.x — systematically *under*-delivering the configured target. Part J showed
that tightening `allowed_error` 1→0 bought **+15–21 points of on-target rate for ~0–2.5 kB**
(jpeg 20→39%, webp 11→25%, avif 41→63%), and Part G's **two-sided** variant got the same
on-target lift structurally — converging toward the target instead of the floor — for
**+0.3–0.8 % bytes** (below the worth-optimizing threshold). #366 shipped the two-sided
variant as the production semantics:

- `allowed_error` is now a **symmetric** stopping tolerance: the search accepts the first
  quality in `[target − allowed_error, target + allowed_error]` and stops, rather than
  minimizing quality below the floor. The on-target lift Part J extracted by forcing
  `allowed_error → 0` is now delivered by default, at any band width.
- The big autoquality byte savings survive: easy images still ship at the lowest quality
  that *reaches* target (both semantics ship those identically); walk-to-floor only ever
  squeezed the thin `[target − ae, target)` sliver, which is exactly the under-delivery
  #366 removed.
- The default `allowed_error = 1` is retained — under symmetric semantics it is an
  intuitive ±1-point tolerance around the target, not a downward sacrifice.

So the lever hierarchy for **on-target rate**, cheapest first, under the shipped semantics:

1. **Lower `allowed_error`** — tightens the band around the target. With walk-to-target the
   default `1.0` already delivers near-target, so this is a fine-tuning knob, not the broad
   lift it was against the old floor-walking search.
2. **Raise `max_quality`** (#8) — a top-up for genuinely ceiling-pinned content, with real
   byte cost.

Both are **host policy choices, not defaults changes**. *Caveat:* a very tight
`allowed_error` shrinks the band the crop confirm/bump leans on for >6 MP content (#354,
#7), so pair an aggressive setting with a check on bump-exhaustion there.

## The bottom line across A–J

The SSIMULACRA2 quality boundary is **genuinely content-dependent and not cheaply
predictable by a *stand-in* for the metric** — neither a reduced-resolution proxy
(Part C) nor a cheap pixel metric (Part D) tracks it; both founder on the same rock.
But the boundary **is** recoverable by computing the *real* metric on a *spatial
subset at native resolution* (Part E) — that tracks within ±~1.5 pts and, as a fixed
tile budget, makes per-probe cost size-independent. So:

- **Ship now:** the resolution cap (#1, *interim* — see below), objective/bracket
  defaults unchanged (#2), the **walk-to-target** search ([#366](https://github.com/hlindset/image_pipe/issues/366),
  Part G's two-sided variant — converges to the target instead of the band floor, #9) on
  the narrow format caps (the small search space still has a real byte payoff, amortized
  away by caching), and the per-format `max_quality` caps unchanged (#8). Defaults stand;
  the two quality/size dials hosts should reach for, in order, are **`allowed_error` (band
  width around the target, #9)** then **`max_quality` (ceiling-pinned top-up, #8)** — both
  host policy, not defaults changes.
- **Don't ship:** the naïve proxy (#3), PSNR narrowing (#4), or saliency-guided tile
  selection (Part F) — even-spacing is already a near-optimal spatial sampler, and the
  full-frame confirm absorbs a *systematic* residual that tile choice cannot touch.
- **Prototype next:** crop-based scoring shipped (#5); the next step it unlocks is
  **lowering the 6 MP crossover** to capture the size-independent per-probe cost on the
  2–6 MP band — de-risked by #7 (crop produced zero target-hit regressions vs full-frame),
  pending validation on more >6 MP content. That plus a wall-clock deadline + the
  existing `max_input_pixels` make the resolution cap redundant as a *cost* guard, so it
  retires to an optional policy knob.
- **Endgame, if needed:** a cheaper perceptual metric in-stack, a learned per-content
  quality predictor, or — to cheapen the surviving full-frame confirm on large images —
  per-content offset calibration. (Part F ruled out the cheaper alternatives: neither a
  smarter tile *selection* nor a cheaper *aggregation* / crop-based confirm tracks the
  full-frame score within tolerance; the residual is systematic and content-dependent.)
  All larger efforts than this benchmark.
