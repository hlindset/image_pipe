# IIIF arbitrary-angle rotation + mirroring (IIIF Phase 5, slice 1)

**Issue:** [#257](https://github.com/hlindset/image_pipe/issues/257) — IIIF `extraFeatures`. This spec covers **only** the rotation slice the issue's owner selected ("rotation alone first, incl. mirroring"): `rotationArbitrary` and `mirroring` (`!n`). The other `#257` workstreams — extra output formats (`jp2`/`gif`/`tif`) and `maxWidth`/`maxHeight`/`maxArea` size bounds (folded-in #296) — are **out of scope** and get their own later specs.

Bitonal quality (also listed in #257) is **already implemented** (`Transform.Operation.Bitonal`, wire tests, `info.json`) and is not touched here.

## Background / current state

User rotate and flip are deliberately **not** transform-chain operations today. A `%Plan.Operation.Rotate{}` or `%Plan.Operation.Flip{}` folds into deferred `State.pending_orientation` (`PlanExecutor.execute_operation/4`) and is applied **late** at the orientation-flush boundary (`Transform.OrientationFlush`), composing **EXIF auto-orient → user-rotate → user-flip**. The flush uses the exact, lossless `vips_rot` for right angles (the same primitive `Image.autorotate` and imgproxy use) and `Image.flip` for flips. This deferral exists to:

- run crop/resize in the **storage frame** with quarter-turn compensation (`quarter_turn?`, `Orientation.swap_resize`, `compensate_crop`, `display_source_dims`) so the observable result matches imgproxy while preserving the shrink-on-load and streaming fast paths;
- avoid libvips' arbitrary-angle affine resampler, which leaves a 1px background seam even at 90° multiples (#211).

The IIIF parser currently rejects any non-`{0,90,180,270}` rotation and any `!`-prefixed value as a **400** (`Parser.IIIF.Grammar.rotation/1`), and `info.json` advertises only `rotationBy90s`.

### Why arbitrary rotation cannot reuse `pending_orientation`

Arbitrary-angle rotation is an **affine resample** (`vips_rotate` / `Image.rotate`), fundamentally different from `vips_rot`:

- it grows the canvas to the rotated **bounding box** — *not* a width↔height swap, which is the only dimension change every compensation routine in `PlanExecutor` (`quarter_turn?`, `swap_resize`, `compensate_crop`, `display_source_dims`, `orient_decode_shrink`) knows how to model;
- it **resamples** (interpolation) and **exposes corners** that must be filled, which `vips_rot` never does.

Folding an arbitrary angle into `pending_orientation` would violate every quarter-turn invariant in the deferred-orientation machinery. So it must live elsewhere.

## Design

### Core decision — arbitrary rotation is a chain `Transform.Operation`

Introduce a genuine **`ImagePipe.Transform.Operation.Rotate`** chain operation (the "reusable native transform op" #257 asks for). Right-angle, non-mirrored rotation **stays on the existing lossless `pending_orientation`/`vips_rot` path, unchanged** — preserving imgproxy parity (whose `rot` is right-angle only) and the #211 seam avoidance.

The two paths coexist:

| Request shape | Path | Primitive |
|---|---|---|
| right angle (`0/90/180/270`), no mirror | `pending_orientation` (unchanged) | `vips_rot` (lossless) |
| any angle **with** mirror, or **any arbitrary** angle | new `Transform.Operation.Rotate` chain op | `vips_rot` for exact right angles; `Image.rotate` (affine) for arbitrary |

**Ordering comes for free.** `Chain.maybe_materialize/2` calls `Materializer.materialize/1` before any `requires_materialization?: true` op, and that path runs `OrientationFlush.flush/1`, which **applies pending EXIF auto-orient before** copying to RAM. So a materializing rotate op automatically sees the EXIF-corrected **display frame** and rotation lands "after EXIF auto-orient, in the display frame" — matching IIIF's coordinate model (region/size/rotation are defined post-EXIF) — with **no special `PlanExecutor` clause** (unlike padding/pixelate, which needed an explicit flush-first because they are *not* materializing). When a preceding resize already flushed, `materialized?: true` short-circuits the materialize and the op rotates the already-display-frame image; no double work.

### Plan model — extend `Plan.Operation.Rotate`

```elixir
@type t :: %__MODULE__{angle: number(), mirror: boolean()}
# angle: degrees clockwise, normalized to [0, 360); mirror: default false
```

- `angle` widens from `90 | 180 | 270` to any number in `[0, 360)`.
- add `mirror: boolean()` (default `false`). This captures IIIF's **atomic** `!n` ("mirror on the vertical axis *before* rotation") as **one op**, isolating the dialect's mirror-then-rotate composition order in the operation struct.

**Rejected alternative — keep `Rotate` pure, model mirror as a separate `Flip`.** For a right-angle mirrored request both ops would fold into `pending_orientation`, whose fixed flush order is rotate-then-flip — the *opposite* of IIIF's flip-then-rotate. Producing the correct order would require the executor to look ahead at sibling ops. A `mirror` field avoids lookahead and keeps each op self-contained. (For *arbitrary* angles the separate-`Flip` form would happen to work, because the chain rotate's materialize flushes the folded flip first — but the right-angle case makes the approach incorrect overall, so it is rejected for consistency.)

### Transform op — `ImagePipe.Transform.Operation.Rotate`

Execution, in order:

1. if `mirror` → horizontal flip (`Image.flip(:horizontal)`).
2. if `angle ∈ {0,90,180,270}` → `vips_rot` (exact, lossless — **no #211 seam even when mirrored**).
3. else (arbitrary) → ensure the image has an alpha band, then `Image.rotate(image, angle, background: [0,0,0,0])` (affine, premultiplied resample) so exposed corners are **transparent**.

`requires_materialization?/1` → **`true`** (rotation reads out of row order). Materialization failure surfaces as `{:decode, _}` → **415**, consistent with the existing contract (the wrap is owned by `Chain`/`PlanExecutor`, as today).

The chain op always carries a real rotation: `!0` (mirror, no rotate) is emitted by the IIIF plan_builder as a plain `%Plan.Operation.Flip{axis: :horizontal}` so it stays on the streaming pending-flip path; the new op is never asked to do "angle 0".

### Corner fill (spec-grounded)

IIIF 3.0 §Rotation: *"it is recommended that the client request the image in a format that supports transparency, such as `png`, and that the server return the image with a transparent background. There is no facility in the API for the client to request a particular background color or other fill pattern."*

So:

- the op **always** fills corners transparent (RGBA);
- for non-alpha output (e.g. `jpg`), the **existing** encoder flatten (`Output.Encoder.flatten_for_format/2`, guarded by `has_alpha?`) composites onto the host-level `Plan.Output.flatten_background` (**default white**);
- **no per-request fill knob is added** — the spec explicitly forbids one. The host config default is the correct, non-API-surface place for the fallback color.

### `PlanExecutor` routing

Split the current single `%PlanRotate{}` fold clause:

```elixir
# unchanged: right-angle, non-mirrored → defer (lossless, imgproxy parity)
def execute_operation(%PlanRotate{angle: a, mirror: false}, state, _ctx, _opts)
    when a in [0, 90, 180, 270] do
  fold into pending_orientation   # existing behavior
end

# new: arbitrary angle OR mirror → chain op (materializing; flushes EXIF first)
def execute_operation(%PlanRotate{} = rotate, state, ctx, opts) do
  run_executable(rotate, state, ctx, opts)   # -> [%Transform.Operation.Rotate{angle, mirror}]
end
```

Add the `%PlanRotate{} -> [%Transform.Operation.Rotate{}]` clause to `executable_operations/3`. No new flush-first clause is needed (materializing op — see "Ordering comes for free").

### Pipeline position

IIIF order **Region → Size → Rotation → Quality** is already what the plan_builder emits, and matches the native fixed order (imgproxy `rotateAndFlip` stage 7 sits after resize, before `applyFilters` stage 9). The arbitrary-rotate chain op slots **after** the resize and **before** the quality point-ops (`Gray`/`Bitonal`), which are sequential-safe and run on the materialized, rotated image. No canonical-order change is required.

### IIIF wiring

- **Grammar `rotation/1`** — accept optional leading `!`, then a decimal `0–360` (`Float.parse`, integers stay integers). Return `{mirror :: boolean, angle :: number}`. Reject negatives, `> 360`, and non-numeric. Normalize `360 → 0`.
- **`PlanBuilder.rotation_operations/1`** — map `{mirror, angle}`:
  - `{false, 0}` → `[]`
  - `{true, 0}` → `[%Flip{axis: :horizontal}]`
  - `{m, a}` → `[%Rotate{angle: a, mirror: m}]` (executor routes right-angle-no-mirror to pending, else to the chain op).
- **`Info` `@extra_features`** — add `"rotationArbitrary"` and `"mirroring"`.

### Boundaries / telemetry

- Export `Operation.Rotate` from the `ImagePipe.Transform` boundary (`exports:` list) so `PlanExecutor` may name it (request/source/response code still must not — unchanged).
- The chain op now emits a `[:transform, :operation]` span with name `:rotate` (the `:rotate` atom is already compiled via `Plan.Operation.Rotate`). No new event names → the default Logger's generic clause renders it (label + `:result` outcome); confirm a `logger_test.exs` line and `docs/telemetry.md` stay accurate. Per-op `:params` may carry the struct (not sensitive).

### libvips capability

`vips_rotate`/`vips_rot` are core libvips — always present. The "build check" #257 anticipated does not materialize; document this rather than add a gate.

## Testing

Per `AGENTS.md`:

- **Materialization gate.** The op is classified `requires_materialization?: true`, so there is **no streaming claim to prove** — the obligation is correctness, not sequential-equivalence. Add the op (right-angle and arbitrary) to the equivalence harness as a **known-random anchor** demonstrating it raises under a genuinely streamed open (`access: :sequential`, `fail_on: :error`), reinforcing the harness self-check. Add a **property test** over angles × input shapes (sizes, with/without alpha, with/without mirror) asserting: output dimensions equal the rotated bounding box; corners transparent for non-multiples of 90; right-angle results are lossless (pixel-equal to `vips_rot`); content preserved.
- **Transform unit test** for `Transform.Operation.Rotate` (mirror order, right-angle vs affine branch, alpha-band-added-then-transparent-corners, premultiply correctness at edges).
- **IIIF wire conformance** (`iiif_wire_test.exs`): `rot_non90` (decode body → assert grown dimensions + transparent corners on `png`; flatten-onto-white on `jpg`), `rot_mirror` (`!90` and `!45` → assert flip-then-rotate result vs a baseline). Keep representative, not exhaustive.
- **Grammar unit tests**: `!90`, `!45`, `45`, `22.5`, `0`, `!0`, `360`; rejects `-5`, `361`, `abc`.
- **plan_builder test**: `{mirror, angle}` → correct op(s) incl. `!0 → Flip` and right-angle-no-mirror → pending-bound `%Rotate{}`.
- Materialization failure → `{:decode, _}` → 415 parity with existing mid-chain/delivery paths.

## Demo (fiddle)

Add a rotation control to `fiddle/assets/.../IiifControls.svelte` (angle `0–360`, e.g. number/slider, + a mirror `!` toggle) and URL state, so the two-provider demo can exercise arbitrary rotation and mirroring end-to-end.

## Docs

Update `docs/iiif_3_support_matrix.md`:

- **Surface axis** — move the `!n`/arbitrary row from ➖ to ✅; reflect the new `rotationArbitrary` + `mirroring` `extraFeatures`.
- **Stage/order + behavioral/pixel axis** — note: arbitrary/mirrored rotation runs as a materializing chain op after resize (EXIF flushed first), transparent corners with non-alpha flatten-onto-`flatten_background` (white), `vips_rot` retained for exact right angles (incl. mirrored) to avoid the #211 seam.
- No imgproxy parity row: imgproxy `rot` is right-angle only, so arbitrary rotation is **IIIF-driven** with no upstream reference (this is the compatibility reviewer's note — IIIF spec is ground truth, not imgproxy).

## Out of scope (separate #257 slices / later specs)

- Extra output formats (`jp2`/`gif`/`tif`) — gated by Vix/libvips encode support.
- `maxWidth`/`maxHeight`/`maxArea` size bounds + the `^max` upscaling interaction (folded-in #296), incl. re-enabling the fiddle "Allow upscaling (^)" toggle for `max`.
- Reconciling imgproxy `rot` / a native parser onto the new reusable op (YAGNI until a real consumer needs arbitrary rotation outside IIIF).

## Review cycle (per AGENTS.md, before implementation)

Parallel reviewers with disjoint lenses:

1. **IIIF compatibility** — `!` = vertical-axis reflection before rotation; `[0,360]` float range; transparent-corner / no-fill-knob conformance; `info.json` `extraFeatures` correctness. IIIF spec is ground truth (no imgproxy reference for arbitrary rotation).
2. **Transform/materialization correctness** — the `requires_materialization?: true` decision and gate-test design; EXIF-flush-before-rotate ordering via `Chain`→`Materializer`; alpha/premultiply/transparent-corner handling; no perturbation of the deferred-orientation invariants (`quarter_turn?` et al.) for the right-angle path.
3. **Architecture/boundaries** — `Plan.Operation.Rotate` shape change; executor routing split; `Transform` boundary export; telemetry/Logger sync.
