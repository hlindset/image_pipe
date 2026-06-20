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

Per source × downscale factor, full-res search vs. proxy-seed. `Δq = q_proxy −
q_full`; `delivered` is the true full-res SSIMULACRA2 score of the full-res encode
at `q_proxy`; `bytesΔ` is delivered bytes vs. the full-res optimum.

| source        | MP   | k | q_full | q_proxy | Δq  | delivered | Δtarget | hit | bytesΔ | speedup |
|---------------|------|---|--------|---------|-----|-----------|---------|-----|--------|---------|
| high_freq.jpg | 1.92 | 2 | 40     | 41      | +1  | 90.03     | +2.03   | yes | +2%    | 3.1×    |
| high_freq.jpg | 1.92 | 3 | 40     | 58      | +18 | 91.71     | +3.71   | yes | +19%   | 6.1×    |
| high_freq.jpg | 1.92 | 4 | 40     | 75      | +35 | 93.64     | +5.64   | yes | +49%   | 9.8×    |
| marker.png    | 1.92 | 2 | 74     | 83      | +9  | 90.26     | +2.26   | yes | +1%    | 3.5×    |
| border.png    | 1.92 | 4 | 73     | 73      | 0   | 88.71     | +0.71   | yes | 0%     | 9.6×    |
| placement.png | 1.92 | 2 | 90     | 90      | 0   | 88.85     | +0.85   | yes | 0%     | 3.3×    |
| placement.png | 1.92 | 4 | 90     | 90      | 0   | 88.85     | +0.85   | yes | 0%     | 8.9×    |
| zone-16MP     | 16.0 | 2 | 95     | 94      | −1  | 87.47     | −0.53   | **NO** | −7% | 3.6×    |
| zone-16MP     | 16.0 | 3 | 95     | 91      | −4  | 82.85     | −5.15   | **NO** | −19% | 7.0×  |
| zone-16MP     | 16.0 | 4 | 95     | 94      | −1  | 87.47     | −0.53   | **NO** | −7% | 9.6×    |

Aggregated per factor (5 real subjects + 1 adversarial synthetic):

| k | target hit @margin 0 | Δq mean / worst | margin that fixes | worst undershoot | worst byte overshoot | speedup |
|---|----------------------|-----------------|-------------------|------------------|----------------------|---------|
| 2 | 5/6                  | +3.2 / −1       | +1q               | −0.53            | +2%                  | ~3.4×   |
| 3 | 5/6                  | +6.0 / −4       | +4q               | −5.15            | +19%                 | ~6.7×   |
| 4 | 5/6                  | +9.3 / −1       | +1q               | −0.53            | +49%                 | ~9.7×   |

**The proxy method works, but its error is two-directional and content-dependent
— it is not a clean win:**

- **Real high-detail content over-picks quality** (Δq ≥ 0): the downscaled proxy
  loses the hard-to-compress detail, so the search on it reads the content as
  *harder* and picks a higher quality. The delivered full-res image clears the
  target (every real source hit, all k) — but the encode is **larger than the
  optimal full-res pick**, eroding the very savings autoquality exists to capture.
  At `k=4`, `high_freq` delivered **+49% bytes** vs. the full-res optimum (q75 vs.
  the correct q40).
- **The adversarial chirp under-picks** (Δq < 0): the zone-plate downscales into a
  lower-frequency zone-plate the metric scores more easily, so `q_proxy` lands
  below `q_full` and the delivered full-res score **undershoots** (e.g. `k=3`:
  82.85 vs. target 88). This is the quality-risk failure mode.
- **A single additive margin can't satisfy both directions** — the margin that
  rescues the undershoot makes the byte overshoot worse.
- **`k=2` is the sweet spot:** ~3.4× speedup with Δq in `[−1, +9]`, worst
  undershoot −0.53 (a +1q margin fixes it), and ≤+2% byte overshoot. Aggressive
  downscale (`k≥3`) trades that balance for speed.

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

### 3. The downscaled-proxy-seed optimization works, but needs the right shape

The motivation holds: a resolution cap only *disables* autoquality above the
threshold (the request falls back to fixed quality), forfeiting the 40–58% savings
exactly on the large, high-detail images where they matter most. And the speedup
is real — Part C measured ~3.4× at `k=2` up to ~9.7× at `k=4`, matching the `k²`
expectation.

But Part C also shows the naïve form — *downscale, search, deliver* — is **not** a
clean win: the quality-transfer error is two-directional and content-dependent
(real content over-picks → byte overshoot up to +49%; the adversarial chirp
under-picks → quality undershoot), and a single additive margin can't fix both.
Two shapes survive the data:

- **Modest downscale (`k≈2`)** — ~3.4× faster with Δq in `[−1, +9]`, ≤+2% byte
  overshoot, and a +1q margin covering the only undershoot. Simple; most of the
  win with little risk.
- **Confirm-and-adjust for aggressive downscale** — search on the proxy, then do
  the *one* full-res confirm metric (already part of the per-request budget — it's
  a single pass, vs. the 4–6 the full search runs) and bump quality if it missed.
  This makes the method robust at high `k` (the only way to keep both quality and
  savings when the bias is large).

Recommendation: prototype `k≈2` first (cheapest, lowest-risk), and gate anything
more aggressive behind a full-res confirm. Do **not** ship a fixed-margin proxy.
Note the accuracy caveat above — the large-scale real-content signal is inferred,
so validate on genuinely large photos before committing to a default `k`.
