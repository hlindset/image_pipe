# Unified coordinate/unit model — design spec

**Issues:**
- [#313](https://github.com/hlindset/image_plug/issues/313) — TwicPics: coordinate focus and `focus=auto`
- [#314](https://github.com/hlindset/image_plug/issues/314) — TwicPics: crop coordinates should be zero-based (`@0x0` rejected)
- [#315](https://github.com/hlindset/image_plug/issues/315) — TwicPics: relative units (% / scale) for crop dimensions and coordinates

**Date:** 2026-06-15
**Status:** Proposed
**Delivery:** Single spec, single PR. The imgproxy differential bake is the merge gate.

## 1. Summary

The three issues above are all TwicPics-specific symptoms of one structural gap:
coordinates and units are handled inconsistently across the stack. The same
concept — *a fraction of some reference dimension* — is encoded three different
ways depending on which operation struct you are in, resolved by three separate
executor helpers with two different rounding rules, and gated independently in
each parser.

This work **unifies the coordinate/unit model** so that every place that takes a
position, a dimension, or an offset speaks one canonical vocabulary, resolved by
one shared resolver, with parsers reduced to pure translation. The three issues
then fall out as instances:

- **#314** — zero-based crop coordinates — becomes "the *position* role allows
  `0`; the TwicPics parser stops forcing `> 0` on coordinates."
- **#315** — relative crop dims/coords — becomes "the TwicPics parser emits the
  canonical relative measure instead of gating to pixels."
- **#313 (coords)** — coordinate focus — becomes "the focal guide carries a
  *position* measure resolved late against the running image."
- **#313 (`focus=auto`)** — **out of scope**, kept as an explicit documented
  rejection; a follow-up issue tracks a future `:smart` guide.

The headline finding that shapes this design: **the runtime resolution machinery
already exists and is already exercised in production.** The Plan already carries
relative units, `crop.ex` already resolves them against the running image, and
IIIF already drives the relative-crop path with `{:ratio, …}` coordinates *and*
dimensions. imgproxy and IIIF do **not** have their own executors — their parsers
translate into the same `CropRegion` / `CropGuided` / `Resize` Plan operations
that run through `crop.ex` / `resize.ex`. So "the three resolvers" are three
helper *functions*, and "migrate imgproxy/IIIF" means "their outputs now flow
through the consolidated resolver, so their pixels must be re-baked" — not a
separate-executor migration.

## 2. The problem, concretely

The same "fraction of a reference" concept is encoded three ways, with tag drift,
encoding drift, and three resolvers:

| Concept | `Resize` | `CropRegion` | `CropGuided` offset | Executor resolution |
|---|---|---|---|---|
| absolute | `{:px, n}` | `{:px, n}` | `{:pixels, n}` | — |
| relative | `{:percent, n}`, `{:scale, n}` (floats) | `{:ratio, n, d}` (exact) | `{:scale, n}` | — |
| resolution helper | `resize.ex` `resolve_relative_dimension` | `crop.ex` `crop_dimension` | `crop.ex` `crop_offset` | `geometry.to_pixels` |

Problems:

1. **Tag drift** — `:px` vs `:pixels` for the same absolute concept.
2. **Encoding drift** — relative is a float `{:percent}`/`{:scale}` in `Resize`
   but an exact `{:ratio, n, d}` in `CropRegion` / IIIF regions / focal guides.
3. **Three resolvers, two rounding rules** — `crop.ex` uses round-ties-to-even
   (banker's, for imgproxy parity); `geometry.to_pixels` uses plain `round/1`.
4. **Parser gates** — TwicPics rejects relative crop units and zero coordinates
   *at the parser layer*, even though the Plan and executor already accept them
   (`plan_builder.ex` `pixels_only/2`, `region_size`, `crop_coordinates`;
   `units.ex` forces every length `> 0`).

## 3. Decisions (settled in brainstorming)

| Decision | Choice |
|---|---|
| Scope of "widen it" | **Unify the model** — one vocabulary, one resolver, parsers translate-only. |
| Resolver consolidation width | **Full consolidation, parity-gated.** Native Plan + TwicPics + imgproxy + IIIF all flow through the shared resolver; the imgproxy differential bake is the merge gate. |
| Canonical relative encoding | **Normalize to `{:px, n}` + exact `{:ratio, n, d}`.** Parsers convert `percent`/`scale` → ratio at parse. This rewrites `Resize`'s float `{:percent}`/`{:scale}` tags. |
| `focus=auto` / smart detection | **Deferred.** Explicit documented rejection; follow-up issue for a future `:smart` guide. |
| `rotate` angle | Out of scope (not a coordinate/unit in this sense). |
| Delivery | Single spec, single PR; bake-gated. |

### Why normalize to px + ratio (not keep percent/scale)

`percent` vs `scale` is *dialect sugar* (TwicPics `p`/`s`, imgproxy `scale`, IIIF
`pct:`); the meaning is identical — a rational fraction of a reference. The
project's neutrality principle says the core Plan carries the meaning and the
parser/adapter owns the sugar. `{:ratio, n, d}` is exact (good for cache key /
ETag canonicalization), is already what `CropRegion`/IIIF/focal guides use, and
the conversion machinery already exists in TwicPics (`decimal_term` /
`scaled_integer`). The cost — migrating `Resize` off float tags, the most
parity-tested op — is exactly what the differential bake gates.

## 4. Design

### 4.1 Canonical vocabulary — `ImagePipe.Plan.Measure` (new, Plan boundary)

Defines one measure type and the validation helpers the `operation.ex`
constructors call. **Resolution does not live here** (that is execution-time, in
the transform boundary).

```
measure  :: {:px, integer()} | {:ratio, integer(), pos_integer()}
```

Four **roles**, each with explicit rules, validated by helpers in this module:

| Role | Allowed | Rule | Resolves to |
|---|---|---|---|
| **dimension** (extent) | px, ratio | px `> 0`, ratio `n > 0, d > 0` | `≥ 1` |
| **position** (coordinate) | px, ratio | px `≥ 0`, ratio `n ≥ 0, d > 0` | `≥ 0` |
| **offset** | `number()`, `{:pixels, n}`, `{:ratio, n, d}` | signed | px (DPR-scaled for `:pixels`; vs bounds for ratio) |
| **guide/focal** | `{:focal, position, position}` | position rules | `0..1` |

Notes:
- The **position** role names #314 as a *concept*, not a one-off (`0` is valid by
  role definition).
- The **offset** role folds today's `{:scale, n}` offset into `{:ratio, n, d}`,
  removing the last float relative encoding. `number()` and `{:pixels, n}` are
  retained for absolute signed offsets.
- `:auto` / `:full_axis` remain operation-specific markers on the operation
  structs (omitted axis / use-entire-axis); they are **not** measures and are not
  owned by this module.

### 4.2 Operation struct changes (Plan boundary)

- **`Resize`** — `dimension` becomes `:auto | {:px, pos} | {:ratio, pos, pos}`
  (drop `{:percent}` / `{:scale}` floats). `offset` becomes
  `number() | {:pixels, n} | {:ratio, n, d}` (drop `{:scale}`).
- **`CropRegion`** — already `{:px} | {:ratio}` for coords (zero-capable) and
  dims; no type change, but it is now produced with relative coords/dims by
  TwicPics, not only IIIF.
- **`CropGuided`** — `guide`'s focal widens from
  `{:focal, {:ratio, …}, {:ratio, …}}` to `{:focal, position, position}` (i.e.
  the focal slot now also accepts `{:px, n}` for late resolution). `offset` aligns
  to the canonical offset type (`{:scale}` → `{:ratio}`).
- **`Canvas`** — already `:auto | {:px} | {:ratio}`; aligns to the shared
  measure type, no behavior change.
- **`Padding`** — stays px-only (`{:px, non_neg}`); no relative-unit work in this
  pass (out of scope, no issue driving it). Left as-is.

`operation.ex` constructor validation (`tagged_*` helpers, `offset/3`,
`region_size`, etc.) delegates to `Plan.Measure` role validators so the rules live
in one place.

### 4.3 One resolver — consolidate into `ImagePipe.Transform.Geometry`

Collapse `crop.ex` (`crop_dimension`, `crop_offset`), `resize.ex`
(`resolve_relative_dimension`), and `geometry.to_pixels` into:

```
Geometry.resolve(measure, reference, role) :: integer()   # px
Geometry.resolve_focal(position, reference) :: float()     # 0..1, clamped
```

- **Rounding:** standardize on **round-ties-to-even (banker's)** — imgproxy's
  rule, the primary compatibility target. This is the single change that shifts
  `resize.ex` off `round/1`, and the main thing the differential bake validates.
- `:auto` / `:full_axis` are resolved by the *operation* (to the running
  dimension) before/around calling `resolve`, since they are operation markers,
  not measures.
- **Rounding ownership** — the mode is a constant in the resolver, **not** Plan
  data and **not** threaded. See §6 for the escalation path if the bake forces a
  per-call-site or per-dialect rule.

### 4.4 Parsers become translate-only

**TwicPics `units.ex`:**
- Split `length/1` into `dimension_length/1` (px `> 0`) and `position_length/1`
  (px `≥ 0`). Both convert `p` (percent) and `s` (scale) → exact `{:ratio, n, d}`
  via the `decimal_term` / `scaled_integer` path (exact from string form — **not**
  the current float `number/1` path). `position_length` needs a zero-allowing
  variant of that path (`0p` → `{:ratio, 0, 1}`); `dimension_length` keeps the
  strictly-positive rule.
- `coordinates/1` uses `position_length/1`. `size/1` / `crop_size/1` use
  `dimension_length/1`.

**TwicPics `plan_builder.ex`:**
- Delete `pixels_only/2`, the `region_size` px-gate, and the `crop_coordinates`
  px-gate. `crop_region`, `crop_guided`, and `inside` accept ratio + zero. A
  region crop still requires *both* axes explicit (no `:auto`/`:full_axis` for a
  region size) — that validity rule stays; only the px-only restriction goes.
  → **closes #314 and #315.**
- `inside` (resize + canvas composition) loses its `pixels_only` gate too, since
  `Resize` and `Canvas` both accept ratio.

**imgproxy / IIIF parsers:** emit canonical measures. IIIF already emits
`{:ratio, …}` regions and zoom resizes — minimal change. imgproxy `{:scale}`
offsets → `{:ratio, n, d}`. No logic change beyond encoding; their pixels are
re-baked through the consolidated resolver.

### 4.5 Coordinate focus — #313

The focal guide already exists (`CropGuided.guide` types `{:focal, …}` plus the
`:smart` / `{:detect, …}` slots), and `focus` / `cover` already thread `acc.guide`
into the guided op.

- TwicPics `focus=<coords>` (`XxY`, `position_length` each):
  - `p` / `s` → `{:ratio, n, d}` directly (a static `0..1` fraction).
  - bare px → `{:px, n}`, **carried unresolved** into the focal slot and resolved
    **late** in `crop.ex` (`Geometry.resolve_focal({:px, n}, running_dim)` =
    `clamp(n / running_dim, 0..1)`) when the guided op consumes the guide.
- **Semantics:** the px focus resolves against the running image dimension at the
  point the guided op consumes the guide (consistent with TwicPics "running-dim"
  relative resolution). A compatibility reviewer confirms against the TwicPics
  parameters docs.
- `focus=center` → `:center` (trivial fix while in this surface; currently an
  explicit rejection).
- `focus=auto` → **kept as an explicit, documented rejection.** Follow-up issue
  for a future `:smart` guide (the `:smart` slot already exists in the type and
  would also satisfy imgproxy `g:sm`).

### 4.6 Docs / fiddle / tests

**Docs:**
- `docs/twicpics_support_matrix.md` — flip the rows for Coordinates (zero-based,
  `0x0` = top-left), Crop size / Crop coordinates (relative units), and
  `focus=<coords>`; keep `focus=auto` as 🚫 with the follow-up reference. (Axis:
  **surface** + **stage/order**.)
- Both `docs/twicpics_support_matrix.md` and `docs/imgproxy_support_matrix.md` —
  note the shared resolver / canonical measure in the processing-pipeline
  section. (Axis: **stage/order**; behavioral/pixel only if the bake surfaces an
  intentional divergence.)

**Fiddle (TwicPics provider, #306 — `fiddle/assets/`):**
- `TwicCropControls.svelte` — crop W/H + origin switch to the unit-capable
  dimension control (the resize control already does px/%/scale).
- `TwicCropOriginPicker.svelte` — origin min `0`; minimap maps clicks to the
  chosen unit; clamp `[0, running − size]`.
- Focus card — gains a coordinate mode (reuse the crop-origin minimap);
  `focus=auto` not offered (parser rejects it).
- `twicpics-path.ts` (+ `twicpics-path.test.ts`) — parse origin coords `≥ 0`,
  relative crop units; keep crop **size** `> 0`.
- Per standing preference: gate + commit, leave the visual check to the user
  (no self-preview of the fiddle UI).

**Tests:**
- `Plan.Measure` — property tests for role validation (dimension `> 0`, position
  `≥ 0`, ratio normalization) and `percent`/`scale` → ratio conversion.
- `Geometry.resolve` — property tests for resolution against a reference across
  roles, rounding (ties-to-even), and clamping; `resolve_focal` clamp to `0..1`.
- TwicPics parser — order-insensitivity / order-dependence unchanged; relative
  and zero coords/dims parse into the expected canonical measures.
- Wire conformance (`test/image_pipe/twic_pics_wire_conformance_test.exs`) —
  `crop=WxH@0x0` crops from the top-left; relative crop dims + coords produce the
  expected geometry (decode + compare pixels); coordinate focus steers the next
  `cover`/`crop` (decode + compare); crop **dimensions** still reject `0`.
- **imgproxy differential bake — the hard merge gate** for the resolver
  consolidation (esp. `Resize` moving to banker's rounding). Follow the
  bake → diagnose → tolerance → quarantine workflow in
  `test/support/image_pipe/test/imgproxy_differential/README.md`.
- Re-confirm crop's sequential-safety classification is unaffected (coordinate
  crop and coordinate focus add no random-access need beyond what region/guided
  crop already declares).

## 5. Forward compatibility: affine / expression measures

TwicPics permits arbitrary arithmetic in values (e.g. `100p - 20` = *100% of the
reference − 20px*). Such a value is **affine in the reference**
(`value = scale·reference + px_const`) and **cannot** be reduced to a single
`{:px}` or `{:ratio}` at parse time. This design is deliberately
**forward-compatible** with that future feature:

- Today's `{:px, n} | {:ratio, n, d}` is a **strict subset** of the affine form
  (`{:px, n}` ≡ scale `0`, px `n`; `{:ratio, n, d}` ≡ scale `n/d`, px `0`). Adding
  arithmetic later is **additive**: widen `measure` with an
  `{:affine, {n, d}, px_const}` (or full `{:expr, tree}`) variant and add one
  resolver clause. No existing value, role, or call site changes.
- The resolver **already takes the reference at execution time**
  (`resolve(measure, reference, role)`) — exactly what an affine/expression
  measure needs. Only the *type* and the *parser's evaluator* grow.
- The only step that would change is parse-time normalization: for `100p - 20`
  the parser would emit the affine form instead of a single ratio. That is the
  parser's job and stays in the parser boundary.

**Decision:** ship the two-variant union now (YAGNI — no arithmetic today, and the
widening is provably non-breaking). The measure type is a tagged union and the
resolver takes the runtime reference, so the affine extension is a new variant,
not a reshape. If arbitrary arithmetic becomes near-term roadmap, revisit and
adopt the affine form up front to avoid re-touching call sites.

## 6. Rounding ownership and escalation path

Rounding happens at resolution time (measure → px) inside the executor. The mode
is owned as follows, in order of preference:

1. **Default (this design):** one neutral rule (banker's / round-ties-to-even, =
   imgproxy's), a constant in the resolver. **Not** Plan data, **not** threaded.
2. **If the bake shows an op needs a different rule by role / call-site:** the
   executor selects the mode when it calls `resolve` — **internal to the
   transform boundary**, chosen at the call site, never on the Plan. No threading.
3. **Only if rounding genuinely diverges by *dialect* for the *same op shape***
   (e.g. imgproxy and TwicPics must round the same `CropRegion` differently to
   match their respective upstreams): mode becomes a **declarative policy field on
   the Plan** (the same pattern as the output color-profile policy on
   `Plan.Output`), resolved at execution — **not** a synthetic per-op flag. Added
   **only with a failing bake fixture proving it**, never speculatively.

**Prime suspect: IIIF, not TwicPics.** The IIIF Image API spec prescribes
specific sizing/region math whose rounding may not coincide with imgproxy's
banker's rule. The differential bake + IIIF conformance will surface it. The
resolver keeps rounding pluggable at the call site (cheap) without putting mode on
the Plan unless a fixture forces it. Ground-truth the IIIF rounding against the
local spec checkout (`/Users/hlindset/src/iiif-image-api-3.0-spec/spec.md`).

## 7. Boundaries

- `ImagePipe.Plan.Measure` lives in the **plan** boundary (canonical model +
  validation helpers). Operation structs and `operation.ex` reference it.
- Resolution (`Geometry.resolve` / `resolve_focal`) lives in the **transform**
  boundary, which already reads Plan structs. No new boundary dependency
  direction is introduced.
- Parsers (TwicPics / imgproxy / IIIF) stay in the **parser** boundary and emit
  canonical `Plan.Measure` values — no resolution, no premature gating.

## 8. Out of scope

- `focus=auto` / smart subject detection (follow-up issue for a `:smart` guide).
- `rotate` angle handling.
- Relative units for `Padding` (no driving issue).
- Arbitrary arithmetic / affine measures (forward-compatible, not built — §5).
- Any change to which operations require materialization.

## 9. Acceptance

- `crop=WxH@0x0` parses and crops from the top-left; crop **dimensions** still
  reject `0`. (#314)
- Relative crop dims + coords (`crop=50px50p`, `crop=200x200@(1/3)sx0.5s`) parse
  and produce the expected geometry. (#315)
- `focus=<coords>` (px and `p`/`s`) translate into a runtime-resolved focal guide
  and steer the next `cover`/`crop`; `focus=auto` is an explicit documented
  rejection. (#313)
- One canonical measure vocabulary (`Plan.Measure`) and one resolver
  (`Geometry.resolve`) are in place; native Plan, TwicPics, imgproxy, and IIIF
  all flow through them.
- `docs/twicpics_support_matrix.md` rows flipped; pipeline sections updated; the
  fiddle TwicPics provider exposes the new behavior.
- `mise run precommit:fiddle` passes; the imgproxy differential bake is green
  (or any divergence is a deliberate, documented tolerance/quarantine decision).
