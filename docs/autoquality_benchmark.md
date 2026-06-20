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
mise exec -- mix autoquality.bench --part all # A + B + C + D + E
mise exec -- mix autoquality.bench --mps 1,4  # custom Part A megapixels
mise exec -- mix autoquality.bench --proxy-factors 2,4 --proxy-mp 25  # Part C knobs
mise exec -- mix autoquality.bench --csv      # also write /tmp/autoquality_bench_part_{a,b,c,e}.csv
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
content type dominates), 512 px tiles, K=16 sub-sample. The honest tracking metric
is the *offset* `tile_p10 − full_frame_score` at the boundary — a calibrated global
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

**Cost win is large-image-only, confirmed.** K=16 is a fixed ~265 ms budget, so it
only beats full-frame above a **~6 MP crossover**: `large` (15 MP) wins **2.5×**,
while CLIC at 2–4 MP and everything smaller is a *loss*. The budget is constant
while full-frame grows ~linearly, so the win scales with size (extrapolating, ~9×
at 36 MP) — collapsing Part A's superlinear blow-up. Sub-sampling penalty is small
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

Recommendation: prototype crop-scoring behind the `max_resolution` threshold (#1) —
below the cap use the full frame; above it, score K p10-tiles per probe with a
threshold calibrated as `target + macro-offset`, plus one full-frame confirm on the
winner for safety. Calibration data already exists: calibrate on `clic` and check
on the held-out `clic_holdout`. This converts the cap from "disable autoquality on
big images" into "run it affordably," recovering savings on the images that matter.

## The bottom line across A–E

The SSIMULACRA2 quality boundary is **genuinely content-dependent and not cheaply
predictable by a *stand-in* for the metric** — neither a reduced-resolution proxy
(Part C) nor a cheap pixel metric (Part D) tracks it; both founder on the same rock.
But the boundary **is** recoverable by computing the *real* metric on a *spatial
subset at native resolution* (Part E) — that tracks within ±~1.5 pts and, as a fixed
tile budget, makes per-probe cost size-independent. So:

- **Ship now:** the resolution cap (#1), objective/bracket defaults unchanged (#2).
- **Don't ship:** the naïve proxy (#3) or PSNR narrowing (#4).
- **Prototype next:** crop-based scoring above the cap (#5) — the genuine speedup,
  turning the cap into "autoquality stays on, affordably" for large images.
- **Endgame, if needed:** a cheaper perceptual metric in-stack, or a learned
  per-content quality predictor — both larger efforts than this benchmark.
