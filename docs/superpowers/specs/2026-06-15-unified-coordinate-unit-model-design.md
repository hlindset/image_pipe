# Unified coordinate/unit model — design spec

**Issues:**
- [#313](https://github.com/hlindset/image_plug/issues/313) — TwicPics: coordinate focus and `focus=auto`
- [#314](https://github.com/hlindset/image_plug/issues/314) — TwicPics: crop coordinates should be zero-based (`@0x0` rejected)
- [#315](https://github.com/hlindset/image_plug/issues/315) — TwicPics: relative units (% / scale) for crop dimensions and coordinates

**Date:** 2026-06-15
**Status:** Proposed (revised after two parallel review passes)
**Delivery:** Single spec, single PR. The imgproxy differential bake and IIIF conformance are pixel-neutrality regression guards; new behavior is gated by native-API + TwicPics + IIIF tie-hitting tests.

> **Revision note.** The first draft was reviewed by five disjoint reviewers
> (imgproxy / IIIF / TwicPics compatibility, architecture/boundary, internal
> correctness). They found two load-bearing premises wrong: (1) imgproxy does
> **not** use one rounding rule — it uses round-half-away-from-zero for
> *dimensions* (`imath.Round`/`Scale`) and round-ties-to-even for
> *positions/offsets* (`RoundToEven`), and the current code already mirrors this
> split; "standardize on banker's" was a regression. (2) The imgproxy bake does
> not exercise the `Resize` relative-dimension path, so it cannot gate that
> change. This revision folds in every accepted finding (see §10).

## 1. Summary

The three issues are TwicPics-specific symptoms of one structural gap: coordinates
and units are handled inconsistently across the stack. The same concept — *a
fraction of some reference dimension* — is encoded multiple ways depending on the
operation struct, resolved by duplicated executor helpers, and gated independently
in each parser.

This work **unifies the coordinate/unit model**: one canonical measure vocabulary
in the Plan, one resolver module that owns the resolution arithmetic, and parsers
reduced to pure translation. **Rounding is preserved per consumer, not unified to
one rule** (see §4.3 / §6) — the imgproxy dimension-vs-position rounding split is
intentional and is documented in one place rather than flattened.

The three issues fall out as instances:

- **#314** — zero-based crop coordinates — the *position* role allows `0`; the
  TwicPics parser stops forcing `> 0` on coordinates.
- **#315** — relative crop dims/coords — the TwicPics parser emits canonical
  relative measures instead of gating to pixels.
- **#313 (relative coords)** — `p`/`s` focus coordinates — scale-invariant
  fractions through the existing `{:focal, ratio}` path.
- **#313 (bare-px coords)** — **deferred to its own issue** (needs a
  running-dim-at-focus-position capture mechanism entangled with orientation; see
  §8).
- **#313 (`focus=auto`)** — **out of scope**, explicit documented rejection;
  follow-up issue for a future `:smart` guide.

Architecture facts confirmed in review and relied on here:

- The runtime resolution machinery already exists and is exercised in production.
- imgproxy and IIIF have **no separate executors** — their parsers translate into
  the native `CropRegion` / `CropGuided` / `Resize` Plan operations that run
  through `crop.ex` / `resize.ex`. (imgproxy emits only `CropGuided` + `Resize`,
  never `CropRegion`; `CropRegion` is IIIF/TwicPics.)
- Focal guides are resolved **eagerly** to `{:fp, float, float}` in the
  PlanExecutor (`tagged_executable_gravity`), not late in `crop.ex`.

## 2. The problem, concretely

| Concept | `Resize` | `CropRegion` | `CropGuided` offset | Resolution helper |
|---|---|---|---|---|
| absolute | `{:px, n}` | `{:px, n}` | `{:pixels, n}` | — |
| relative | `{:percent, n}`, `{:scale, n}` (floats) | `{:ratio, n, d}` (exact) | `{:scale, n}` | — |
| relative (IIIF size) | `zoom_x/zoom_y` (float, via `apply_zoom`) | `{:ratio, n, d}` | — | — |
| helper | `resize.ex` `resolve_relative_dimension` → `to_pixels` | `crop.ex` `crop_dimension` | `crop.ex` `crop_offset` | `geometry.to_pixels` (also `extend_canvas.ex`, anchor machinery) |

The defects:

1. **Tag drift** — `:px` vs `:pixels` for absolute.
2. **Encoding drift** — relative is float `{:percent}`/`{:scale}`/`zoom` in some
   places, exact `{:ratio}` in others.
3. **Duplicated arithmetic** — "measure × reference → px" is implemented in
   `crop_dimension`, `crop_offset`, `resolve_relative_dimension`, and `to_pixels`
   (the latter also consumed by `extend_canvas.ex` and the anchor/coordinate-crop
   machinery).
4. **Parser gates** — TwicPics rejects relative crop units and zero coordinates
   at the parser layer, though the Plan and executor already accept them.

**Not a defect:** the two rounding regimes (`crop.ex` ties-to-even for
positions/offsets; `resize.ex`/`to_pixels` half-away for dimensions) are
**intentional** and match imgproxy's `RoundToEven` vs `imath.Round`. The
unification must **preserve** them, not collapse them.

## 3. Decisions

| Decision | Choice |
|---|---|
| Scope of "widen it" | **Unify the model** — one vocabulary, one resolver module, parsers translate-only. |
| Resolver consolidation | **Consolidate the arithmetic + vocabulary; preserve each consumer's rounding exactly.** Native Plan + TwicPics + imgproxy + IIIF all flow through the shared resolver functions; imgproxy/IIIF stay pixel-neutral by construction. |
| Canonical relative encoding | **Normalize relative *dimensions* to `{:px, n}` + exact `{:ratio, n, d}`.** Rewrites `Resize`'s float `{:percent}`/`{:scale}` dims + `min_width`/`min_height` to ratio. **Offsets are NOT folded** (kept `number()`/`{:pixels}`/`{:scale}` float — folding to ratio shifts imgproxy pixels on an unguarded path). **`zoom_x`/`zoom_y` are NOT folded this PR** (separate float-multiply path; deferred — see §8). |
| Rounding | **Per-consumer, preserved.** Dimensions → half-away-from-zero (`imath.Round`); positions/offsets → ties-to-even (`RoundToEven`). Documented in one table (§4.3). **No** single-rule unification. |
| Native constructor | `Operation.resize` keeps accepting `percent`/`scale` *sugar* and converts to `{:ratio, n, d}` at construction (via `Plan.Measure`); the stored field type is `{:px}`/`{:ratio}`. Existing native callers and tests keep working; `50p` and `0.5s` converge to the same stored ratio. |
| `focus=<coords>` | `p`/`s` (relative) only this PR. **Bare-px deferred** to its own issue. |
| `focus=center` | **Not changed** — invalid TwicPics anchor (the API `anchor` param has 8 values, no `center`); current rejection stays. |
| `focus=auto` / smart | **Deferred.** Explicit rejection; follow-up for a `:smart` guide. |
| `rotate` angle, `Padding` relative units | Out of scope. |
| crop-size rounding alignment | **Out of scope** — `crop.ex` `crop_dimension` uses ties-to-even for crop *size* today, a latent divergence from imgproxy's half-away (`CalcCropSize`). Preserved as-is here; filed as a separate bake-gated follow-up so this PR stays pixel-neutral for imgproxy. |
| Delivery | Single spec, single PR. |

### Why normalize to px + ratio

`percent` / `scale` / `zoom` are *dialect sugar* (TwicPics `p`/`s`, imgproxy
`scale`, IIIF `pct:`); the meaning is one rational fraction of a reference. The
neutrality principle puts the meaning in the core Plan (`{:ratio, n, d}`, exact —
good for cache key / ETag) and the sugar in the parser. The conversion machinery
already exists in TwicPics (`decimal_term` / `scaled_integer`).

## 4. Design

### 4.1 Canonical vocabulary — `ImagePipe.Plan.Measure` (new, Plan boundary)

Defines one measure type and the role-validation helpers the `operation.ex`
constructors call. **Resolution does not live here** (execution-time, transform
boundary). **`Geometry.resolve*` trusts the struct** — no re-validation of a
`Plan.Measure` inside the resolver (consistent with "trust operation structs
inside the transform boundary").

```
measure  :: {:px, integer()} | {:ratio, integer(), pos_integer()}
```

Roles, validated by helpers here:

| Role | Allowed | Rule | Resolves to |
|---|---|---|---|
| **dimension** (extent) | px, ratio | px `> 0`, ratio `n > 0, d > 0` | `≥ 1` |
| **position** (coordinate) | px, ratio | px `≥ 0`, ratio `n ≥ 0, d > 0` | `≥ 0` |
| **offset** | `number()`, `{:pixels, n}`, `{:scale, n}` | signed | float (see §4.3) |
| **guide/focal** | `{:focal, {:ratio,…}, {:ratio,…}}` | ratio in `0..1` | `0..1` |

Notes:
- **position** names #314 as a concept (`0` valid by definition).
- **offset is left unchanged** — a distinct tagged union (`number()`/`{:pixels, n}`
  for signed absolute, `{:scale, n}` *float* for fractional). It is **not**
  normalized to ratio: the `{:pixels}` vs `{:scale}` distinction is load-bearing
  for DPR (`{:pixels}` offsets are DPR-scaled, `{:scale}` are not — matching
  imgproxy's `|x| >= 1` → `RoundToEven(x*dpr)` vs `|x| < 1` →
  `ScaleToEven(width, x)` dispatch, committed at parse time by the imgproxy
  grammar), and folding the `{:scale}` *float* to an exact ratio changes
  imgproxy's `bounds * value` arithmetic (`bounds * n/d`) enough to flip an
  even-rounded tie — a 1px drift on a path no bake fixture covers. So offsets stay
  exactly as they are today.
- The **focal** role stays `{:ratio,…}`-only this PR (bare-px focus deferred), so
  no widening of the executable gravity slot is needed.
- `:auto` / `:full_axis` remain operation-specific markers (omitted axis /
  use-entire-axis); they are **not** measures and are resolved by the operation
  against the running dimension *before* calling the resolver (as `crop.ex`
  already does for `:auto`).

### 4.2 Operation struct changes (Plan boundary)

- **`Resize`** — `dimension` becomes `:auto | {:px, pos} | {:ratio, pos, pos}`
  (drop float `{:percent}`/`{:scale}`). `min_width`/`min_height` follow the same
  type. `offset` is **unchanged** (`number() | {:pixels, n} | {:scale, n}`).
  `zoom_x`/`zoom_y` are **unchanged** (stay float; IIIF `pct:n` keeps its current
  float-multiply path — normalization deferred, §8).
- **`CropRegion`** — already `{:px} | {:ratio}` for coords (zero-capable) and
  dims; no type change, now produced with relative coords/dims by TwicPics too.
- **`CropGuided`** — **unchanged** (offset `number() | {:pixels, n} | {:scale, n}`;
  focal guide `{:focal, ratio, ratio}`).
- **`Canvas`** — already `:auto | {:px} | {:ratio}`; references the shared measure
  type, no behavior change.
- **`Padding`** — stays px-only; out of scope.

`operation.ex` constructors (`tagged_*`, `offset/3`, `region_size`) delegate role
validation to `Plan.Measure`, keeping the rules in one place (this is a
relocation of the existing `tagged_*` logic, not a new guard surface; `semantic?/1`
keeps using the same source of truth).

### 4.3 One resolver module — consolidate into `ImagePipe.Transform.Geometry`

Collapse the duplicated arithmetic (`crop.ex` `crop_dimension`/`crop_offset`,
`resize.ex` `resolve_relative_dimension`, `geometry.to_pixels`) into role-specific
functions. **`Geometry` stays an unexported intra-transform helper** (not a
boundary export — nothing outside transform calls it).

```
Geometry.resolve_dimension(measure, reference, opts) :: integer()   # half-away; opts: clamp?
Geometry.resolve_position(measure, reference)        :: integer()   # preserve current rule (see table)
Geometry.resolve_offset(offset, reference, dpr)      :: float()     # NOT rounded here
Geometry.resolve_focal(ratio, reference)             :: float()     # 0..1 (ratio only this PR)
```

**Per-consumer rounding — preserved, documented in one place:**

| Consumer | Kind | Rounding | vs today |
|---|---|---|---|
| resize dims / min-dims / zoom (`resize.ex`) | dimension | half-away (`round/1`) | unchanged |
| `extend_canvas.ex` dims | dimension | half-away | unchanged |
| crop *size* (`crop.ex` `crop_dimension`) | dimension | **ties-to-even (current)** | unchanged this PR (latent imgproxy divergence; follow-up — §3) |
| gravity origin/offset (`crop.ex`) | position/offset | ties-to-even | unchanged |
| coordinate-crop origin (`crop.ex` `crop_coordinates/4`) | position | half-away (current via `to_pixels`) | unchanged |

The role abstraction must **preserve each call site's full behavior**, not just
"measure → px":
- **resize-dim does NOT clamp** (it returns `{:pixels, n}` and clamping happens
  later in `clamp_to_source`); **crop-dim DOES clamp** to bounds. Hence
  `resolve_dimension` takes a `clamp?` option; they are not the same call.
- **offset returns an unrounded float**, DPR-scales `{:pixels}` offsets, resolves
  `{:scale}` offsets against bounds (float `bounds * value`, no DPR). Rounding to
  even happens **at composition** with the origin (`round_offset_to_even` in
  `gravity_position`) — *round offset-to-even and origin-to-even separately, then
  sum*. This sequence and the float `{:scale}` arithmetic are load-bearing for
  imgproxy parity and must be preserved; `resolve_offset` must not round
  internally and must not convert `{:scale}` to a ratio.
- the anchor machinery (`anchor_to_scale_units` / `anchor_to_pixels`) and the
  coordinate-crop path are also `to_pixels` consumers; they are folded in with
  their current rounding preserved. `extend_canvas` *offsets* round half-away
  (`round/1`) — preserved at that call site (do not assume all offset consumers
  round-to-even).

**Net pixel effect of the consolidation:** zero for imgproxy and IIIF — rounding,
arithmetic, and encodings are preserved (crop dims already ratio; offsets stay
float `{:scale}`/`{:pixels}`; resize dims px; IIIF regions already ratio; IIIF
`pct:n` zoom stays float). The bake and IIIF conformance are pure regression
guards. Pixel changes occur **only** on (a) the new TwicPics relative
crop/coord/focus paths, and (b) native-API + TwicPics `percent`/`scale` *resize
dimensions*, which move from float `round(reference·percent/100)` to exact-ratio
`round(reference·n/d)` — a real change in float-operation order that differs by
1px at some ties (covered by new tests, §4.6). imgproxy/IIIF never drive that
resize path.

### 4.4 Parsers become translate-only

**TwicPics `units.ex`:**
- Split `length/1` into `dimension_length/1` (px `> 0`) and `position_length/1`
  (px `≥ 0`). Both convert `p`/`s` → exact `{:ratio, n, d}` via the
  `decimal_term`/`scaled_integer` path (exact from string form — **not** the
  current float `number/1` path). `position_length` needs a zero-allowing variant
  of that path (`0p` → `{:ratio, 0, 1}`); `dimension_length` keeps strictly
  positive. **Negative coordinates stay rejected** at the parser (TwicPics
  coordinates are "positive lengths") — do not rely on clamp to absorb them.
- `coordinates/1` uses `position_length/1`; `size/1` / `crop_size/1` use
  `dimension_length/1`.

**TwicPics `plan_builder.ex`:**
- Delete `pixels_only/2`, the `region_size` px-gate, and the `crop_coordinates`
  px-gate. `crop_region`, `crop_guided`, and `inside` accept ratio + zero. A
  region crop still requires *both* axes explicit (no `:auto`/`:full_axis` for a
  region size) — only the px-only restriction goes. → **closes #314 and #315.**

**imgproxy / IIIF parsers:** IIIF `pct:` regions already emit `{:ratio,…}` and
flow through the shared resolver unchanged. IIIF `pct:n` size keeps its current
float zoom (`zoom = num/den` via `apply_zoom`) — **not** normalized this PR
(deferred, §8), so IIIF size is pixel-neutral. imgproxy offsets stay float
`{:scale}`/`{:pixels}` (not folded). No imgproxy or IIIF arithmetic/rounding/
encoding change.

### 4.5 Coordinate focus — #313 (relative units only this PR)

The focal guide and the `focus`/`cover` guide-threading already exist.

- TwicPics `focus=<coords>` with `p`/`s` (`position_length` each) → `{:ratio, n, d}`
  per axis → `{:focal, ratio, ratio}` → existing `{:fp, float}` path. A fraction is
  **scale-invariant**, so it is correct under any chain ordering (including an
  intervening resize) with **no new machinery**.
- **Bare-px** `focus=<coords>` → **explicit documented rejection** this PR, with a
  follow-up issue (a px coordinate needs the running dimension *at the focus's
  chain position*, which a fraction does not — see §8).
- `focus=center` → **still rejected** (not a valid TwicPics anchor). Center is
  already the default focus when `focus` is omitted.
- `focus=auto` → explicit documented rejection; follow-up for a `:smart` guide.

### 4.6 Docs / fiddle / tests

**Docs:**
- `docs/twicpics_support_matrix.md` — flip rows for Coordinates (zero-based,
  `0x0` = top-left), Crop size / Crop coordinates (relative units), and
  `focus=<coords>` (relative only; bare-px and `auto` remain 🚫 with follow-up
  refs). Mark any out-of-range *positive* focus/coordinate clamping as a
  **deliberate, upstream-unverified** host choice (TwicPics docs are silent on
  clamping). (Axes: **surface** + **stage/order**.)
- `docs/imgproxy_support_matrix.md` — note the shared resolver in the pipeline
  section. No behavioral/pixel row changes (imgproxy is pixel-neutral).
- `docs/iiif_3_support_matrix.md` — no behavioral/pixel change (IIIF is
  pixel-neutral this PR); a **stage/order** note that IIIF regions/sizes resolve
  through the shared resolver.

**Fiddle (TwicPics provider, #306 — `fiddle/assets/`):**
- `TwicCropControls.svelte` — crop W/H + origin switch to the unit-capable
  dimension control (the resize control already does px/%/scale).
- `TwicCropOriginPicker.svelte` — origin min `0`; minimap maps clicks to the
  chosen unit; clamp `[0, running − size]`.
- Focus card — gains a **relative** coordinate mode (`p`/`s`); bare-px and `auto`
  not offered (parser rejects them).
- `twicpics-path.ts` (+ `twicpics-path.test.ts`) — origin coords `≥ 0`, relative
  crop units; crop **size** stays `> 0`.
- Gate + commit; leave the visual check to the user (no self-preview).

**Tests:**
- `Plan.Measure` — property tests for role validation (dimension `> 0`, position
  `≥ 0`, ratio normalization) and `percent`/`scale` → ratio conversion.
- `Geometry` — property tests per role: `resolve_dimension` (half-away, clamp
  option), `resolve_position`, `resolve_offset` (float, DPR-scale, no internal
  round), `resolve_focal` clamp to `0..1`.
- **Native-API pixel tests** for the `Resize` relative-dimension change
  (`percent`/`scale` → ratio): decode + compare, including a tie-hitting case.
  **Rewrite `resize_relative_resolution_property_test.exs`** — its RHS pins the
  *old* float order `round(reference·percent/100)`; the ratio path computes
  `round(reference·n/d)`, which differs by 1px at ~some ties (float-operation
  order, not rounding mode). The assertion must be rewritten to the ratio order
  `round(reference·num/den)`; this is a real resolution change, **not** a no-op.
- **Cache key / ETag** — reshape `ImagePipe.Plan.KeyData` for the ratio encoding
  of resize dims/min-dims (`zoom`/offsets unchanged, so their key encodings are
  untouched); update `key_data_test.exs`. Because `Operation.resize` converts
  `percent`/`scale` sugar to a stored `{:ratio}`, `{:percent, 50}` / `{:scale, 0.5}`
  inputs now produce the **same** stored ratio → the **same** key/ETag — update
  the "distinct relative magnitudes" / percent-vs-scale-encoding assertions
  accordingly. Greenfield: reshape in place, no data-version bump.
- TwicPics wire conformance — `crop=WxH@0x0` crops from top-left; relative crop
  dims + coords produce expected geometry (decode + compare); `p`/`s` coordinate
  focus steers the next `cover`/`crop` (decode + compare); crop **dimensions**
  still reject `0`; **negative** coords, bare-px focus, and `focus=auto` rejected.
- **imgproxy differential bake** — pixel-neutrality regression guard for the
  resolver consolidation (imgproxy crop scale flows through `crop_dimension`).
  Follow the bake workflow in
  `test/support/image_pipe/test/imgproxy_differential/README.md`.
- **IIIF wire conformance** — regression guard (IIIF is pixel-neutral this PR).
- Re-confirm crop's sequential-safety classification is unaffected
  (`requires_materialization?` keys only on `:smart`/`{:detect,…}` gravity; this
  work touches none of those).
- Remove now-dead float-pixel clauses only with **per-call-site producer proof**:
  `to_pixels` is shared by `anchor_to_scale_units`/`anchor_to_pixels` and the
  coordinate-crop path, not just crop dims. Verify each removed clause (the
  `is_float` branches, `{:pixels, float}` crop dims) has no in-repo producer across
  *all* callers before deleting; delete the clause and any test pinning it rather
  than preserving a dead path.

## 5. Forward compatibility: affine / expression measures

TwicPics permits arbitrary arithmetic (e.g. `100p - 20` = *100% of the reference −
20px*), which is **affine in the reference** (`value = scale·reference + px_const`)
and cannot reduce to a single `{:px}` or `{:ratio}` at parse time. This design is
forward-compatible:

- Today's `{:px, n} | {:ratio, n, d}` is a **strict subset** of the affine form.
  Adding arithmetic later is **additive**: widen `measure` with
  `{:affine, {n, d}, px_const}` (or `{:expr, tree}`) and add one resolver clause.
  No existing value, role, or call site changes.
- The resolver already takes the reference at execution time — exactly what an
  affine/expression measure needs. Only the *type* and the *parser's evaluator*
  grow; evaluation stays in the parser boundary.

**Decision:** ship the two-variant union now (YAGNI; the widening is provably
non-breaking). Revisit affine-up-front only if arbitrary arithmetic becomes
near-term roadmap.

## 6. Rounding ownership

Rounding is **per-consumer and preserved**, owned at the call site inside the
transform boundary (the resolver provides the primitives; each consumer selects
its documented mode — §4.3 table). It is **not** Plan data and **not** threaded.
The two regimes (dimension half-away, position/offset ties-to-even) are imgproxy's
intentional split, now documented in one table instead of scattered.

Escalation path, in order, used **only with evidence**:
1. **Default:** per-consumer mode at the call site (this design).
2. **If a fixture shows a dialect needs a different rule for the same op shape:** a
   declarative rounding-policy field on the **`Plan.Output` struct** (same pattern
   as the output color-profile policy — the *struct field* in the plan boundary,
   not the `ImagePipe.Output` boundary), read by the executor and passed to the
   resolver. Not a synthetic per-op flag. Added only with a failing fixture.

**Suspected future divergence: IIIF.** The IIIF spec (§4.7) makes rounding
implementation-defined, so when `zoom`/`pct:n` *is* eventually normalized to ratio
(deferred follow-up, §8), exactness-at-ties could shift the derived axis. That
follow-up must land a tie-hitting `pct:n` fixture (the existing IIIF wire tests use
evenly-dividing values and hit no ties, and the imgproxy bake cannot see IIIF) —
which is also the "failing fixture" this escalation requires. Not needed this PR,
since IIIF stays pixel-neutral. Ground-truth against
`/Users/hlindset/src/iiif-image-api-3.0-spec/spec.md`.

**Known latent divergence (follow-up, not this PR):** `crop.ex`'s crop-*size*
resolution uses ties-to-even, while imgproxy `CalcCropSize` uses half-away. This
PR preserves the current behavior (keeps imgproxy pixel-neutral); a separate
bake-gated change aligns crop size to half-away.

## 7. Boundaries

- `ImagePipe.Plan.Measure` lives in the **plan** boundary. **Add it to
  `lib/image_pipe/plan.ex` `exports:` and to the exact-match assertion in
  `test/image_pipe/architecture_boundary_test.exs`** (the assertion is exact —
  the build breaks otherwise).
- Resolution lives in the **transform** boundary; `transform → plan` is already a
  declared, tested dependency, and `plan` does not depend on `transform` (no
  cycle). `Geometry` stays **unexported** (intra-transform helper).
- Parsers stay in the **parser** boundary and emit canonical `Plan.Measure`
  values — no resolution, no premature gating.

## 8. Out of scope (with follow-ups)

- **Bare-px focus coordinates** (#313 px) — needs a `State`-carried focal point
  (like `pending_orientation`) that captures the running dimension at the focus's
  chain position and converts px → fraction there, plus an orientation-frame
  interaction (px measured in the display frame vs resolved in the storage frame
  under quarter turns). Its own issue.
- **`focus=auto` / smart subject detection** — follow-up `:smart` guide (also
  satisfies imgproxy `g:sm`).
- **crop-size half-away alignment** — separate bake-gated follow-up (§6).
- **`zoom_x`/`zoom_y` → exact-ratio normalization** (IIIF `pct:n`) — a separate
  float-multiply path (`apply_zoom`/`normalize`/`result_box_axis` + the resize
  constructor's numeric validation), not the dimension resolver; deferred so IIIF
  stays pixel-neutral. Follow-up, with the IIIF tie fixture (§6).
- **Offset → ratio normalization** — not pursued; offsets stay float `{:scale}`/
  `{:pixels}` (folding shifts imgproxy pixels — §3, §4.1).
- **`rotate` angle**, **relative `Padding`**, **affine/expression measures**
  (§5), **any materialization-classification change**.

## 9. Acceptance

- `crop=WxH@0x0` parses and crops from top-left; crop **dimensions** still reject
  `0`; **negative** coordinates still rejected. (#314)
- Relative crop dims + coords (`crop=50px50p`, `crop=200x200@(1/3)sx0.5s`) parse
  and produce the expected geometry. (#315)
- `focus=<coords>` with `p`/`s` translates into a focal guide and steers the next
  `cover`/`crop`; **bare-px** focus and `focus=auto`/`focus=center` are explicit
  documented rejections. (#313, partial — bare-px deferred)
- One canonical measure vocabulary (`Plan.Measure`) and one resolver module
  (`Geometry`) in place; native Plan + TwicPics relative dims/coords, imgproxy
  crop dims, and IIIF regions all resolve through them (IIIF `pct:n` zoom and
  crop offsets remain on their existing paths — §8).
- `Plan.KeyData` reshaped for resize dim/min-dim ratios; cache-key/ETag tests
  updated (incl. the `{:percent,50}`/`{:scale,0.5}` → same-ratio key-collapse).
- Docs updated (`twicpics_`, `imgproxy_`, `iiif_3_` matrices); fiddle TwicPics
  provider exposes the new behavior.
- **Gates green:** `mise run precommit:fiddle`; imgproxy differential bake
  (pixel-neutral regression guard); IIIF wire conformance (pixel-neutral);
  rewritten native-API resize relative-resolution + pixel tests. Any divergence is
  a deliberate, documented tolerance/quarantine decision.

## 10. Review findings folded in

- **Rounding is two intentional regimes, not one** — resolver preserves
  dimension=half-away, position/offset=ties-to-even per consumer (§3, §4.3, §6).
- **imgproxy bake doesn't gate the Resize relative path** — added native-API
  pixel tests; bake reframed as a pixel-neutrality regression guard (§4.6, §9).
- **Resolver under-modeled call sites** — role-specific functions; offset returns
  unrounded float (compose-then-round preserved); resize-dim no-clamp vs crop-dim
  clamp; `extend_canvas`/anchor consumers enumerated (§4.3).
- **`KeyData` reshape + `50p`/`0.5s` key collapse** — explicit work item (§4.6).
- **`focus=center` invalid** — change dropped (§3, §4.5).
- **Focal late-resolution wrong (semantics + mechanism)** — relative focus only,
  via existing `{:focal, ratio}`; bare-px deferred (§4.5, §8).
- **Architecture** — `Geometry` unexported; `Plan.Measure` export + arch-test
  edits; offset tags deliberately distinct (DPR); resolver trusts struct;
  `Plan.Output` = struct field (§4.1, §4.3, §7).
- **IIIF `pct:n` is float zoom** — zoom normalization **deferred** (separate
  float-multiply path); IIIF stays pixel-neutral this PR (§4.2, §4.4, §8).
- **Negative coords** — kept as parser rejection, not clamp-absorbed (§4.4).
- **Resize `min_width`/`min_height`** — included in the dimension normalization;
  `zoom_x`/`zoom_y` deferred (§4.2, §8).
- **Dead float-pixel clauses** — deleted only with per-call-site producer proof
  (`to_pixels` has non-dimension callers) (§4.6).

### Second-pass review (re-review of §4.2/§4.3) — folded in

- **Offset `{:scale}` → `{:ratio}` fold is not pixel-neutral for imgproxy** (both
  re-reviewers) — fold dropped; offsets stay float (§3, §4.1, §4.2).
- **`resize_relative_resolution_property_test` does not "stay green"** — the change
  is float-operation *order* (`reference·percent/100` vs `reference·n/d`), ~1823
  inputs differ by 1px; the assertion must be rewritten to the ratio order. Spec
  rationale corrected (§4.6).
- **`zoom_x`/`zoom_y` "flow through the resolver" was loose** — zoom is a separate
  float-multiply path + constructor validation; normalization deferred (§4.2, §8).
- **`extend_canvas` offset rounds half-away**, not ties-to-even — preserved at that
  call site, noted (§4.3).
