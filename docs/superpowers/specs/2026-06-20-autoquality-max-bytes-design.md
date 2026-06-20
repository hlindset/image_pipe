# Autoquality (#344) + max_bytes (#83): encode-search loop

**Status:** design / spec
**Date:** 2026-06-20
**Issues:** [#344](https://github.com/hlindset/image_pipe/issues/344) (autoquality), [#83](https://github.com/hlindset/image_pipe/issues/83) (max_bytes)

## 1. Summary

Add an **encode-quality search** at the output/encoder boundary. A single loop
searches the encode `quality` over an integer bracket `[min_quality,
max_quality]`, governed by up to two constraints derived from the request:

- an **objective** from imgproxy `autoquality`/`aq` — one of `:none`, `:size`
  (output bytes ≤ target), `:ssim2` (a SSIMULACRA2 score ≥ target, within
  `allowed_error`);
- a **byte ceiling** from imgproxy `max_bytes`/`mb` (#83) — final bytes ≤ target.

Both `autoquality` and `max_bytes` are the *same machinery*: a best-effort
binary search that re-encodes the full-resolution result at trial qualities
until a stop condition is met. When neither is requested (the common case) the
loop is bypassed entirely and the existing single-shot lazy streaming encode
runs unchanged — **zero added cost for normal requests**.

The perceptual metric is **SSIMULACRA2** via the `ssimulacra2` package
(`github.com/hlindset/ssimulacra2`, module `Ssimulacra2`), not real DSSIM. This
is a deliberate divergence from imgproxy, documented in the support matrix.

`ml` and any other unknown method are rejected before side effects.

### Scope deltas vs the issues

- **Per-format min/max clamps are IN scope** (config-only), not deferred. Both
  #344 and earlier notes said "defer"; this design pulls them in because a
  single global `[min,max]` bracket is semantically wrong across codecs
  (q63 AVIF ≈ q80 JPEG). The addition is well-bounded and lives entirely on the
  config surface.
- `autoquality_max_resolution` cost guard is IN scope (config-only).
- The `dssim` keyword is accepted **bare only**; its inline-numeric form is
  rejected (see §4).

## 2. Background (already decided — do not re-litigate)

From [#344](https://github.com/hlindset/image_pipe/issues/344) and its
[research comment](https://github.com/hlindset/image_pipe/issues/344#issuecomment-4752643993):

- One encode-search loop with two stop conditions; design `autoquality` and
  `max_bytes` together. Lives at the output/encoder boundary
  (`lib/image_pipe/output/encoder.ex`), **not** a `Plan.Operation`.
- Declarative knobs go on `Plan.Output`; the parser emits to `Plan`. Namespace /
  Boundary rules hold: request/source/response must not name concrete transform
  modules; the output boundary owns this.
- Methods in scope: `none`, `size`, `ssim2` (imgproxy `dssim`). `ml` is
  rejected/deferred (no license-clean model).
- The search runs on the **full-resolution result**. A downsized proxy may only
  *seed* a future bracket; neither size nor the perceptual metric is
  scale-invariant. (Proxy seeding is out of scope for this pass.)
- imgproxy `max_bytes` (`processing/save_fit_bytes.go`) is **best-effort, never
  errors**: it starts at the resolved quality and steps down, returning the
  smallest result even if it can't fit (floor quality 10 / min 1). imgproxy's
  `autoquality` is Pro/closed — its loop is genuinely ours to design.

### Ground-truth references

- imgproxy source: `/Users/hlindset/src/imgproxy`
  (`processing/save_fit_bytes.go`, `processing/processing.go:498-528`).
- imgproxy docs: `/Users/hlindset/src/imgproxy-docs`
  (`docs/features/autoquality.mdx`, `docs/usage/processing.mdx:875-891`,
  `docs/configuration/options.mdx:255-263`).
- The conformance doc to update: `docs/imgproxy_support_matrix.md`.

## 3. Native model — `Plan.Output`

Two new resolved fields (never `nil`):

```elixir
# lib/image_pipe/plan/output.ex
quality_search: :none | %ImagePipe.Plan.Output.QualitySearch{
  objective:     :size | :ssim2,
  target:        number(),      # :size -> bytes (pos_integer); :ssim2 -> score 0.0..100.0
  min_quality:   1..100,
  max_quality:   1..100,
  allowed_error: number(),      # :ssim2 only (score points); 0 for :size
  format_min:    %{optional(format()) => 1..100},   # per-format clamp; {} = none
  format_max:    %{optional(format()) => 1..100},
  max_resolution: non_neg_integer()   # megapixels; 0 = off
},
max_bytes: nil | pos_integer()
```

New module `ImagePipe.Plan.Output.QualitySearch` (under the `Plan` boundary).
`@enforce_keys` covers `objective`, `target`, `min_quality`, `max_quality`;
`allowed_error` defaults `0`, the per-format maps default `%{}`,
`max_resolution` defaults `0`.

Rationale for **two** fields rather than one: `quality_search` is the perceptual/
size *objective*; `max_bytes` is an orthogonal *byte ceiling*. imgproxy composes
them as "objective picks quality, then `max_bytes` caps it" — see §6. Keeping
them separate models that composition directly and lets `max_bytes` work with no
`autoquality` set (the #83 standalone case).

Product-neutral names throughout (`:ssim2`, not `:dssim`); nothing here names
imgproxy.

## 4. Parser — imgproxy adapter

### 4.1 Grammar

`autoquality`/`aq` is an irregular-arity option → bespoke `parse_special_option/3`
clause (like `resize`), in
`lib/image_pipe/parser/imgproxy/option_grammar.ex`. `max_bytes`/`mb` is a simple
single-int option → `@special_specs` with a new non-neg-int type, scoped
`:output`.

```
autoquality:none                                   -> quality_search disabled
autoquality:size[:target[:min[:max]]]              -> objective :size  (target = bytes)
autoquality:ssim2[:target[:min[:max[:allowed_error]]]]
                                                   -> objective :ssim2 (target = score)
autoquality:dssim                                  -> bare alias for ssim2-from-config
aq:...                                             -> alias of autoquality
max_bytes:%bytes  /  mb:%bytes                     -> max_bytes ceiling (0 disables)
```

- **All trailing args optional** (imgproxy `processing.mdx:882`: "All arguments
  are optional and can be omitted"). Each omitted field falls back to its config
  default (§4.3).
- **`max_bytes:0` disables the ceiling** (maps to `nil`), matching imgproxy:
  `max_bytes` is parsed with `parsePositiveInt` (rejects only `< 0`) and gated on
  `maxBytes > 0` in `processing.go`. Only a negative or non-numeric value is an
  error.
- **`:size` accepts no 5th arg.** imgproxy's grammar is uniform
  (`method:target:min:max:allowed_error`) and ignores a trailing `allowed_error`
  for `size`; ImagePipe rejects it instead (`allowed_error` is meaningless for a
  byte target). A minor, documented grammar divergence (§11).
- **`dssim` is bare-only.** `autoquality:dssim` parses (method = perceptual, all
  params from config). **Any inline argument is rejected** before side effects
  (`autoquality:dssim:0.02:...` → invalid-option error). This is the deliberate
  divergence: imgproxy's `dssim` target is a DSSIM value (low = good, e.g.
  `0.02`); ImagePipe's metric is a SSIMULACRA2 score (high = good, 0–100) — a
  different metric, scale, *and* direction. Rather than silently misinterpret a
  pasted DSSIM number (which would trivially satisfy the target and pick
  `min_quality`), we reject the numeric form and the error points to `ssim2`.
  Bare `dssim` ≡ bare `ssim2` (both use the config-default perceptual settings).
- `ml` and any other unknown method → reject before side effects with the
  canonical invalid-option error tag.

### 4.2 Field validation

- `min_quality`, `max_quality` ∈ `1..100`; reject `min > max` at parse time.
- `:size` target: `pos_integer` bytes.
- `:ssim2` target: float in `0.0..100.0`; `allowed_error`: non-negative float.
- Validation failures return before any source fetch or cache access (request
  safety guideline).

### 4.3 Config defaults (host opts, resolved in `apply_request_defaults/2`)

The imgproxy parser resolves these the same way it already resolves `quality` /
`strip_metadata` defaults. The **native** `Plan.Output` defaults stay
product-neutral; the imgproxy adapter supplies imgproxy-flavored defaults.

Two distinct axes share this table — do not conflate them:

- **`autoquality_target`** is the *metric goal* the search aims for (a
  SSIMULACRA2 **score** for `:ssim2`, a **byte count** for `:size`).
- **`autoquality_(format_)min/max_quality`** bound the *encoder quality knob*
  (libvips `q`, `1..100`) that the search **varies**. The per-format defaults
  (`avif: 60/65`) exist because the encoder quality scale differs per codec
  (imgproxy: "q63 AVIF ≈ q80 JPEG") — they are **not** metric targets.

So an AVIF request with `ssim2:90` searches for the lowest encoder `q` in
`[60, 65]` whose measured SSIMULACRA2 score is ≥ `90`.

| Option | Type | Native default | imgproxy-adapter default |
|---|---|---|---|
| `autoquality_method` | `:none \| :size \| :ssim2` | `:none` | `:none` |
| `autoquality_target` | number | — | `90.0` (ssim2); `:size` requires explicit target |
| `autoquality_min_quality` | `1..100` | `70` | `70` |
| `autoquality_max_quality` | `1..100` | `80` | `80` |
| `autoquality_allowed_error` | number (score pts) | `1.0` | `1.0` |
| `autoquality_format_min_quality` | `%{format => 1..100}` | `%{}` | `%{avif: 60}` |
| `autoquality_format_max_quality` | `%{format => 1..100}` | `%{}` | `%{avif: 65}` |
| `autoquality_max_resolution` | non-neg megapixels | `0` (off) | `0` |
| `autoquality_max_iterations` | pos_integer | `6` | `6` |

- The imgproxy-adapter `avif` per-format defaults reproduce imgproxy's out-of-box
  behavior (`IMGPROXY_AUTOQUALITY_FORMAT_MIN/MAX` default `avif=60/65`).
- `:size` has no universal byte default — `autoquality:size` with no target
  (and none configured) is an invalid option, surfaced at request time.
- imgproxy's config `TARGET=0.02` (a DSSIM value) is **not** portable; a host
  migrating from imgproxy config must set `autoquality_target` in SSIMULACRA2
  terms. Documented.
- `max_bytes` is per-request only (imgproxy has no `max_bytes` config default).

Options validated with `NimbleOptions` / adapter `validate_options`; unknown or
malformed values rejected before side effects.

## 5. Resolution — `Output.Policy` → `Output.Resolved`

The per-format bracket clamp resolves **after format negotiation**, where the
output format is finally known — inside the private `resolved/2` builder reached
from the public `ImagePipe.Output.Policy.resolve/2` (the same place
`effective_quality/2` already keys off the negotiated format). (Tests drive it
through the public `Policy.resolve/2`.)

```
global_min  = url_min ?? config.autoquality_min_quality
global_max  = url_max ?? config.autoquality_max_quality
effective_min(fmt) = quality_search.format_min[fmt] ?? global_min
effective_max(fmt) = quality_search.format_max[fmt] ?? global_max
```

Per-format config wins for listed formats, falling back to the global bracket
(which the URL can override) — matching the docs' "when value for the resulting
format is not set, the global value is used." URL `min/max` stay global-only
(imgproxy has no per-format URL form).

`Output.Resolved` gains the resolved, format-specific search descriptor. The
per-format maps are consumed during resolution (collapsed into the clamped
bracket), so the resolved descriptor is a narrower struct —
`ImagePipe.Output.ResolvedQualitySearch` (its own file, per the one-module-per-file
guideline), with the bracket already format-clamped and `max_resolution` carried
forward for the encoder's skip check:

```elixir
# lib/image_pipe/output/resolved.ex
quality_search: :none | %ImagePipe.Output.ResolvedQualitySearch{
  objective, target, min_quality, max_quality, allowed_error, max_resolution
},
max_bytes: nil | pos_integer()
```

`max_resolution` is **forwarded** through resolution (it rides along on
`ResolvedQualitySearch`, default 0) but is **not** evaluated in `Policy` — the
finalized image's pixel count is only in hand inside the encoder. The skip is
decided there: `EncodeSearch.skip?/2` returns true when `max_resolution > 0` and
the finalized megapixels exceed it, in which case the search is bypassed and the
single-shot encode runs at the resolved base quality (`outcome: :skipped`). This
bounds worst-case cost on huge results. `max_resolution` is a generation guard,
so it stays out of the cache key and ETag (see §8).

## 6. Encoder — the search loop

Lives in `ImagePipe.Output.Encoder` (output boundary). Driven from the producer's
existing honest `[:encode]` span (`request/source_session/producer.ex`).

### 6.1 Why the encoder needs restructuring

Today `stream_output/3` returns a **lazy** `Enumerable` and the producer pulls
the first chunk. The search needs *full* encoded buffers (to measure bytes and to
decode candidates for the metric), which is incompatible with lazy first-chunk
streaming. So:

- Add a **buffer-encode** path producing `{bytes :: binary, byte_size :: integer}`
  per candidate (via `Image.write_to_buffer` / Vix `write_to_buffer`).
- The search runs on the **finalized pre-encode image** — the output of the
  existing `finalize/2` (color finalize + format flatten + metadata strip). That
  same finalized image is the **metric reference** (see §6.3), so the score
  measures *encode loss only*, never color-management differences.
- The winning candidate's bytes are already in memory → returned as a
  one-element `Enumerable` so the producer's streaming contract is unchanged
  (no redundant re-encode of the winner).
- When `quality_search == :none and max_bytes == nil`, `stream_output/3` keeps
  its current lazy path verbatim.

### 6.2 The search algorithm (our own — imgproxy's is closed)

Integer **binary search on quality** within `[min_quality, max_quality]`, shared
by all three predicates.

**Monotonicity contract.** The binary search assumes encoded byte size is
non-decreasing in quality, and SSIMULACRA2 score is non-decreasing in quality.
Real encoders can violate this *locally* (adjacent qualities flat, or off by a
hair; the research note shows the score curve can even wiggle). The consequence
is bounded and acceptable for a best-effort search: the returned quality may be a
step or two from the theoretical optimum, but it is always re-measured and always
within `[min, max]` — never wrong in kind. This is a documented limitation, not a
bug to "fix" by ripping out the search; widen tolerances if a real-encoder flake
appears. The property tests (§12) therefore generate non-monotone curves too and
assert only the kind-invariants (within bracket; `:hit` results actually satisfy
their predicate), never optimality.

Predicate per request:

- `:size` — accept when `byte_size ≤ target` (want the **highest** quality that
  still fits).
- `:ssim2` — accept when `score ≥ target − allowed_error` (want the **lowest**
  quality whose score still clears the tolerance band, to minimize bytes at
  acceptable quality). `allowed_error` widens the acceptable band *below* the
  target (we tolerate undershooting by up to that many score points) and bounds
  search convergence: stop once the bracket can no longer change acceptability.
  This one-sided band is the metric-flipped analogue of imgproxy's `allowed_error`
  (**inferred from the docs, not source** — `autoquality` is Pro/closed): imgproxy
  tolerates DSSIM *above* its target (low = good), and the `ml` doc's
  `allowed_error: 1` ⇒ "always use the predicted quality" confirms a tolerance
  that loosens toward more error / lower quality. Flipped to a SSIMULACRA2 score
  (high = good), "tolerate DSSIM above target" becomes "tolerate score below
  target." Because the search minimizes quality, only this lower bound is
  operative, so a symmetric `|score − target| ≤ allowed_error` band would pick
  the same quality.
- `max_bytes` — accept when `byte_size ≤ target` (byte ceiling).

Common shape:

1. Evaluate the predicate at trial qualities, halving the bracket each step.
2. **Hard iteration cap** (default 6, host-configurable via
   `autoquality_max_iterations`) — each `:ssim2` step costs an extra decode +
   metric, so this directly bounds worst-case latency.
3. **Best-effort, never error** (matches imgproxy): if no quality in range
   satisfies the predicate, return the best boundary — the floor when even the
   floor exceeds a byte budget; `max_quality` when even the ceiling can't reach
   an `:ssim2` target.

Algorithm note (not a divergence): imgproxy `max_bytes` uses a *multiplicative
step-down* from the resolved quality (`save_fit_bytes.go`) that stops at the
first quality which fits; ImagePipe uses the shared binary search, which selects
the **highest** quality under the budget. Both satisfy the identical observable
contract — *best-effort, result bytes ≤ target* — and byte-identical parity is
unachievable regardless (the selected quality depends on each build's libvips
encoder output, which is why the conformance suite uses tolerances, not
exact-byte assertions). So there is no testable divergence against real imgproxy;
ours simply meets the same contract at the best quality for the budget. Recorded
as a one-line behavioral *note* in the support matrix, not a divergence.

### 6.3 Composition — `autoquality` then `max_bytes`

When both are set, imgproxy-faithful composition (chosen design): the objective
picks a base quality, then the byte ceiling lowers it further only if the result
exceeds the budget (byte ceiling wins). Concretely:

1. Run the objective search (`:size`/`:ssim2`) → `q_objective` and its buffer.
2. If `max_bytes` set and `q_objective`'s bytes exceed it, continue the search
   downward against the `max_bytes` predicate (reusing the lower half of the
   bracket, floored at `min_quality`). Otherwise keep `q_objective`.

`max_bytes` alone (no objective) is the #83 standalone path: binary-search the
bracket `[10, resolved_base_quality]` for the highest quality that fits the
budget, best-effort to the floor (`quality 10`). The floor of **10** matches
imgproxy's `save_fit_bytes.go` give-up threshold (`quality <= 10` → return). When
`autoquality` *is* active, its own `min_quality` is the floor instead (the
composition in §6.3), not 10.

### 6.4 Metric integration

- Depend on `ssimulacra2` (module `Ssimulacra2`) via git SHA (§9), isolated
  behind the `ImagePipe.Output.Ssim2Metric` adapter (the only module naming
  `Ssimulacra2.*`).
- Precompute the reference **once** from the finalized pre-encode image via
  `Ssimulacra2.Vix.reference/1` → `{:ok, Reference.t()}` (the bridge handles the
  Vix→packed coercion: sRGB, alpha flattened, bit depth preserved).
- Each candidate: decode the trial buffer back to a Vix image
  (`Image.from_binary/1`) and score it against the precomputed reference via
  `Ssimulacra2.Vix.compare/2` *(reference, image)* → `{:ok, float}`. In-memory
  only, no temp files. That `compare(reference, image)` arity is the upstream
  addition merged as PR #6 (`c95683de`, pinned in §9).
- **No metric conformance check here** — we trust Imazen/`fast-ssim2`; the
  binding-sanity test lives in the `ssimulacra2` repo.
- Score is SSIMULACRA2-native: 0–100, 100 = identical, ~90 ≈ visually lossless.

## 7. Telemetry

(Per user request — proper spans/events for the whole feature.)

- **Span** `[:image_pipe, :encode, :search, :start | :stop | :exception]`
  wrapping the loop, **inside** the existing `[:encode]` span. Emitted via the
  shared `ImagePipe.Telemetry` helpers (`:telemetry.span`-style naming).
  - start metadata: `objective`, `max_bytes` (bool present), `min_quality`,
    `max_quality`, `target`, `output_format`.
  - stop metadata: `result`, `iterations`, `chosen_quality`, `chosen_bytes`, and
    `final_score` (ssim2), plus `outcome` (`:hit` | `:best_effort` | `:skipped`).
- **Per-probe event** `[:image_pipe, :encode, :search, :probe]` — `quality`,
  `bytes`, `score`, `index`. Cheap and structural (like per-op transform spans);
  carries no sensitive data (no URLs/secrets — product-neutral numbers only).
- The `max_resolution` skip emits a `:stop` with `outcome: :skipped`.

### Default Logger (`ImagePipe.Telemetry.Logger`) — keep in sync

- **Subscription:** add the search span to `@group_span_events` and the probe to
  the appropriate one-shot list.
- **Rendering:** add a `message/3` clause that surfaces `outcome` +
  `chosen_quality`/`chosen_bytes`/`final_score`; still surface `:result`. Place
  before the generic fallback.
- **Levels:** escalate `outcome: :best_effort` above the base level via
  `level_for/3` (the search could not meet the target — a degradation worth a
  warn).
- **Coverage:** add `logger_test.exs` assertions; align `docs/telemetry.md`.

## 8. Cache

- `quality_search` and `max_bytes` join the cache **key** — they change the
  stored bytes (`ImagePipe.Cache.Key.output_plan_data/2`, mirrored in
  `Plan.KeyData`). Distinct targets/brackets must not collide.
  - The key contributes the **native, pre-negotiation** descriptor — objective,
    target, global bracket, `allowed_error`, and the per-format maps (as sorted
    lists) — consistent with how `quality`/`format_qualities` already key their
    *unresolved* plan values (the negotiated format is captured elsewhere in the
    key via `Accept`/modern candidates). Keying the native descriptor avoids
    depending on the resolved bracket and is deterministic.
  - **`max_resolution` is excluded** from the key (and the ETag): it is a runtime
    generation guard, not stored identity — keep safety limits out of both.
- The **ETag** rules are unchanged in spirit: the search is deterministic in its
  output given identical inputs (same finalized image + same descriptor → same
  bytes), so the new fields participate as part of the canonical plan seed (they
  flow into the ETag automatically via `plan_material/2`, which drops only the
  cachebuster), not as a body content-hash. Two distinct `max_bytes`/`target`s
  therefore yield distinct ETags — correct, since they change the stored bytes.
  No new fast-path regression.
- Greenfield: reshape canonical key data in place; **do not** bump a key data
  version.
- The search is a cache-**miss** generation concern only; it must not gate
  serving an existing successful cached response (safety-limits-vs-key guideline).

## 9. Dependency & toolchain

```elixir
# mix.exs
{:ssimulacra2, github: "hlindset/ssimulacra2", ref: "c95683deefcafd7313e149d0d5e30a3328c14efd"}
```

- **Upstream prerequisite — DONE:** `Ssimulacra2.Vix.compare(reference, image)`
  (the precompute-once bridge fn the search loop needs) is merged as PR #6
  (`c95683de`); the pin above is that SHA.
- Compiles the Rust NIF locally during dev (no precompiled artifacts until a
  release is tagged). **Pin Rust in `mise.toml`** so contributors/CI get the
  toolchain.
- Switch to `~> 0.1` when tagged — no feature-code change.
- `mise run setup` / CI must build the NIF; document the Rust requirement in the
  fiddle/dev setup notes if needed.

## 10. Fiddle UI

`fiddle/assets/` Svelte app — add controls + URL state (Transform/demo
guideline):

- `autoquality` method select (`none` / `size` / `ssim2`), with conditional
  fields: target, min/max quality, allowed_error (ssim2 only).
- `max_bytes` input.
- Wire to URL option state so the demo exercises the search end-to-end.
- (Per-format clamps and `max_resolution` are config-level; not exposed as
  per-request UI controls.)

## 11. Docs — `docs/imgproxy_support_matrix.md`

Update per the conformance-doc discipline; note which axis changes:

- **Surface:** new option rows for `autoquality`/`aq` and `max_bytes`/`mb`,
  plus the config options (§4.3); `ml` documented as unsupported (deliberate
  divergence).
- **Stage/order:** pipeline-section note for the re-encode search loop at the
  output/encode stage (no option-table knob for the loop mechanics themselves).
- **Behavioral/pixel:** the SSIMULACRA2-vs-DSSIM divergence (metric, scale,
  direction; bare-`dssim`-only rule; migration table — e.g. imgproxy
  `dssim:0.02` ≈ `ssim2:85`). Plus a one-line behavioral *note* (not a
  divergence): `max_bytes` selects the highest quality under budget via binary
  search; imgproxy uses a faster heuristic descent. Same observable contract
  (best-effort, bytes ≤ target); byte-identical parity is build-dependent and
  not asserted.

## 12. Tests (TDD; wire-level acceptance, not a pixel differential)

Per the test guidelines — assert user-visible contracts via real
`ImagePipe.call/2` requests; keep grammar edges in parser/property tests.

- **Parser** (`option_grammar` / options): per-method grammar; bare `dssim`
  accepted, `dssim` with inline args rejected; `ml`/unknown method rejected;
  `min > max` rejected; `max_bytes`/`mb` parse; trailing-arg optionality →
  config fallback; config-default resolution in `apply_request_defaults`.
- **Planner:** `Plan.Output.quality_search` / `max_bytes` populated correctly;
  product-neutral mapping (`dssim`→`:ssim2`).
- **Resolution:** per-format bracket clamp in `Output.Policy.resolve/2`
  (format-specific min/max with global fallback); `max_resolution` skip.
- **Wire acceptance** (`imgproxy_wire_conformance_test` style):
  - `size` / `max_bytes` — decode response, assert byte size ≤ target (within
    tolerance) for a format where quality reduces size; status/headers correct.
  - `ssim2` — decode response, assert measured score ≥ target within
    `allowed_error`.
  - **Best-effort paths:** byte target smaller than any in-range encode → returns
    `min_quality` result (no error); `ssim2` target unreachable → returns
    `max_quality` result.
  - Validation failures return **before** source fetch / cache access.
  - Telemetry assertions use a unique `telemetry_prefix` (global-handler
    hygiene).
- **Cache key:** distinct `quality_search` targets/brackets and distinct
  `max_bytes` values do **not** collide; semantically-equal requests reuse.
- **Property tests** (StreamData) where invariants span input shapes: bracket
  resolution monotonicity (effective_min ≤ effective_max), search returns a
  quality within `[min,max]`, key canonicalization.

## 13. Boundary / architecture compliance

- `Plan.Output.QualitySearch` under the `plan` boundary; `Output.*` owns
  resolution and the encoder loop; `request`/`source`/`response` never name it.
- The encoder dispatches metric work through the `Ssimulacra2` package API
  (external dep) — no new internal cross-boundary reference.
- Add `Boundary` export only if a stable entry point is needed; do not export
  helpers to satisfy compile errors.
- Architecture test additions only if a new boundary edge is introduced
  (the `ssimulacra2` dep is external, not a namespace).

## 14. Open / deferred (explicitly out of scope)

- Downsized-proxy bracket seeding (future speed optimization; never search
  entirely on the proxy).
- `ml` method (no license-clean model).
- Per-format clamps as *processing-option* (URL) form — imgproxy has none;
  config-only here too.
- Exposing per-format clamps / `max_resolution` in the fiddle UI.
- A memory high-water benchmark for the buffer-encode path (the search
  intentionally materializes full buffers; correctness is covered, perf is not).

## 15. Definition of done

- [ ] `Plan.Output.QualitySearch` + `quality_search`/`max_bytes` fields.
- [ ] imgproxy parser rows + config-default resolution + per-method grammar
      (bare `dssim`; `ml`/unknown rejected; `min>max` rejected).
- [ ] Per-format bracket resolution in `Output.Policy`; `max_resolution` skip.
- [ ] Shared best-effort binary-search loop in `Output.Encoder` (size / ssim2 /
      max_bytes; AQ-then-cap composition; iteration cap).
- [ ] SSIMULACRA2 integration (`Ssimulacra2.Reference` + `Ssimulacra2.Vix`),
      reference = finalized pre-encode image.
- [ ] `ssimulacra2` git-SHA dep + Rust pin in `mise.toml`.
- [ ] Telemetry span + per-probe event; default Logger + `docs/telemetry.md`
      updated.
- [ ] Cache key includes new fields; non-collision tests.
- [ ] Fiddle UI controls + URL state.
- [ ] `docs/imgproxy_support_matrix.md` updated (surface + stage + behavioral
      axes; `ml` unsupported; divergences documented).
- [ ] Wire-level acceptance + parser + resolution + cache-key + property tests.
- [ ] `mise run precommit` (and `precommit:fiddle` for the fiddle changes) green.
