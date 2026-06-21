# Crop-based ssim2 scoring for autoquality (#354)

**Status:** design, reviewed (4-reviewer disjoint cycle applied)
**Issue:** [#354](https://github.com/hlindset/image_pipe/issues/354)
**Boundary:** `ImagePipe.Output.*` only
**Predecessors:** #351 (autoquality + max_bytes search), #352 (benchmark harness), Part E of `docs/autoquality_benchmark.md` (validated approach). #353 (resolution cap) closed redundant; #355 (deadline) out of scope.

## Problem

The `:ssim2` autoquality objective binary-searches encoder quality at the
output/encode boundary (`ImagePipe.Output.EncodeSearch`). For `:ssim2`, **every
distinct probe does a full-resolution encode + decode + SSIMULACRA2 metric**, and
the metric dominates (~80–88% of wall-clock, Part A). The search runs on the
*finalized output*, already clamped by `max_result_pixels` (default 40 MP). At that
ceiling a full-frame search is ~20 s of CPU — enough to blow HTTP timeouts and pin a
scheduler. Today the only mitigation (`autoquality_max_resolution`) *disables*
autoquality above a threshold, forfeiting the savings on exactly the large,
high-detail images where they are positive (Part B: +17% on a 15 MP source).

## Validated approach (Part E)

Score SSIMULACRA2 on **K native-resolution tiles of the actual full-res encode**
instead of the whole frame, taking the **p10** of the tile scores. This changes
*which area* is measured, not the metric or the resolution — so it tracks the
full-frame quality decision (p10-tile offset median within ±1.5 pts ≈ ±2 q across
photos, screen content, huge screenshots, large photos; macro +0.22). With a fixed
K≈16-tile budget the scored sample is a flat ~4.2 MP (16 × 512²) regardless of
source size, so per-probe metric cost becomes size-independent: a **loss below a
~6 MP crossover** (full-frame is cheap there) but **2.5× at 15 MP**, scaling to ~9×
at 36 MP — collapsing the ~20 s worst case to low-single-digit seconds.

## Design

### 1. New module: `ImagePipe.Output.Ssim2Metric.CropScore`

File `lib/image_pipe/output/ssim2_metric/crop_score.ex`, inside the `Output`
boundary, nested under the ssim2 metric module (it *is* tiled ssim2 scoring; the
parent `Ssim2Metric` stays the thin "only module that touches `Ssimulacra2.*`"
adapter). Ports the validated prototype from
`test/support/mix/tasks/autoquality.bench.ex`:

- `tile_coords/3` + `axis_positions/2` — full-size 512px windows covering the frame;
  the last row/col is clamped to the edge (slight overlap) so every tile is full
  size and safe for SSIMULACRA2's multiscale downsamples. ≤512px axis → a single
  tile on that axis.
- `subsample/2` — K=16 evenly-spaced tiles (the cost lever); ≤K tiles → all of them.
- `percentile/2` — p10 over the sorted tile scores.
- A public entry `p10(base_image, candidate_image)`: given the finalized base image
  + the **decoded** candidate image (the caller decodes the encoded buffer once, the
  same `Image.from_binary` the full-frame `score_fun` already does — one shape, not
  binary-or-image), extract matching tiles via `Vix.Vips.Operation.extract_area`,
  score each pair through `Ssim2Metric.reference/1` + `Ssim2Metric.score/2`,
  subsample to K, return the p10 score (raw, no offset).

**Single-touchpoint invariant.** `CropScore` references **no** `Ssimulacra2.*`
symbol — *all* SSIMULACRA2 access goes through the parent `Ssim2Metric`, preserving
its role as the only module touching the NIF. (An architecture test can assert
`CropScore`'s source names no `Ssimulacra2.`.) `CropScore` does tiling +
`extract_area` (Vix) only.

**Failure routing.** `extract_area`, per-tile `reference`/`score` can fail at runtime
(libvips). These route through the **existing** channel: the crop `score_fun` closure
(built in `run/3`) throws `{:image_pipe_score_error, reason}` on any tile failure,
caught by `run/3` and mapped to `{:error, {:encode, reason}}` — identical to today's
`ssim2_score/2`. No new error shape.

Drops the benchmark-only `tile_texture`/HET binning. Constants documented here with
Part-E provenance (read by `Encoder` for the crossover decision, by the score_fun for
`@macro_offset`):

| constant | value | source |
|---|---|---|
| `@tile` | 512 | Part E operating point |
| `@subsample_k` | 16 | Part E (≈4.2 MP scored) |
| `@crossover_megapixels` | 6 | Part E crossover |
| `@macro_offset` | **calibrated** (Part E ≈ +0.22, recalibrate) | derived on `clic` |

K/tile/crossover/macro_offset are **internal constants**, not host config — the
issue explicitly forbids a second user-facing knob and treats dynamic-K selection
as future/exploratory.

### 2. Scorer selection — decided once in `Encoder`, built in `EncodeSearch`

The "which path" decision lives in **one** place (`Encoder`, beside the existing
`skip_search?`), not re-derived in `EncodeSearch`. `Encoder.stream_output` computes
the finalized image's megapixels **once** and resolves a single precedence ladder
(see §4) to one of `:skip | :crop | :full`, passing the scorer mode to
`EncodeSearch.run/3` via opts (e.g. `scorer: :crop | :full`). `EncodeSearch` does not
recompute MP.

`build_score_fun/2` then just **builds** the requested scorer for `:ssim2`:

- **`scorer: :full`** → today's full-frame `score_fun` (unchanged): one full-frame
  `Ssim2Metric.reference`, candidate scored whole. `confirm_fun: nil`.
- **`scorer: :crop`** → crop `score_fun` returning `CropScore.p10(base, candidate) −
  @macro_offset` (decoding `bytes` once via `Image.from_binary`), **plus** a
  full-frame `confirm_fun` and `confirm_band` for §3.

`@crossover_megapixels` is defined on `CropScore`; `Encoder` reads it from there (one
definition).

**Threshold folding (no new predicate).** The honest tracking statistic is
`offset = tile_p10 − full_frame_score` at the boundary. We want the crop path to
make the *same* accept decision as full-frame, whose objective predicate is
`full_score ≥ target − allowed_error`. At the boundary
`tile_p10 ≈ full_score + offset`, so crop should accept when
`tile_p10 ≥ (target − allowed_error) + macro_offset`. Implementing the crop
`score_fun` as `p10 − macro_offset` lets the **existing** objective predicate
`score ≥ target − allowed_error` be reused unchanged. (The issue's shorthand
"`target + macro_offset`" folds `allowed_error` differently; we calibrate the
constant empirically, so the principled form governs.)

The crop `score_fun` needs the *base* (finalized) image to build per-tile
references; `run/3` already has it. The full-frame mode is untouched, so a non-crop
request is byte-identical to today.

### 3. Confirm + bump — an objective-neutral re-validation hook

The crop `score_fun` returns an *estimate*; the delivered score must be the true
full-frame score. This is a **generic two-stage objective** pattern (a cheap estimate
selects a candidate; an authoritative measure confirms it), so the core's new phase
is expressed in objective-neutral, closure-injected terms — **no `:ssim2`/crop
literal in `search/3`**:

- The phase runs between `objective_phase` and `cap_phase` (so a later `max_bytes`
  `cap_phase` still binds the *final* delivered q — see §open-risks).
- It is parameterized by `confirm_fun` (quality → authoritative score) and a
  `confirm_band` number. `confirm_fun: nil` ⇒ the phase is a pure passthrough, so the
  full-frame and `:size`/`:none` paths are byte-identical to today.

Mechanics (crop mode supplies `confirm_fun` = full-frame `Ssim2Metric` score,
`confirm_band` = `target − allowed_error`):

1. **Confirm** — score the objective winner `q` via `confirm_fun` (1 pass;
   authoritative `meta.score`, memoized in a `confirm_memo`).
2. If `score ≥ confirm_band` → done, winner stands.
3. **Bump** — else linear-step `q+1`, `q+2`: re-encode (reuses the encode memo /
   `encode_fun`) + `confirm_fun` each; first that clears `confirm_band` wins.
   **Capped at 2 extra confirm passes** (`@max_bump_passes 2`). Linear (not binary)
   is a deliberate robustness choice: encoder score-vs-quality is only *approximately*
   monotone (the module's monotonicity contract), and a linear scan catches a local
   non-monotone dip at `q+1` that a binary step could skip.
4. **Cap-exhaustion fallback (data-gated, see §6).** If neither `q+1` nor `q+2`
   clears and `max_quality` headroom remains, the default ships best-effort at the
   highest q tried (`:best_effort`). **Escalation:** if calibration (§6) shows the
   cap-2 miss rate is not acceptably low, the fallback becomes a bounded full-frame
   `search_lowest_satisfying` over the tiny `[q+1, max_quality]` bracket (a handful of
   confirm passes over a ≤~10-wide bracket, only on the rare exhaustion path),
   preserving "clear target when reachable." Which fallback ships is decided by the
   calibration data, not assumed.

Worst-case crop-path full-frame cost (default) = **3 passes** (1 confirm + 2 bump);
typical (no undershoot) = **1**. This keeps the N-passes→1-pass win: the confirm is
the irreducible floor that *is* the issue's "low-single-digit seconds at the ceiling";
the tight bump cap stops the bump from eroding it.

**Why the cap is data-gated (review finding).** Part E's per-image residual is
±2–4 q (not ±2) and the p10-offset median varies ~2 pts across content types, so a
single global `macro_offset` + a hard cap-2 *could* leave a winner >2 q below the true
full-frame boundary, shipping best-effort under target with unused `max_quality`
headroom. Calibration must therefore **measure** the cap-2 miss rate and pick the
fallback accordingly; the global-offset-plus-bump design is only safe when the cap
covers the measured residual.

**Cost math (Part A/E numbers):**

| size | full search (~4 probes) | crop: 4 crop probes + 1 full confirm |
|---|---|---|
| 15 MP | 4 × 682 ms ≈ 2.7 s | 4 × 270 + 682 ≈ 1.8 s |
| 36 MP | 4 × ~3.0 s ≈ 12 s | 4 × 270 ms + ~3.0 s ≈ 4 s |

`run/3` builds a crop `score_fun` (objective phase) + a full-frame `confirm_fun` /
`confirm_band` when the caller passes `scorer: :crop`; the pure `search/3` core gains
the objective-neutral confirm phase but stays closure-injected and testable without
real images.

### 4. Encoder precedence (the one place MP is computed)

`Encoder.stream_output` keeps its shape; it computes the finalized image's
megapixels **once** and resolves one precedence ladder to `:skip | :crop | :full`:

1. Host `max_resolution` skip (if `> 0` and MP exceeds it) → encode once at the
   resolved quality (today's `:skipped` behavior, **unchanged**). **Skip wins.**
2. Else MP > `CropScore.crossover_megapixels()` → `scorer: :crop` search.
3. Else → `scorer: :full` search.

The chosen scorer mode is passed into `EncodeSearch.run/3`; `EncodeSearch` never
re-derives MP. (`skip_search?` and the crossover check share the same single
width×height/1e6 computation.)

`max_resolution` stays the host's "don't even try" policy knob; the crossover is the
internal scorer choice. Default `max_resolution = 0` ⇒ the crossover always governs.
This issue does **not** change `max_resolution` semantics (rec #5's "retire to a
policy knob" endgame is out of scope).

### 5. Telemetry

Extend the `[:encode, :search]` `:stop` meta with `scorer: :full | :crop`, and on
the crop path `tiles_scored` (K actually scored) and `confirm_passes`
(1 + bump steps). Product-neutral numbers, safe per Telemetry guidelines. Update
`ImagePipe.Telemetry.Logger`: the search-stop `message/3` surfaces the scorer while
still surfacing `:result`/outcome; add a `logger_test.exs` assertion; keep
`docs/telemetry.md` aligned. No new event names (so no new subscription wiring), only
meta fields on an existing span.

### 6. Calibration & validation

1. `mix autoquality.corpus` (one-time fetch).
2. Derive `@macro_offset` on the `clic` split; **validate on the held-out
   `clic_holdout` split** (never in-sample).
3. Because `clic*` is photographic only and the offset median varies ~2 pts across
   content types (gb82_sc −0.52 … large +1.46), **also check the chosen constant
   against the macro (all-source) holdout behavior** — including dimension/aspect
   diversity, since the edge-clamp tile overlap (§1) biases p10 in a
   dimension-dependent way. The global constant centers; the bump (§3) absorbs the
   per-content/per-image residual.
4. **Measure the cap-2 miss rate** (fraction of crop picks still below
   `target − allowed_error` after 2 bump steps, and by how many q). This is the gate
   that decides §3's fallback: best-effort (default) if misses are rare and small, or
   the bounded `[q+1, max]` full-frame search if not.
5. Re-run `mix autoquality.bench --part e --corpus <cache>`; record the chosen
   `@macro_offset`, the validated p10-offset, the bump-fire rate, and the cap-2 miss
   rate in `docs/autoquality_benchmark.md` (Part E / rec #5 follow-up).

### 7. Tests (TDD, focused at boundaries)

- **CropScore unit:** `tile_coords` over assorted W×H (full coverage; edge clamp /
  overlap on the last row-col; ≤512 axis → 1 tile; non-square); `subsample` (≤K → all,
  >K → K evenly-spaced); `percentile` p10 incl. n=1 and n=16 indices; `p10/2`
  end-to-end on a synthetic large image vs hand-computed tiles.
- **EncodeSearch (injected closures, no real images):** the confirm phase passthrough
  when `confirm_fun: nil`; confirm-no-bump (winner clears) → `confirm_passes == 1`;
  confirm-with-bump clears at `+1` → `confirm_passes == 2`; bump-cap exhaustion →
  `:best_effort` at highest q (default fallback); `meta.score` is always the delivered
  authoritative (full-frame) score, never the crop estimate. **`max_bytes` × bump
  ordering:** crop mode + a `max_bytes` where the bumped winner exceeds the budget —
  assert `cap_phase` still descends below the bumped q (the §open-risk this design
  explicitly worries about).
- **Wire-level (`Encoder.stream_output` or real `ImagePipe.call/2`), self-referential
  (no golden q):** build a deterministic input with the existing synthetic
  `Operation.zone` zone-plate at a **capped near-crossover size (~7–8 MP)** — *not* a
  15–36 MP image (keeps the test in low-single-digit seconds; avoids a multi-MB
  committed fixture + `SourceInventory` drift burden). Run **both** scorers on the same
  finalized image in-test and assert `abs(crop_q − full_q) ≤ 2` and the delivered
  full-frame score is within `allowed_error` of `target`. Separately: a small (<6 MP)
  output is byte-identical / `scorer: :full`.
- **Crossover-boundary engagement:** an input *just above* crossover (~6.x MP, 1–2
  tile grid on the short axis) asserting crop mode engages and the confirm runs
  against the real scorer — catches a scorer-switch off-by-one and exercises the
  `≤512 axis → 1 tile` / edge-clamp branches at the boundary (the unit test alone
  won't).
- **Telemetry:** assert/refute on the new `scorer` / `tiles_scored` / `confirm_passes`
  meta (riding the existing `[:encode, :search]` `:stop` span) with a **unique
  `telemetry_prefix`** — the default `[:image_pipe, …]` name leaks across async tests
  (and the existing `encode_search_telemetry_test.exs` would collide).
- Follow the test-not-to-write rules: no impossible-internal-misuse structs, no
  name/existence policing, no private-error-string pins. **No** sequential-vs-random
  materialization-gate test: the crop path runs on the already-finalized in-memory
  image inside the Output encoder (and `Image.from_binary`, already buffered), not a
  `Plan.Operation` on a streamed decode — it is outside that gate (confirmed in
  review).

### 8. Docs

`docs/imgproxy_support_matrix.md`: the autoquality search is an internal stage with
**no per-option knob**, so this is a **stage/pipeline** edit, not a surface one.
Constants-only ⇒ the option tables and the autoquality config rows are **unchanged**
(no new `IMGPROXY_AUTOQUALITY_*`).

Concretely, the **Save / encode row (line ~149)** currently describes the search as a
flat "binary search over encoder quality" — now stale for `:ssim2` above the
crossover. Update it to name the crop-scored ssim2 stage: above an internal ~6 MP
crossover, `:ssim2` scores K=16 native-resolution p10-tiles per probe (size-
independent metric cost) plus one full-frame confirm + bounded bump on the winner;
below it, the full-frame search is unchanged. Keep it framed as a config-less internal
stage like the other internal stages on that row.

`max_resolution` parity is preserved (it still *disables* the search above the host
cap — the crossover is strictly below it in precedence and only selects the scorer),
so **no `Diverges` note** and **no** imgproxy-parity claim: imgproxy's autoquality is
Pro/closed with no wire oracle, and ImagePipe already uses a different metric
(SSIMULACRA2 vs imgproxy DSSIM), so quality choice is already non-portable. The
behavioral axis (chosen quality / output bytes) is validated against ImagePipe's own
full-frame search via the benchmark, **not** against imgproxy. The compatibility
reviewer confirms this framing.

## Scope guardrails

- Production code only in `Output.*`.
- No new resolution cap (#353 redundant — search already bounded by
  `max_result_pixels`).
- No wall-clock deadline (#355).
- No second user-facing knob; crossover is internal.
- Dynamic/saliency K selection left as the issue's explicit future work.

## Resolved in review (4-reviewer disjoint cycle)

- **macro_offset folding** — *confirmed correct.* `p10 − macro_offset` against the
  unchanged band reproduces `tile_p10 ≥ (target − allowed_error) + macro_offset`; sign
  is right (offset +0.22 ⇒ p10 over-reports ⇒ subtract to recover the full estimate).
- **Materialization / sequential safety** — *outside the gate.* The crop path runs on
  the already-finalized in-memory base and the buffered `Image.from_binary` candidate
  inside the Output encoder; it is not a `Plan.Operation` on a streamed decode. No
  sequential-equivalence test (would test the wrong boundary).
- **Bump × `max_bytes` cap_phase ordering** — *resolved by §3:* the confirm phase runs
  **before** `cap_phase`, so the byte cap binds the final (possibly bumped) q; pinned
  by a dedicated closure test (§7).
- **Cap-2 vs residual spread** — *resolved by §3+§6 data-gating:* the cap stays 2 by
  default but calibration measures the miss rate and escalates to a bounded `[q+1,max]`
  full-frame fallback if needed.
- **Confirm/bump placement** — *resolved:* expressed as an objective-neutral,
  closure-injected phase (`confirm_fun`/`confirm_band`), no crop/ssim2 literal in the
  pure core; crossover MP decided once in `Encoder`.
- **imgproxy compatibility** — *resolved:* no wire oracle (autoquality Pro/closed),
  `max_resolution` parity preserved, no new option rows; only a stage-note edit to the
  Save/encode row (§8). No `Diverges` note, no parity claim.
