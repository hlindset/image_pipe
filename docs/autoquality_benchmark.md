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
mise exec -- mix autoquality.bench --part all # A + B + C
mise exec -- mix autoquality.bench --mps 1,4  # custom Part A megapixels
mise exec -- mix autoquality.bench --proxy-factors 2,4 --proxy-mp 25  # Part C knobs
mise exec -- mix autoquality.bench --csv      # also write /tmp/autoquality_bench_part_{a,b,c}.csv
```

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

## The bottom line across A–D

The SSIMULACRA2 quality boundary is **genuinely content-dependent and not cheaply
predictable** — neither by reducing resolution (Part C) nor by a cheap pixel metric
(Part D). The metric cost (~83% of wall-clock, Part A) is therefore largely
intrinsic. The robust, shippable lever is the **resolution cap** (#1); the
search/objective defaults are sound (#2); and the two "make it cheaper" shortcuts
(proxy seed, cheap-metric narrowing) both founder on the same rock — a cheap or
low-res stand-in for SSIMULACRA2 doesn't track its boundary. A real speedup needs
either a cheaper perceptual metric in-stack or a learned per-content quality
predictor (the endgame), both larger efforts than this benchmark.
