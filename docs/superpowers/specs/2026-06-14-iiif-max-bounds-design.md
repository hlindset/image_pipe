# IIIF max bounds — maxWidth / maxHeight / maxArea + `^max` (IIIF Phase 5, max-bounds slice)

**Issue:** [#257](https://github.com/hlindset/image_pipe/issues/257) — IIIF `extraFeatures`, folding in [#296](https://github.com/hlindset/image_pipe/issues/296). This spec covers **only** the max-bounds slice: server-side `maxWidth`/`maxHeight`/`maxArea` size limits and the `^max` upscaling interaction. The other remaining `#257` slice — extra output formats (`jp2`/`gif`/`tif`) — is **out of scope** and gets its own spec.

Sibling specs: arbitrary rotation + mirroring (`2026-06-14-iiif-arbitrary-rotation-mirroring-design.md`, merged as [#305](https://github.com/hlindset/image_pipe/pull/305)) — mirror its conventions (grammar/plan_builder/info wiring, matrix-axis discipline, validator-by-name pattern, review cycle).

## Background / current state

`lib/image_pipe/parser/iiif.ex` deliberately **omits** `maxWidth`/`maxHeight`/`maxArea` from the `iiif:` schema. A comment at the top of `@schema` explains why: *"advertising them in info.json without enforcing the limit in the size pipeline would be a conformance lie (and `maxHeight` without `maxWidth` is spec-invalid)."* This slice closes that gap — wire enforcement first, then advertise.

The size pipeline today:

- `Grammar.size/1` parses the size token into `{:max, up?}` / `{:w, w, up?}` / `{:h, h, up?}` / `{:wh, w, h, up?}` / `{:confined, w, h, up?}` / `{:pct, ratio, up?}`. A leading `^` sets `up?`. **No grammar change is needed** — the bounds are host *config*, not URL syntax.
- `PlanBuilder.size_operations/1` maps each form to a single `Plan.Operation.Resize`. `{:max, up?}` currently emits `Resize{mode: :fit, width: :auto, height: :auto, enlargement: deny|allow}` — i.e. natural size, clamped or upscaled, with **no ceiling**. So today `max` == `^max` == natural size, and `^max` is inert.
- `Transform.Operation.Resize.resolve_dimensions/2` resolves the final pixel dims against the actual decoded (extracted-region) source dims at transform time. The parser cannot know region dims at plan time, so any ceiling must be carried *declaratively on the op* and resolved here.

### Spec ground truth (IIIF Image API 3.0, §4.5 Size + §5.1 Technical properties)

Verbatim:

- `max`: *"The extracted region is returned at the maximum size available, but will not be upscaled. The resulting image will have the pixel dimensions of the extracted region, unless it is constrained to a smaller size by `maxWidth`, `maxHeight`, or `maxArea`."*
- `^max`: *"The extracted region is scaled to the maximum size permitted by `maxWidth`, `maxHeight`, or `maxArea`. If the resulting dimensions are greater than the pixel width and height of the extracted region, the extracted region is upscaled."*
- The only **400** SHOULD is the upscale-beyond-region case: *"Requests for sizes not prefixed with `^` that result in a scaled region with pixel dimensions greater than the pixel dimensions of the extracted region are errors that should result in a 400 (Bad Request) status code."* (Already handled by `enlargement: :reject`.)
- General server MUST (the reason enforcement is **uniform**, not `max`-only): *"For all requests the pixel dimensions of the scaled region must not be less than 1 pixel or greater than the server-imposed limits."* (The ≥ 1px floor is separately preserved by `positive_round/1`.)
- Direct form-level support for the clamp: the confined `!w,h` / `^!w,h` rows say the result *"must be as large as possible but not larger than … or server-imposed limits"* — the one size form whose own definition bakes in the max-clamp.
- `maxWidth`/`maxHeight`/`maxArea` are written as **client** constraints (*"clients must not expect requests with a width greater than this value to be supported"*) — there is **no** mandated 400 for an explicit size that exceeds a max.
- Cross-field rules: *"`maxWidth` must be specified if `maxHeight` is specified"*; *"If `maxWidth` is specified and `maxHeight` is not, then clients should infer that `maxHeight = maxWidth`"*; `maxArea` may be specified on its own.
- `sizeUpscaling` coupling (§5.7): *"A server that supports `sizeUpscaling` must specify `maxWidth` or `maxArea`."* Our parser advertises `sizeUpscaling` unconditionally (it supports `^`-prefixed **explicit** sizes — `^w,`/`^pct:n`/`^!w,h` — which upscale with no ceiling needed). Only `^max` is degenerate when no bound is configured (it has no ceiling to scale *to*, so it falls back to source size = the unbounded no-op). We deliberately **do not** force every IIIF host to configure a bound (a greenfield zero-config default must keep working), so unbounded `^max` → source is a **documented divergence** from this MUST, recorded in the matrix — not a hard config rejection.

**Design consequence.** Because the maxes *are* the advertised "server-imposed limits," the MUST means a scaled result must never exceed them **for any request** — not just `max`/`^max`. A `max`/`^max`-only enforcement would leave a real hole: with `maxWidth` configured **below** the source, an explicit `3000,` (no `^`, ≤ source, so no upscale-400) would return a 3000px image while we advertise `maxWidth: 2000`. So enforcement is a **uniform output ceiling** applied to every size form, satisfying the MUST. (Decision confirmed with the issue owner: uniform clamp, clamp-down on overflow — not a 400.)

## Design

### Core decision — a product-neutral output ceiling on `Resize`

Add three optional fields to the resize op: `max_width`, `max_height`, `max_area` (each `pos_integer | nil`; `nil` = unbounded). They express *"the scaled result must fit within this ceiling"* and resolve at transform time against the actual source (extracted-region) dims. This is product-neutral: an output-dimension/area ceiling is a generic resize constraint any dialect could use; it is **not** an IIIF concept leaking into the core model. The IIIF parser is the only producer today.

Two structs change in lockstep (the same Plan-op / Transform-op pairing every resize field already has):

- `ImagePipe.Plan.Operation.Resize` — declarative fields `max_width`/`max_height`/`max_area`.
- `ImagePipe.Transform.Operation.Resize` — the same fields, consumed by `resolve_dimensions/2`.

### The ceiling resolution — direction falls out of the existing op signature

In `Transform.Operation.Resize.resolve_dimensions/2`, **after** the existing `normalize/1` and the target/intermediate dims are computed, apply a bounding step. The predicate and `bound_scale` read the **normalized** operation (so `max`/`^max` are `width: :auto, height: :auto`) and the transform op's **`enlarge` boolean** (resize.ex, *not* the plan op's `enlargement` atom). The step is **per-candidate** — it runs separately on the `intermediate` dims and the `target` dims, computing `bound_scale` from *that candidate's own* `{w, h}` (the two can differ; for IIIF's `:fit`/`:force` they coincide in pixel terms, but the rule must be per-candidate to stay correct):

```
# all-nil fast path: if max_width, max_height, max_area are all nil → return the
# candidate unchanged (no scale constructed, no re-round) so behavior is byte-identical to today.
bound_scale(candidate {w, h}) = min over CONFIGURED bounds of:
  max_width  / w
  max_height / h
  sqrt(max_area / (w * h))
```

`nil` bounds contribute no term. **A `:auto` axis is passed through untouched** — never multiplied (`scale_dimensions/2` would raise on `:auto`), and it contributes no `max_width`/`max_height` term for that axis.

Then choose the direction from the op's own shape — **no new flag, no parser lookahead**:

- **Grow-to-ceiling** — apply `bound_scale` even when `> 1.0` — **iff** the op is the bare `max`/`^max` signature *with* enlargement: `enlarge and width == :auto and height == :auto and not factor_requested?(operation)`. That predicate is exactly `^max` (the `max` keyword maps to `Resize{mode: :fit, width: :auto, height: :auto}`; `pct` sets `zoom_*` so `factor_requested?` is true and is excluded; `^w,`/`^,h` leave one axis `{:px,_}` after normalize so the predicate is false → clamp-down). **For this case `target` is `{:auto, :auto}` and `intermediate` is `source`** (traced: `resolve_base_dimensions` → auto/auto → `target_dimensions` auto/auto, `intermediate_dimensions` → source). So the grow scale is derived from and applied to the **`intermediate` (source) dims**; the grown intermediate is what drives the pixel resize (`fit_resize_and_result_crop` reads `intermediate_*`). `target` stays `:auto` — no consumer needs a numeric `target` for `^max` (response/info dims come from the resized image, not `target`). This makes `^max` "scaled to the maximum size permitted by the bounds," including the **`maxArea`-only** case (scale source up until `w·h ≈ maxArea`).
- **Clamp-down** — apply `min(1.0, bound_scale)` — for **everything else**: plain `max` (never upscales), and every explicit form (`w,`/`,h`/`w,h`/`!w,h`/`pct`, including their `^` variants, which upscale to *their own* target and are then capped). This is the uniform clamp satisfying the spec MUST.

Apply the chosen scale via `scale_dimensions/2` + `positive_round/1` (preserving the ≥ 1px floor). For the `:force` (`w,h` stretch) mode the uniform scale preserves the requested stretch ratio while fitting both axis caps and the area cap.

**maxArea must never be exceeded (it's a MUST, not a SHOULD).** Per-axis `positive_round` of a `sqrt`-derived scale can push `w·h` marginally *above* `max_area`. When the **area term is the binding constraint**, round the result **down** (floor the area-binding axis / floor the scale) so the invariant `w·h ≤ max_area` holds exactly. A unit test asserts `w·h ≤ max_area` across shapes (including the rounding-edge cases).

**`effective_dpr` is intentionally not re-derived after the bound step**, and `result_box_*` (the cover/fill result-crop box) is **not** scaled by `bound_scale`. This is correct for the IIIF surface (`:fit`/`:force`): IIIF's bounded forms never produce a *biting* result-crop (`max`/`^max`/`pct` have `:auto` result box; explicit `w,`/`,h`/`!w,h` set no `min_width`/`min_height` so the fit crop is a no-op), so the crop box and dpr-scaled offsets are unaffected. **Scope guard:** bounds are therefore only honored for `:fit` and `:force`. The fields are product-neutral and `resize_from/2` copies them onto *every* mode, so a future `:cover`/`:fill` op with bounds set would resize the intermediate but crop to an *unscaled* `result_box` → wrong crop. No producer sets bounds on a cover resize today; this is left **out of scope and untested** (documented here so a future cover-bounds consumer knows to also scale `result_box_*`), rather than building speculative support.

**Traced cases (against the resolver):**

| Request | Bounds | Source | Result | Why |
|---|---|---|---|---|
| `max` | `maxW=maxH=10000` | 6000×4000 | 6000×4000 | `bound_scale > 1`, no enlarge → `min(1.0, …) = 1.0` → source |
| `^max` | `maxW=maxH=10000` | 6000×4000 | 10000×6667 | enlarge + auto/auto → apply `bound_scale > 1` → fill box |
| `^max` | `maxW=maxH=2000` | 6000×4000 | 2000×1333 | enlarge but `bound_scale < 1` → downscale to box (no upscale needed) |
| `max` | `maxW=2000` | 6000×4000 | 2000×1333 | clamp-down; `maxH = maxW = 2000` inferred |
| `4000,` (no `^`) | `maxW=2000` | 6000×4000 | 2000×1333 | explicit target 4000 (≤ source, no 400), then clamp-down to 2000 |
| `^max` | `maxArea=2_000_000` | 6000×4000 | ~1732×1155 | maxArea-only; `bound_scale = sqrt(2e6/24e6) < 1` → downscale to area |
| `^max` | `maxArea=50_000_000` | 6000×4000 | ~8660×5774 | maxArea-only, enlarge → upscale until area = 50e6 |

The existing `reject_enlargement` upscale-beyond-region check (its `upscale_required` is computed from `unclamped` dims vs **source**) is **unaffected** by the ceiling and runs before the bound step, exactly as today. A request that upscales beyond the source is still a 400 regardless of bounds.

### Effective height inference (`maxHeight = maxWidth`)

When `maxWidth` is configured and `maxHeight` is not, the effective height ceiling is `maxWidth` (the spec value clients infer). The IIIF parser computes `eff_max_height = max_height || max_width` when threading bounds onto the resize op. We **advertise only the configured values** in info.json (never the inferred `maxHeight`) but **enforce** the inference, so what we serve matches what a conformant client assumes. `maxArea` is independent.

### IIIF wiring

- **Schema (`iiif.ex`)** — add to `@schema`:
  - `max_width: [type: :pos_integer]` (no default → key absent → unbounded)
  - `max_height: [type: :pos_integer]`
  - `max_area: [type: :pos_integer]`

  NimbleOptions enforces `pos_integer` per field. The cross-field rule (`max_height` present without `max_width` → reject) goes in `validate_options!/1` **after** `NimbleOptions.validate!` — *not* a `:custom` per-key validator, which can't see a sibling key. This follows the established pattern: imgproxy's `validate_options!` already does post-`validate!` work (signature, source encryption). `max_area` alone and `max_width` alone are valid. **Remove** the "conformance lie" comment block (lines ~21–26) cleanly — no narration of the removal.
- **`PlanBuilder.image_plan/3`** — read `max_width`/`max_height`/`max_area` from `opts`; compute `bounds = %{max_width: mw, max_height: mh || mw, max_area: ma}` (nils preserved; `mh || mw` is the spec's `maxHeight = maxWidth` inference); thread `bounds` into every `size_operations` call.
- **`PlanBuilder.size_operations/1` → `/2`** — this is an **arity bump** (today it is `size_operations(tokens.size)`, arity 1): add a `bounds` parameter to every clause. Each clause passes `max_width: bounds.max_width, max_height: bounds.max_height, max_area: bounds.max_area` into its `Operation.resize(...)` opts. `{:max, up?}` keeps `:auto, :auto` (the grow-to-ceiling signature); explicit forms keep their existing width/height target (the clamp-down path). No other mapping change.
- **`PlanBuilder.info_plan/3`** — the `params` map is built inline (`plan_builder.ex:23-33`); **always** add `max_width`/`max_height`/`max_area` keys (raw configured value or `nil`). Always present (even as `nil`) so `Info.document`'s dot-access (`params.max_width`) can't `KeyError`. `InfoRenderer` is a pass-through and needs no change.
- **`Info.document/2`** — emit `"maxWidth"`/`"maxHeight"`/`"maxArea"` keys **only when the corresponding param is non-nil** (omit otherwise; read via the always-present param key so dot-access is safe). Place alongside `width`/`height`. Never emit an inferred `maxHeight`. `@extra_features` is **untouched** — the maxes are top-level technical properties, not registry features.

### Plan model + cache + validation

- **`Plan.Operation.resize/4` constructor (`operation.ex`)** — add `:max_width`/`:max_height`/`:max_area` to `@semantic_resize_keys` and to the `%Resize{}` build; validate each as `pos_integer | nil` (a small `optional_positive_integer/2` helper or reuse existing pos-int validation). These come from the in-repo parser, but the constructor is the plan boundary, so validate.
- **`valid_resize?/1` (`semantic?` gate)** — add `pos_integer | nil` checks for the three fields so the gate stays exhaustive over the struct.
- **`Plan.KeyData.data(%Resize{})`** — add `max_width`/`max_height`/`max_area` to the key data (they change stored bytes → part of storage identity per the Cache guidelines). ETag derives from the canonical plan, so it picks them up for free.
- **`PlanExecutor.resize_from/2`** — copy `max_width`/`max_height`/`max_area` from the `PlanResize` onto the transform `%Resize{}` (alongside `min_width`/`min_height`).
- **No telemetry/Logger change.** No event is added, renamed, or re-meta'd — an existing op struct merely gains fields, which the per-op `:params` dump surfaces automatically. (Stated to preempt the AGENTS telemetry-sync flag.)

### Materialization / decode planning

The bounds do **not** change `Resize`'s materialization classification (it remains a streaming-safe, non-materializing op — the bounding step is pure arithmetic on dims). `DecodePlanner` pattern-matches existing `Resize` fields; the new fields have defaults and don't affect its shrink computation. For a clamped-down explicit request the planner may shrink-load against the (larger) pre-clamp target and the residual resize finishes the clamp — correct, marginally less optimal load shrink; acceptable and noted, not optimized in this slice. For `^max` upscaling (auto/auto), the planner loads full and the resize upscales, as today.

## Demo (fiddle)

- **`application.ex` `build_iiif_opts/0`** — add demo bounds to the `iiif:` keyword: `max_width: 4000, max_height: 4000`. Rationale: the samples run 1000–8775px, so no single bound exceeds all of them. `4000` demonstrates **both** behaviors — big samples (e.g. `spinning` 6000×4000) clamp *down* under `max`/`^max`; small samples (`woman` 1200×800, `concert` 1000×1500) *upscale* under `^max` to fill 4000. `maxArea` is left unset to keep the demo focused on the box (it's still configurable). Trivially adjustable.
- **`IiifControls.svelte`** — re-enable the "Allow upscaling (^)" toggle for `max`: drop the `case "max"` block that forces `iiifState.upscale = false` (lines ~51–54) and the `{#if iiifState.size.kind !== "max"}` gate around the toggle (line ~207) so it renders for `max` too. `iiifSizeSegment` already emits `^max` correctly. The issue-referencing comments explaining the gate are removed with the gate (clean removal).
- **`iiif-path.ts`** — no functional change required (`^max` round-trips already); update only any stale comment that claims `^max` is inert.

## Docs

Update `docs/iiif_3_support_matrix.md`:

- **Fix the existing contradiction.** Line ~38 ("`max` / `^max` … Bounded by maxWidth/maxHeight/maxArea when configured") was written optimistically; line ~85 says "Not advertised." Reconcile: the row now accurately describes the implemented behavior, and the info.json row flips from ➖ to ✅.
- **Surface axis** — info.json `maxWidth`/`maxHeight`/`maxArea` row → ✅: advertised when configured, with the cross-field rule (`maxHeight` requires `maxWidth`; `maxArea` standalone; only configured values emitted).
- **Stage/order + behavioral/pixel axis** — note the uniform output ceiling: every size form is clamped down to fit `maxWidth`×`maxHeight` (effective `maxHeight = maxWidth` when only `maxWidth` set) and `maxArea`; `^max` (and `max`) additionally *grow to* the ceiling via the auto/auto + enlarge signature; the clamp satisfies the spec's "for all requests … server-imposed limits" MUST.
- **Validator** — record that the official image-validator has **no** maxWidth/maxHeight/maxArea test (confirmed against its test list), so there is nothing to wire by name; our wire tests are the coverage. (Contrast #305, which wired `rot_*` tests by name.) The validator *does* run `size_up.py` (`^max`), which asserts `^max` == **full source size** and does not consult the info.json maxes — so the validator endpoint (`validator/server.exs`) must remain **bounds-free** for the gate to stay green. The demo bounds are scoped to the fiddle endpoint only; **do not** add bounds to `validator/server.exs`.
- **Divergence (`sizeUpscaling` ↔ max coupling).** Add a "Diverges" note: the spec §5.7 MUST *"A server that supports `sizeUpscaling` must specify `maxWidth` or `maxArea`"* is not enforced as a hard config requirement. We advertise `sizeUpscaling` unconditionally (explicit `^` forms work unbounded); when no bound is configured, `^max` degrades to source size (the unbounded no-op). A greenfield zero-config default must keep working, so we accept this as a documented divergence rather than forcing every host to configure a bound.
- No imgproxy parity row — imgproxy has no analogous output-dimension ceiling; this is IIIF-driven (IIIF spec is ground truth).

## Testing

Per `AGENTS.md`:

- **Resize op unit/property** (`transform/operation` or the resize resolver test, plus a property test over source shapes × bounds):
  - `max` with ceiling > source → result == source (no upscale).
  - `^max` with ceiling > source → result fills the box (one axis == ceiling, aspect preserved).
  - `^max` / `max` with ceiling < source → downscale to box.
  - explicit `w,h` / `pct` exceeding a ceiling → clamped down, result ≤ ceiling on every axis and `w·h ≤ maxArea`.
  - `maxArea`-only `^max` → `w·h ≈ maxArea` (upscale or downscale as needed).
  - **`maxArea` invariant**: across shapes/scales (incl. rounding-edge cases) the result satisfies `w·h ≤ max_area` exactly (the area MUST — guards the floor-the-binding-axis rounding).
  - effective `maxHeight = maxWidth` when only `maxWidth` set (height ceiling honored).
  - all-`nil` bounds → byte-identical to no-bounds behavior (no-op regression guard; exercises the all-nil fast path).
  - (Cover/fill + bounds is **out of scope and untested** — IIIF uses only `:fit`/`:force`; see the scope guard in "ceiling resolution".)
  - **No materialization claim changes** — `Resize` stays non-materializing; no sequential-safety harness entry is added (the bounding step is pure dim arithmetic, already covered by the op's existing sequential classification).
- **IIIF wire conformance** (`test/parser/iiif_wire_test.exs`) — real `ImagePipe.call/2`, decode the body, assert dims:
  - `^max` with demo bounds on a small source → decoded dims **> source** (visible upscale).
  - `max` on a large source under a sub-source ceiling → decoded dims == ceiling-fit (clamp down).
  - explicit `w,` exceeding `maxWidth` → decoded width ≤ `maxWidth` (uniform clamp).
  - info.json advertises `maxWidth`/`maxHeight`/`maxArea` when configured; **omits** them when not (two endpoint configs, or assert key presence/absence).
  - Keep representative, not exhaustive — grammar/combinatorics stay in the op property test.
- **Schema validation** (`iiif.ex` option tests / wherever `validate_options!` is exercised) — `max_height` without `max_width` → `validate_options!` raises; `max_area` alone OK; `max_width` alone OK; `max_width` + `max_height` OK; non-pos-int rejected. (Boundary: host config the caller controls.)
- **Cache key** (`cache/key` or `key_data` test) — two requests differing only in configured bounds produce different keys; identical bounds collide. (Reuse the existing Resize key-data test pattern.)
- **Gates** — `mise run precommit` (Elixir gate) for the library changes; `mise run precommit:fiddle` because the fiddle Svelte app changes. The Docker `mise run validator` gate is unaffected (no new by-name tests; the existing Level-2 + rotation/mirror run is unchanged) — run it if Docker is available, but it is not a new acceptance requirement for this slice.

## Change sites (for the implementation plan)

- `lib/image_pipe/plan/operation/resize.ex` — `defstruct` + `@type` add `max_width`/`max_height`/`max_area` (`pos_integer | nil`, default `nil`).
- `lib/image_pipe/plan/operation.ex` — `@semantic_resize_keys` + `resize/4` build + `valid_resize?/1` add the three fields with `pos_integer | nil` validation.
- `lib/image_pipe/plan/key_data.ex` — `data(%Resize{})` adds the three fields (`optional_data/1`).
- `lib/image_pipe/transform/operation/resize.ex` — `defstruct` + `@type` add the fields; `resolve_dimensions/2` applies the **per-candidate** grow/clamp bounding step to `intermediate` and `target` (new private helpers `apply_bounds/2` + `bound_scale/2` + the grow-vs-clamp predicate), with `:auto`-axis pass-through, an all-nil fast path, and floor-the-area-binding-axis so `w·h ≤ max_area`.
- `lib/image_pipe/transform/plan_executor.ex` — `resize_from/2` copies the three fields onto the transform `Resize`.
- `lib/image_pipe/parser/iiif.ex` — `@schema` adds the three options + post-`validate!` cross-field check; remove the "conformance lie" comment.
- `lib/image_pipe/parser/iiif/plan_builder.ex` — `image_plan/3` reads bounds + computes `eff_max_height = mh || mw`; `size_operations/1 → /2` (arity bump) threads bounds into every resize; `info_plan/3` adds the three keys to `params` (always present, nil when unset).
- `lib/image_pipe/parser/iiif/info.ex` — `document/2` emits `maxWidth`/`maxHeight`/`maxArea` when configured (`@extra_features` untouched).
- `fiddle/lib/image_pipe_fiddle/application.ex` — demo bounds in `build_iiif_opts/0`.
- `fiddle/assets/IiifControls.svelte` — re-enable the `^` toggle for `max`.
- `fiddle/assets/iiif-path.ts` — stale-comment cleanup only (if any).
- `docs/iiif_3_support_matrix.md` — surface + stage/order + behavioral/pixel + validator-N/A + `sizeUpscaling`-divergence note + contradiction fix.
- **No edit needed**: `grammar.ex` (bounds are config, not URL); `info_renderer.ex` (pass-through); the Docker validator task **and `validator/server.exs`** (no by-name test; endpoint stays bounds-free); telemetry `Logger` (no event change).

## Out of scope (separate #257 slice)

- Extra output formats (`jp2`/`gif`/`tif`) — gated by libvips encode support; its own spec.
- A 400 (rather than clamp) on explicit-size overflow — the spec doesn't require it; the uniform clamp is the chosen, conformant behavior.
- Per-request fill / granular tiling config and info/derivative caching — unrelated follow-ups.
- Optimizing decode-shrink for clamped-down explicit requests — correctness holds; perf is deferred.

## Review cycle (per AGENTS.md) — RUN, findings folded in

Three parallel reviewers ran with disjoint lenses; all findings were verified against the code/spec and folded into this spec.

1. **IIIF compatibility** (ground truth: local `/Users/hlindset/src/iiif-image-api-3.0-spec/spec.md`) — confirmed `max`/`^max` semantics, the uniform-ceiling reading of the "for all requests … server-imposed limits" MUST, the `maxHeight = maxWidth` enforce-but-advertise-only-configured decision, cross-field rules, per-form behavior, and that no upstream validator test is missed. **Folded:** the §5.7 `sizeUpscaling`-requires-`maxWidth`-or-`maxArea` MUST → documented divergence (not a hard config gate); the `maxArea` rounding-overshoot → floor-the-binding-axis so `w·h ≤ max_area`; the `validator/server.exs` must-stay-bounds-free note (`size_up.py` expects `^max` == full source); full-quote + confined-form citations.
2. **Transform/resize correctness** — confirmed the predicate excludes `pct`/`^w,`/`^,h`, the `reject_enlargement`/`upscale_required` independence, the all-nil no-op, the `maxArea`-only `^max` math, and the non-materializing/decode-planner claims. **Folded (blockers):** `^max` has `target = :auto` and `intermediate = source`, so the grow scale derives from + applies to **`intermediate`** with `:auto`-axis pass-through; the predicate reads the **normalized** op + the `enlarge` boolean; **per-candidate** `bound_scale`; the all-nil **early return**; the cover/fill `result_box`-not-scaled **scope guard** (bounds honored for `:fit`/`:force` only).
3. **Architecture/boundaries + cache** — confirmed product-neutrality (symmetric to `min_*`), key-data inclusion + "ETag for free" (both consume the same `plan_material`), the constructor/`semantic?` validation as a distinct Plan boundary, no new Boundary crossing/export, and no key-data version bump. **Folded:** cross-field check via post-`validate!` (not `:custom`); `size_operations/1 → /2` is an arity bump; `params` keys always present for safe dot-access; the explicit "no Logger change" note.

Spec re-reviewed inline after folding (no placeholders, internally consistent, single-slice scope).
