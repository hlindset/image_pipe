# Butteraugli as a pluggable autoquality metric provider

**Date:** 2026-06-24
**Status:** Design — approved, pending spec review
**Depends on:** JPEG XL output (#384, merged), autoquality content-class offsets (#382), confirm-skip crop proxy (#369)

## Summary

Add **butteraugli** as a second autoquality quality metric alongside the existing
ssimulacra2 metric. Today the metric is effectively singular: `Plan.Output.QualitySearch`
carries `objective: :size | :ssim2`, and `Output.EncodeSearch` measures quality through
the lone `Output.Ssim2Metric` adapter. This work makes the metric a **pluggable provider**:
the plan names *which* metric, parsers translate their dialect syntax into a per-provider
plan struct, and Output owns one runtime module per metric carrying all metric semantics
(polarity, valid range, the `reference`/`score` calls). At **resolve** time — where the output
*format* is known — Output picks an **execution strategy** from `(metric, format)`: an
external-measure search for most pairings, or a **native** strategy when the encoder has a knob
that already targets the metric (JPEG XL's `distance` *is* butteraugli distance).

The butteraugli runtime is the unpublished NIF at
[hlindset/butteraugli](https://github.com/hlindset/butteraugli), depended on by commit SHA
(not a hex release).

## Goals (this cycle)

1. **Provider abstraction.** A metric is a behaviour implemented by one Output runtime module.
   Adding a metric is a new struct (Plan), a new runtime module (Output), a one-line dispatch
   entry, and a hand-wired clause in whichever dialect parser should expose it.
2. **Per-provider plan shapes.** Replace the single `QualitySearch` struct with a family:
   `QualitySearch.{Size, Ssimulacra2, Butteraugli}`. Struct identity encodes objective + metric;
   illegal field combinations become unrepresentable.
3. **Polarity-neutral search.** The external-measure band search reads `direction` from the metric
   runtime so ssimulacra2 (higher-is-better) and butteraugli (lower-is-better, a *distance*) share
   one loop.
4. **Resolve-time strategy selection (the native-JXL seam).** `resolve_search` maps `(metric,
   format)` → an execution strategy. `Butteraugli` + JPEG XL selects a self-contained
   **`NativeJxlButteraugli`** strategy: it clamps `target` into the `min/max_quality` bracket (via
   libjxl's Q→distance formula) and encodes once at that distance, never invoking the external NIF;
   if a `max_bytes` budget is present it runs its *own* small search — raising `distance` (degrading
   quality) until the bytes fit — so it is self-capping. This is the clean home for the JXL escape
   hatch (originally scoped as "B"): the seam is the resolver's `(metric, format)` dispatch, not a
   mid-loop metric callback. Requires exposing the JXL `distance` encoder suffix (currently only
   `Q=` is wired; libvips `jxlsave` exposes
   `distance`, gdouble, min 0 / max 25, literally named *"Target butteraugli distance"*).
5. **C-seam: crop aggregation polarity.** Carrying `direction` makes the crop aggregation
   (p90/max-of-distances + *additive* offset, mirroring ssim2's p10 + subtractive offset) fall
   out of the same code — but see Non-Goals: butteraugli ships **full-frame-only** this cycle.
6. **imgproxy URL surface.** An `aq:butteraugli:<target>:<min>:<max>:<allowed_error>` clause,
   documented as a deliberate divergence/extension in the imgproxy conformance matrix.

## Non-Goals (deferred to later cycles)

- **ssim2 → butteraugli-distance conversion.** Only `(butteraugli, JXL)` selects a native
  strategy. `(ssim2, JXL)` keeps the external Q-search — an ssim2 target cannot drive JXL's native
  distance knob until a calibrated ssim2→distance conversion is built. The resolver simply has no
  native clause for ssim2; nothing special is needed to "fall back."
- **butteraugli crop proxy.** The aggregation seam lands (polarity), but butteraugli is
  **crop-disabled**: it always scores full-frame regardless of resolution. ssim2 keeps its
  crop proxy. Enabling butteraugli's crop proxy requires a calibration bake (next non-goal).
- **The calibration bake.** The Part-K-equivalent measurement of butteraugli's crop→full
  residual distribution, and the offset table it would populate, is its own empirical cycle.
  We do *not* assume the residual is as systematic/bounded as ssim2's; that is the thing the
  bake must prove before crop is trusted for butteraugli.
- **Exposing NIF tuning knobs** (`intensity_target`, `hf_asymmetry`). Not even as struct
  fields; added when a use case appears.
- **Other dialects.** Only the imgproxy parser learns `aq:butteraugli` this cycle. TwicPics/
  IIIF wiring is per-dialect and out of scope.

## Architecture

Division of labor across boundaries (which the design is built to respect — `parser` may not
depend on `output`):

### Plan boundary — the known shapes

Per-provider structs under `ImagePipe.Plan.Output.QualitySearch.*`. No polarity, no ranges,
no token order — pure neutral configuration shapes a parser may emit.

```elixir
%QualitySearch.Size{target_bytes, min_quality, max_quality}
%QualitySearch.Ssimulacra2{target, min_quality, max_quality, allowed_error}
%QualitySearch.Butteraugli{target, min_quality, max_quality, allowed_error}
```

```elixir
# Plan.Output
@type quality_search ::
  :none
  | QualitySearch.Size.t()
  | QualitySearch.Ssimulacra2.t()
  | QualitySearch.Butteraugli.t()
```

`min_quality`/`max_quality` are duplicated across the three structs (the shared search
bracket) rather than factored into an embedded sub-struct — two fields is cheaper than the
indirection.

The `{format, content-class} → offset` policy (`Plan.Output.quality_search_offsets`,
`offset_for/3`) is unchanged in shape; it remains an ssim2-crop concern this cycle (butteraugli
is full-frame, so it never consults an offset).

**Struct-split fan-out (consumers of the old single `QualitySearch`).** Replacing the one struct
with a family is mechanical but touches load-bearing consumers the rest of this spec assumes; each
is an explicit plan item, not incidental:
- **`Cache.Key.quality_search_key/1`** pattern-matches the single struct and reads `.objective`.
  It must become per-struct clauses so cache identity stays deterministic *and* distinguishes
  ssim2 vs butteraugli at the same numeric target. Reshape the canonical key data in place
  (greenfield — no key data-version bump) and update `cache_key`/`cache_key_test`.
- **Plan boundary `exports:`** lists `Output.QualitySearch` (singular); add the three sub-structs,
  and update the **exact-match** mirror in `architecture_boundary_test.exs` (the Plan-exports
  assertion uses `==`, so an incomplete list fails the arch suite — this is a forced edit, not
  polish). State the final export set explicitly in the plan.
- **`Plan.Output` typespec** `quality_search :: :none | QualitySearch.t()` becomes the union above;
  the old `QualitySearch.@type objective :: :size | :ssim2` is removed.

### Parser boundary — per-dialect, hand-wired translation

Each dialect parser translates its own syntax into the right `QualitySearch.*` struct, owning
its token order. This is deliberately manual: no auto-discovery, no neutral arg-schema. Adding
a metric to a dialect is an explicit edit to that dialect's adapter.

imgproxy (`Parser.Imgproxy.OptionGrammar`) gains:

```elixir
defp parse_autoquality(["butteraugli" | rest], segment) when length(rest) <= 4 do
  with {:ok, fields} <-
         parse_autoquality_args(rest, [:target_distance, :min_quality, :max_quality, :allowed_error]) do
    autoquality_result([metric: :butteraugli] ++ fields, segment)
  end
end
```

The `:target_distance` field spec is **new** and butteraugli-specific. It must *not* reuse the
existing `:target_float` spec, which hard-clamps to `0.0..100.0` (the ssim2 range). `:target_distance`
enforces `0.0..25.0` — the **parser is where target-range validation lives** (revised during plan
review; see below).

The existing `aq:ssim2:…`, `aq:size:…`, `aq:dssim`, `aq:none` clauses keep their behavior;
they now build `QualitySearch.Ssimulacra2` / `QualitySearch.Size` respectively.

The `metric: :butteraugli` tag above is a **parser-internal keyword**, not a struct field:
the grammar emits a flat keyword list, and `Parser.Imgproxy.Options` consumes the tag to decide
*which* `QualitySearch.*` struct to construct. The constructed struct carries no `metric` atom —
its identity is the metric.

`Parser.Imgproxy.Options` gains `@default_butteraugli_target 1.0` next to `@default_ssim2_target 78`,
and resolves URL-omitted butteraugli fields from host `autoquality_*` config the same way ssim2
fields resolve today. **Butteraugli's default `min/max_quality` bracket is full-range (`1`/`100`)**,
*not* ssim2's `70`/`80`: because `dist(80) = 1.9 > 1.0`, a default ceiling of `80` would clamp
essentially every `target 1.0` request down to Q80 on the native path. Full-range defaults keep the
bracket inert unless the user explicitly narrows it (the guardrail bites only when asked for).

**Target-range validation is parser-side** (revised during plan review). The existing ssim2 path
*already* range-validates at the parser — `:target_float` rejects outside `0.0..100.0`.
`:target_distance` mirrors that (rejects outside `0.0..25.0`), and `resolve_quality_search_target`
validates the config-resolved target too, so a host-config default out of range is caught, not just
URL tokens. This keeps `Output.Policy`'s resolve **infallible** (it is reached through the
infallible `resolved/1`, whose error-threading blast radius spans `producer.ex` and the HDR path).
`Output.Metric.target_range/0` stays the source-of-truth constant the parser mirrors (a literal, no
parser→Output dependency — same as `:target_float`'s inline `0–100`) and the native-JXL clamp uses.

> Note: `aq:butteraugli` is an ImagePipe extension — imgproxy has no butteraugli autoquality
> method (its set is `none|size|dssim|ml`), so there is no upstream behavior to match or diverge
> from. The existing `aq:ssim2/size/dssim/none` forms are untouched because the struct split keys
> off the existing `objective:` tag; the new clause adds a separate `metric:` tag and never edits
> the old paths. The matrix is synced per the conformance-doc rule (see Documentation), not for
> parity.

### Output boundary — one runtime module per metric

A metric runtime behaviour, implemented per provider. This is where the *measurement* semantics
live (used by the external-measure strategy); the parser never sees it. There is no
`native_encode_param` callback — native realization is a resolve-time *strategy* decision (below),
not a metric capability.

```elixir
defmodule ImagePipe.Output.Metric do
  @callback direction() :: :higher_better | :lower_better
  @callback target_range() :: {number(), number()}
  @callback reference(Vix.Vips.Image.t()) :: {:ok, term()} | {:error, term()}
  @callback score(reference :: term(), Vix.Vips.Image.t()) :: {:ok, float()} | {:error, term()}

  def runtime(%QualitySearch.Ssimulacra2{}), do: __MODULE__.Ssimulacra2
  def runtime(%QualitySearch.Butteraugli{}), do: __MODULE__.Butteraugli
end
```

```elixir
defmodule ImagePipe.Output.Metric.Butteraugli do
  @behaviour ImagePipe.Output.Metric
  def direction,        do: :lower_better
  def target_range,     do: {0.0, 25.0}   # = libvips jxlsave `distance` min/max
  def reference(img),   do: Butteraugli.Vix.reference(img)
  def score(ref, cand), do: with({:ok, %{score: s}} <- Butteraugli.Vix.compare(ref, cand), do: {:ok, s})
end
```

`Output.Metric.Ssimulacra2` is the existing `Ssim2Metric` adapter renamed/relocated to fit
the behaviour, with `direction/0 => :higher_better` and `target_range/0 => {0, 100}`.

`target_range {0.0, 25.0}` is not a guessed sanity bound — it is exactly libvips `jxlsave`'s own
`distance` range (`min 0, max 25`), which doubles as the ceiling for the native strategy's
`max_bytes` distance-degradation search.

The headline butteraugli **distance** (`Result.score`, the max — what JXL's `distance` is
calibrated against, 1.0 ≈ visually lossless) is the targeted value. `Result.pnorm_3`/`diffmap`
are unused this cycle.

> Caveat (deferred to the calibration bake): the search compares a candidate's measured distance
> against `[target ± allowed_error]`; the measured value is `Result.score` (the **max** distance).
> `score` is the *correct, conventional* target — it's what the butteraugli CLI and JXL's `distance`
> knob mean (so it's mandatory on the JXL native path for calibration consistency) — but as a
> *search* signal it's a jumpy extreme-order statistic: one bad block at one `q` can spike it
> non-monotonically. `pnorm_3` (a smoothed 3-norm pooling) moves more steadily with `q`, **but it is
> not a free swap**: since `pnorm_3 ≤ score` always, comparing a target of `1.0` against `pnorm_3`
> is a stricter, *different* perceptual bar than against `score`, and no longer matches JXL's
> `distance=1.0`. The band search tolerates local non-monotonicity (it ships a probed `q` within
> `[min,max]`, same as ssim2 today), so `score` won't *break* the search. We ship `score` (one
> definition across native + search). If the bake shows poor convergence, the remedy is to use
> `pnorm_3` as a smoothed internal proxy **with a measured offset back to the `score` scale** — not
> to redefine the target — which is exactly what the bake would calibrate.

### Output — search loop, resolve, encoder

- **Resolve-time strategy selection.** `Output.Policy.resolve_search(plan_search, format)` maps the
  neutral plan struct + the negotiated format to a resolved **execution-strategy** struct. The
  resolved family is `Resolved.QualitySearch.{Size, Ssimulacra2, Butteraugli, NativeJxlButteraugli}`
  — one more than the plan family, because `Butteraugli` expands by format:
  - `%Plan…Size{}`        → `%Resolved…Size{}`            (byte search)
  - `%Plan…Ssimulacra2{}` → `%Resolved…Ssimulacra2{}`     (external-measure, ssim2 runtime)
  - `%Plan…Butteraugli{}` + JPEG XL    → `%Resolved…NativeJxlButteraugli{}`  (native distance)
  - `%Plan…Butteraugli{}` + other fmt  → `%Resolved…Butteraugli{}`           (external-measure, butteraugli runtime)

  The `(metric, format)` → strategy mapping *is* the generic native seam; a future format/metric
  with a native knob adds one resolver clause + one strategy. Plan stays format-agnostic — the
  native-ness appears only here, in the Output resolve layer. `resolve_search` is **infallible** —
  target-range validation is parser-side (above), so resolve never returns an error and the
  infallible `resolved/1` chain is undisturbed.
- **`EncodeSearch` dispatches on the resolved struct** to a strategy. `Size`, `Ssimulacra2`, and
  (non-JXL) `Butteraugli` run the **external-measure** band search below; `NativeJxlButteraugli`
  runs the **native** strategy further below. Struct identity carries the strategy intact into the
  loop — no atom re-derivation.
- **External-measure band search** (`Ssimulacra2` / non-JXL `Butteraugli`) reads `direction` from
  the runtime to orient the walk-to-target band. The band membership test
  `[target − allowed_error, target + allowed_error]` is polarity-symmetric and unchanged. **Every
  *directional* arm must invert for `:lower_better`, and the spec calls them out explicitly so the
  implementation doesn't merely "conceptually flip" them:**
  - **Walk arms** (`do_target`): for ssim2, `score > band_hi` ⇒ over-quality ⇒ search *lower*;
    `score < band_lo` ⇒ search *higher*. For butteraugli these swap — `score > band_hi` means the
    *distance* is too large = quality too low ⇒ search *higher*; `score < band_lo` ⇒ search *lower*.
  - **Overshoot accumulator + `resolve_target`**: the "remember the cheapest still-acceptable q,
    ship it if the band is straddled" fallback accumulates on the higher-is-better branch today;
    for `:lower_better` it must accumulate on the mirror branch, and the "never reached the band"
    pin flips which bracket end (`ceiling` vs `floor`) it lands on. The `limiting_factor` label
    must stay semantically honest under inversion.
  - **Moduledoc monotonicity contract** (`encode_search.ex`) states "SSIMULACRA2 score is
    non-decreasing in quality"; update it to record that butteraugli distance is
    non-*increasing* in quality, and that the loop branches (not negates) so each arm is audited.
  - The size objective phase and the byte-budget predicates (`cap_phase`, `search_highest_satisfying`)
    are monotone in bytes regardless of metric and are **unchanged**.
- **`NativeJxlButteraugli` strategy** — fully self-contained; it never invokes the external NIF and
  never calls the generic `cap_phase` (it *is* its own cap). It honors `min/max_quality` as a real
  guardrail (they are **not** no-ops here), via a one-encode distance clamp:
  - **Quality-bracket clamp (runs first).** `min/max_quality` are Q-scale; convert them to distances
    with libjxl's Q→distance formula `dist(Q)` (monotone-decreasing, so a Q *ceiling* is a distance
    *floor*) and clamp the target:

        effective = clamp(target, dist(max_quality), dist(min_quality))

    `dist/1` is the piecewise libjxl formula (`30 ≤ Q < 90: 0.1 + (100−Q)·0.09`; `90 ≤ Q < 100:
    (100−Q)·0.10`; `0 < Q < 30: 15.0 + (59·Q − 4350)·Q/9000`; `Q ≤ 0: 15.0`). An explicitly-set
    `max_quality` can therefore never be exceeded on JXL — the clamp ships exactly what `Q=max_quality`
    would. The coupling to libjxl's formula is **pinned by a drift-guard test** (below).
  - **No `max_bytes`:** one encode at `distance = effective`. `meta` reports `outcome: :native`,
    `iterations: 0`, `score: nil` (`:native` added to `@type outcome`; `limiting_factor_for/2`
    already falls through to `nil` for an unknown outcome).
  - **With `max_bytes` (runs after the clamp):** start at `distance = effective`; if the encode
    exceeds the budget, **raise `distance` (degrade quality) until the bytes fit** — a small search
    over the native distance knob, measuring only bytes, bounded above by `target_range` max (25).
    `max_bytes` is the hard cap, so it may push past the `min_quality`-floor if the budget demands
    it — same precedence as `cap_phase` today. If even max distance can't fit, ship best-effort at
    max distance with `limiting_factor: :max_bytes`.
  - **Encode failure** routes through `run/3`'s normal `{:error, {:encode, _}}` tuple — *not* the
    `{:image_pipe_score_error, _}` throw/catch, which only wraps the external-measure `search/3`
    call and is not armed on this path.
- **C-seam / crop:** butteraugli is full-frame-only. The crop-proxy crossover (`CropScore`, 6 MP)
  applies to ssim2 only. Today two guards gate crop on the atom `objective: :ssim2`
  (`encoder.ex` `crop?/2`; `encode_search.ex` `:crop` `score_opts`); because `ResolvedQualitySearch`
  splits into per-strategy structs, **these guards must be rewritten to match the *Ssimulacra2
  struct type*, with both butteraugli resolved structs (`Butteraugli` and `NativeJxlButteraugli`)
  falling through to `:full`** — a too-loose guard (`%{objective: _}`) catching butteraugli is
  exactly where a regression would sneak in. (The native strategy doesn't measure at all, so it is
  trivially full-frame; the external non-JXL butteraugli is full-frame by this gate.) The crop
  aggregation's polarity is **not** generalized this cycle (it stays ssim2-shaped, untested for
  inversion) since butteraugli never reaches it; the polarity seam lands with the deferred crop
  proxy, not now. The offsets resolver populates `quality_search_offsets` only on the ssim2 resolve
  path, so a butteraugli resolve clause that omits offsets means butteraugli never consults one.
- **Encoder:** the JXL encoder learns a `distance` suffix in addition to `Q=`, so the
  `NativeJxlButteraugli` strategy can encode at a chosen distance (`.jxl[distance=…]` via libvips).
  The existing `Q=` path is untouched.

## Data flow

```
URL  aq:butteraugli:1.0:70:80:0.1
  │  Parser.Imgproxy.OptionGrammar  (hand-wired clause, owns token order)
  ▼
%Plan…QualitySearch.Butteraugli{target: 1.0, min_quality: 70, max_quality: 80, allowed_error: 0.1}
  │  Output.Policy.resolve_search(search, format)   (infallible: pick strategy only — the target
  │     range 0.0..25.0 was already validated parser-side, keeping resolve total — see §Validation)
  │     format == :jpeg_xl  → %Resolved…NativeJxlButteraugli{target: 1.0, …}
  │     else                → %Resolved…Butteraugli{target: 1.0, …}
  ▼
Output.EncodeSearch.run/3  — dispatch on resolved struct:
  │  %Resolved…NativeJxlButteraugli{}:
  │     effective = clamp(target, dist(max_quality), dist(min_quality))  (libjxl Q→distance)
  │     max_bytes == nil → encode once at distance=effective          (outcome: :native, iters 0)
  │     max_bytes set    → raise distance from effective until bytes fit (self-capping, no NIF)
  │  %Resolved…Butteraugli{} (non-JXL):
  │     external-measure band search via Output.Metric.Butteraugli   (direction :lower_better,
  │     full-frame Result.score) → then cap_phase for max_bytes
  ▼
{:ok, binary, meta}
```

## Error handling

- **Out-of-range target** — parser-side validation error (the `:target_distance` field spec and
  `resolve_quality_search_target`), surfaced before plan construction, consistent with how the
  existing `:target_float` ssim2 range rejection works.
- **Score failure (external-measure strategy)** — `runtime.score/2` returning `{:error, reason}`
  is caught the same way the existing ssim2 score-error path is
  (`throw({:image_pipe_score_error, reason})` → `{:error, {:encode, reason}}`). The butteraugli
  NIF's `:timeout`/`:cancel` paths surface as score errors. (The native strategy never measures, so
  this path doesn't apply to it; its encode failures use the encoder error tuple.)
- **NIF unavailable** — butteraugli is a hard dependency once added; a missing precompiled NIF
  is a build/boot failure, not a runtime degradation. (No silent fallback to ssim2.)

## Testing

- **Plan/struct** — the three `QualitySearch.*` structs with `@enforce_keys`; no hand-built
  internal-misuse tests (per project test discipline).
- **Parser** — `aq:butteraugli:…` grammar + order/default resolution → `QualitySearch.Butteraugli`;
  existing ssim2/size/dssim/none clauses still produce their structs.
- **Metric runtime** — `Output.Metric.Butteraugli` `direction`/`target_range` contract; `score/2`
  over a known reference/candidate pair (polarity: identical images → near 0).
- **Resolve strategy selection** — `(butteraugli, :jpeg_xl)` resolves to `NativeJxlButteraugli`;
  `(butteraugli, :webp/:avif/:jpeg)` resolves to the external `Butteraugli`; `(ssim2, :jpeg_xl)`
  stays external (no native ssim2 clause).
- **External-measure polarity** — using a fake/stub `:lower_better` runtime (isolating the loop from
  the NIF), assert the *directional* arms, not just "it converges": (i) an undershoot-distance pins
  to the correct bracket end, (ii) an empty-band straddle ships the correct just-past-band q, (iii)
  the never-in-band fallback pins to the right end with a sensible `limiting_factor`. A bare
  convergence test passes while the overshoot/`resolve_target` polarity is subtly wrong.
- **Native JXL strategy** — no `max_bytes` and full-range bracket → single encode at
  `distance = target`, `outcome: :native`, `iterations: 0`, and **no external NIF call** (assert via
  a telemetry/spy that the butteraugli comparison never runs); with `max_bytes` set and the encode
  over budget → distance is raised until bytes fit; an infeasible budget ships best-effort at max
  distance with `limiting_factor: :max_bytes`.
- **Native bracket guardrail** — an explicit `max_quality` is never exceeded: a `target` higher in
  quality than `dist(max_quality)` is clamped down to it; an explicit `min_quality` clamps the other
  way; the clamp runs before the `max_bytes` self-cap.
- **Q↔distance drift guard** — `encode(Q=q)` is byte-identical (within rounding) to
  `encode(distance=dist(q))` for sample `q`, pinning our replicated libjxl `dist/1` formula to the
  installed libjxl; this fails loudly if libjxl ever changes its Q→distance conversion.
- **Full-frame-only** — a butteraugli resolved search above 6 MP yields `scorer: :full` and never
  consults `quality_search_offsets`; the rewritten crop guards match the Ssimulacra2 struct type.
- **Parser range rejection** — out-of-range butteraugli target rejected, in-range accepted; the
  rejection covers a **host-config-default** out-of-range target (via `resolve_quality_search_target`),
  not only a URL-supplied one.
- **Cache key** — semantically distinct autoquality requests (ssim2 vs butteraugli at the same
  numeric target) produce distinct keys; equivalent requests reuse a key.
- **Wire-level** — a representative `aq:butteraugli` request through `ImagePipe.call/2` decoding the
  response and asserting it is smaller-but-valid vs. a max-quality baseline, and that a JXL +
  butteraugli request takes the single-encode path (no search iterations in `meta`).
- **Encoder** — JXL `distance` suffix produces a valid JXL; `Q=` path unchanged.
- **Arch test** — Plan-exports mirror updated for the new sub-structs; the imgproxy boundary's
  exact-match `deps:` continues to exclude `ImagePipe.Output` (this is what enforces
  parser-never-reaches-metric-runtime).

## Documentation

- `docs/imgproxy_support_matrix.md` — butteraugli isn't an imgproxy feature, so there's no parity
  to match; the matrix still needs syncing per the conformance-doc rule across three axes:
  **surface** (a new `aq:butteraugli:…` form on the autoquality row; the config-default note gains
  `@default_butteraugli_target 1.0`), **stage/order** (the `NativeJxlButteraugli` strategy is a new
  Save/encode pipeline behavior — single direct-distance encode, `iterations: 0`, self-capping for
  `max_bytes` — and belongs in the pipeline section, not just the surface table), and **behavioral**
  (a one-line note on butteraugli's lower-is-better polarity and full-frame-only scoring). The
  existing matrix line stating "a butteraugli distance mapping is deferred" becomes false and must
  be updated, since this work implements it.
- Fiddle UI (`fiddle/assets/`) — add a butteraugli option to the autoquality control + URL state,
  per the transform/demo-sync rule.
- Telemetry — if the native strategy (`outcome: :native`) or the metric choice introduces new
  metadata (e.g. a `:metric` key on an existing autoquality span), update the default Logger
  (`@group_span_events`/one-shot lists + rendering), the OTel Capture allowlist (`@safe_keys`,
  `@span_stages`/`@oneshot_stages`), and `docs/telemetry.md` in the same change. The metric name
  is product-neutral and safe to emit.

## Review lenses (plan-review cycle)

This design spec was reviewed by parallel subagents (boundary/namespace, search/encode correctness,
and a conformance-doc/compat pass); accepted findings are folded in above (the spelled-out polarity
inversion, the struct-split fan-out, the `:target_distance` field spec). The `max_bytes`-on-native
correctness bug the review found is now resolved structurally: the `NativeJxlButteraugli` strategy
self-caps on the distance axis rather than skipping a separate cap phase. butteraugli is **not** an
imgproxy feature, so there is no imgproxy *parity* to verify — the compat dimension reduces to
keeping the conformance doc synced (above).

The implementation **plan** still gets its own parallel review before code. Disjoint lenses:
(1) **boundary/namespace** — parser never reaches Output metric runtime, metric semantics stay in
Output, Plan stays semantics-free, struct-split fan-out is complete (cache key, exports, arch-test
mirror); (2) **search/encode correctness** — the external-measure polarity arms, the
`NativeJxlButteraugli` self-cap (`max_bytes` honored, never improves past target), and
full-frame-only enforcement with no offset leakage; (3) **conformance-doc sync** — the three matrix
axes above are updated. No imgproxy-parity reviewer is required (nothing to match upstream).
