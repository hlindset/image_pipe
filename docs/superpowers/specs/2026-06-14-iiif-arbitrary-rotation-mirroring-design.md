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
defstruct [:angle, mirror: false]            # @enforce_keys [:angle] only — mirror has a default
@type t :: %__MODULE__{angle: number(), mirror: boolean()}
# angle: degrees clockwise, normalized to [0, 360); whole numbers stay integers; mirror: default false
```

- `angle` widens from `90 | 180 | 270` to any number in `[0, 360)`. **Whole-number angles are stored as integers** (`90`, not `90.0`) so that the right-angle routing guard and the lossless `vips_rot` branch fire for e.g. `"90.0"`. (`90.0 in [90,180,270]` is *false* in a guard — `in` compares with `===` — so a stray float would silently take the affine path and expose transparent corners on a 90° turn. Normalize at the parse/constructor boundary.)
- add `mirror: boolean()` (default `false`), **not** in `@enforce_keys`. This captures IIIF's **atomic** `!n` ("mirror on the vertical axis *before* rotation") as **one op**, isolating the dialect's mirror-then-rotate composition order in the operation struct.

**Validation gate must widen (was a BLOCKER omission).** `Plan.Operation.semantic?/1` is the gate `Plan.validated_pipelines/1` runs before transform execution; its current clause `semantic?(%Rotate{angle: angle}) when angle in @right_angles` (`plan/operation.ex:397`) returns `false` for any arbitrary or whole-number-float angle, rejecting the plan **before** the executor ever routes it. Widen to `is_number(angle) and angle >= 0 and angle < 360 and is_boolean(mirror)`. (The new op reuses the existing `Rotate` struct, so no *new* `semantic?` clause is needed — only this one widens. No module-enumerating canonical-order list exists; order lives in `executable_operations/3` dispatch + the IIIF builder's op concatenation, so "no canonical-order change" holds — but the validation enumeration is `semantic?/1` and it is *not* untouched.)

**Cache key must include `mirror` (correctness).** `Plan.KeyData.data(%Rotate{angle: angle})` (`plan/key_data.ex:137`) omits `mirror`, so `90` and `!90` would collide on one cache key and serve the wrong (mirrored vs not) bytes. Add `mirror: mirror` to the key data — per the Cache guidelines, every input that changes stored bytes is part of the key. (The ETag derives from the canonical plan, so it picks `mirror` up for free once the key data does.)

**Constructor shape.** Widen `Plan.Operation.rotate/1` to `rotate(angle, mirror \\ false)`: accepts any number in `[0, 360)` (normalizing whole floats to integers) + a boolean. The default arg keeps the existing arity-1 call site in `imgproxy/plan_builder.ex:326` (`Operation.rotate(angle)`, right-angle only) working unchanged — imgproxy stays off the new behavior. No keyword/opts form (no caller needs it).

**Do not widen `PendingOrientation.fold_rotate/2`** (typespec `0 | 90 | 180 | 270`): arbitrary/mirrored rotation never reaches the pending path, so the typespec stays accurate. Leaving it narrow is correct, not an oversight.

**Rejected alternative — keep `Rotate` pure, model mirror as a separate `Flip`.** For a right-angle mirrored request both ops would fold into `pending_orientation`, whose fixed flush order is rotate-then-flip — the *opposite* of IIIF's flip-then-rotate. Producing the correct order would require the executor to look ahead at sibling ops. A `mirror` field avoids lookahead and keeps each op self-contained. (For *arbitrary* angles the separate-`Flip` form would happen to work, because the chain rotate's materialize flushes the folded flip first — but the right-angle case makes the approach incorrect overall, so it is rejected for consistency.)

### Transform op — `ImagePipe.Transform.Operation.Rotate`

Execution, in order:

1. if `mirror` → horizontal flip (`Image.flip(image, :horizontal)`).
2. if `angle ∈ {0,90,180,270}` → `Vix.Vips.Operation.rot/2` (exact, lossless — **no #211 seam even when mirrored**), the same direct-Vix primitive `OrientationFlush.maybe_rotate/2` uses.
3. else (arbitrary) → fill exposed corners **transparent**:
   - ensure the image has an alpha band (add one if the source is opaque);
   - **premultiply → affine-rotate → unpremultiply**, following the established `with_alpha_premultiplied` pattern in `transform/operation/blur.ex` (premultiply → cast to band format → rotate → unpremultiply → cast back). `vips_rotate` does **not** premultiply internally; rotating un-premultiplied RGBA over a transparent background dark-fringes the resampled/anti-aliased edges. This is a hard requirement, not a note.
   - call **`Vix.Vips.Operation` directly** (e.g. `Vix.Vips.Operation.rotate/3` / the affine primitive) with the raw 4-element `[0,0,0,0]` RGBA background. **Do not** use the `Image.rotate/3` facade — its `:background` option validation rejects a 4-element RGBA list (accepts only number / 3-element / 1-element), exactly the transparent-corner case we need. Calling `Vix.Vips.Operation` directly to bypass the too-narrow `image` facade is the established precedent (`orientation_flush.ex` calls `Operation.rot` for the same reason).

`requires_materialization?/1` → **`true`** (rotation reads out of row order; both branches). Materialization failure surfaces as `{:decode, _}` → **415**, consistent with the existing contract (the `{:materialize_error, _}` wrap is owned by `Chain`/`PlanExecutor`, mapped to `{:decode, _}` by `Request.Processor`, as today).

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

- **Grammar `rotation/1`** — accept optional leading `!`, then a decimal angle. Return `{mirror :: boolean, angle :: number}`. Rules:
  - Accept the **closed** interval `[0, 360]` (IIIF: *"any floating point number from 0 to 360"* — 360 inclusive), then normalize `360 → 0`. Do **not** write a `< 360` guard that rejects exactly `360`.
  - **Strict remainder** like the rest of `grammar.ex` (e.g. `rotation/1:92`): require `{n, ""}` from `Float.parse`/`Integer.parse`; a non-empty remainder is invalid. This rejects `"45."`, `".5"`, `"45deg"`, `"45.0.0"`, `"4 5"`, leading/trailing whitespace.
  - Reject negatives (`"-5"`), `> 360` (`"361"`), a leading `+` (`"+45"`, which `Float.parse` already refuses), and an empty/`"!"`-only angle.
  - **Normalize whole-number floats to integers**: `"90.0" → 90`, `"45.0" → 45` (so right angles route to the lossless `vips_rot` branch); `"45.5"` stays a float. Leading zeros (`"045"`) are accepted (IIIF BNF doesn't forbid them) and normalized.
  - Percent-encoded `!` (`%21`) needs no grammar handling — IIIF path tokens are percent-decoded before `classify/1` (matrix line 105); a single wire test locks this in.
- **`PlanBuilder.rotation_operations/1`** — map `{mirror, angle}`:
  - `{false, 0}` → `[]`
  - `{true, 0}` → `[%Flip{axis: :horizontal}]`
  - `{m, a}` → `[%Rotate{angle: a, mirror: m}]` (executor routes right-angle-no-mirror to pending, else to the chain op).
- **`Info` `@extra_features`** — add `"rotationArbitrary"` and `"mirroring"`.

### Boundaries / telemetry

- Export `Operation.Rotate` from the `ImagePipe.Transform` boundary (`exports:` list) so `PlanExecutor` may name it (request/source/response code still must not — `:Rotate` is already in the architecture test's `@concrete_transform_names`, so that guard covers the new op for free). Add `Operation.Rotate` to the arch test's `assert_boundary_exports_include` list for documentation parity (the assertion is subset-based, so it isn't forced, but it documents intent).
- The chain op now emits a `[:transform, :operation]` span with name `:rotate` (the `:rotate` atom is already compiled — it appears as a literal in `key_data.ex` and the executor). **No Logger change is needed and none should be made**: the existing specific clause `message([:transform, :operation | _], …)` (`telemetry/logger.ex:158-160`) already renders these as `"image_pipe transform: <op> (#N)"` and deliberately **omits `:result`** (per the AGENTS.md rule that per-op spans show structure, not outcome). Do not add an outcome to that clause. Per-op `:params` may carry the struct (not sensitive). `docs/telemetry.md` already covers `[:transform, :operation]`; no edit.

### libvips capability

`vips_rotate`/`vips_rot` are core libvips — always present. The "build check" #257 anticipated does not materialize; document this rather than add a gate.

## Testing

Per `AGENTS.md`:

- **Materialization gate.** The op is classified `requires_materialization?: true`, so there is **no streaming claim to prove** — the obligation is correctness, not sequential-equivalence. Add the op (right-angle and arbitrary) to the equivalence harness as a **known-random anchor** demonstrating it raises under a genuinely streamed open (`access: :sequential`, `fail_on: :error`), reinforcing the harness self-check. Add a **property test** over angles × input shapes (sizes, with/without alpha, with/without mirror) asserting: output dimensions equal the rotated bounding box; corners transparent for non-multiples of 90; right-angle results are lossless (pixel-equal to `vips_rot`); content preserved.
- **Transform unit test** for `Transform.Operation.Rotate` (mirror-then-rotate order, right-angle `vips_rot` vs affine branch, alpha-band-added). Two edge assertions that catch the B1/B2 regressions specifically: (a) a transparent corner pixel is exactly `[…, 0]` alpha (catches a missing alpha band / wrong background arity); (b) an opaque-content pixel adjacent to a transparent corner keeps its un-fringed colour (catches a missing premultiply/unpremultiply).
- **IIIF wire conformance** (`iiif_wire_test.exs`): `rot_non90` (decode body → assert grown bounding-box dimensions + transparent corners on `png`; flatten-onto-white on `jpg`), `rot_mirror` (`!90` and `!45` → assert flip-then-rotate result vs a baseline). Keep representative, not exhaustive.
- **Grammar unit tests** — accept: `!90`, `!45`, `45`, `22.5`, `0`, `!0`, `360` (→0), `90.0` (→ integer 90, lossless branch), `045`. Reject: `-5`, `361`, `abc`, `+45`, `45.`, `.5`, `45deg`, `45.0.0`, `" 45"`, `"!"`. Plus a wire test that `%2145` ≡ `!45`.
- **plan_builder test** — assert **producer output only**: `{false,0}→[]`, `{true,0}→[%Flip{axis: :horizontal}]`, `{m,a}→[%Rotate{angle: a, mirror: m}]`. Do **not** assert executor routing (pending vs chain) from here — that's the executor's private dispatch; cover it via the wire test, not by reaching into routing from a parser test.
- Materialization failure → `{:decode, _}` → 415 parity with existing mid-chain/delivery paths.
- The op is added to the sequential-safety harness (`sequential_access_test.exs`) as a **known-random anchor** (it must raise under a genuinely streamed open) — reinforcing the harness self-check; there is no `false`-classification streaming claim to prove.

## Demo (fiddle)

Add a rotation control to `fiddle/assets/.../IiifControls.svelte` (angle `0–360`, e.g. number/slider, + a mirror `!` toggle) and URL state, so the two-provider demo can exercise arbitrary rotation and mirroring end-to-end.

## Docs

Update `docs/iiif_3_support_matrix.md`:

- **Surface axis** — move the `!n`/arbitrary row from ➖ to ✅; reflect the new `rotationArbitrary` + `mirroring` `extraFeatures`.
- **Stage/order + behavioral/pixel axis** — note: arbitrary/mirrored rotation runs as a materializing chain op after resize (EXIF flushed first), transparent corners with non-alpha flatten-onto-`flatten_background` (white), `vips_rot` retained for exact right angles (incl. mirrored) to avoid the #211 seam.
- No imgproxy parity row: imgproxy `rot` is right-angle only, so arbitrary rotation is **IIIF-driven** with no upstream reference (this is the compatibility reviewer's note — IIIF spec is ground truth, not imgproxy).

## Change sites (for the implementation plan)

Every site that assumes right-angle-only rotation, exhaustive:

- `lib/image_pipe/plan/operation/rotate.ex` — `defstruct [:angle, mirror: false]`; `@type angle :: number()`; drop "right angle" wording.
- `lib/image_pipe/plan/operation.ex:104-105` — `rotate(angle, mirror \\ false)` constructor; widen range to `[0,360)`, normalize whole floats → int, validate `mirror` boolean.
- `lib/image_pipe/plan/operation.ex:397` — **`semantic?(%Rotate{})` widen** (the validation BLOCKER): `is_number(angle) and angle >= 0 and angle < 360 and is_boolean(mirror)`.
- `lib/image_pipe/plan/operation.ex:28` — `@right_angles` stays (used by routing/normalization); `semantic?` no longer references it.
- `lib/image_pipe/plan/key_data.ex:137` — add `mirror: mirror` to the cache key data.
- `lib/image_pipe/parser/iiif/grammar.ex` (`rotation/1`) — new mirror + arbitrary grammar.
- `lib/image_pipe/parser/iiif/plan_builder.ex` (`rotation_operations/1`) — map `{mirror, angle}`.
- `lib/image_pipe/parser/iiif/info.ex` (`@extra_features`) — add `"rotationArbitrary"`, `"mirroring"`.
- `lib/image_pipe/transform/plan_executor.ex:177-180` — split the `%PlanRotate{}` clause (right-angle-no-mirror → pending; else → chain op); add a `%PlanRotate{} -> [%Transform.Operation.Rotate{}]` `executable_operations/3` clause + alias.
- `lib/image_pipe/transform/operation/rotate.ex` — **new** transform op.
- `lib/image_pipe/transform.ex` — add `Operation.Rotate` to `exports:`.
- `fiddle/assets/.../IiifControls.svelte` (+ URL state) — rotation angle + mirror controls.
- `docs/iiif_3_support_matrix.md` — surface + stage/order + behavioral/pixel updates.
- **No edit needed**: `pending_orientation.ex` `fold_rotate/2` typespec (stays narrow); `imgproxy/plan_builder.ex:326` (default `mirror` arg keeps arity-1 call working); `architecture_boundary_test.exs` `@concrete_*_names` (`:Rotate` already listed).

## Out of scope (separate #257 slices / later specs)

- Extra output formats (`jp2`/`gif`/`tif`) — gated by Vix/libvips encode support.
- `maxWidth`/`maxHeight`/`maxArea` size bounds + the `^max` upscaling interaction (folded-in #296), incl. re-enabling the fiddle "Allow upscaling (^)" toggle for `max`.
- Reconciling imgproxy `rot` / a native parser onto the new reusable op (YAGNI until a real consumer needs arbitrary rotation outside IIIF).

## Review cycle (per AGENTS.md) — RUN, findings folded in

Three parallel reviewers ran with disjoint lenses; all findings were verified against the code and folded into this spec.

1. **IIIF compatibility** — confirmed mirror-before-rotate, `[0,360]` closed-interval float range, transparent-corner / no-fill-knob conformance, exact `rotationArbitrary`/`mirroring` feature names, post-EXIF display frame. Tightened grammar acceptance (strict remainder, whole-float→int, `360` inclusive, edge rejects). No blockers.
2. **Transform/materialization correctness** — confirmed the EXIF-flush-before-rotate "for free" ordering, the `requires_materialization?: true` decision and gate plan, and `{:decode,_}`→415 parity. **Two blockers fixed in spec**: (B1) use `Vix.Vips.Operation` directly, not the `Image.rotate/3` facade, which rejects a 4-element RGBA background; (B2) premultiply→rotate→unpremultiply (vips_rotate does not premultiply). Corrected the telemetry-rendering prose (existing `[:transform,:operation]` clause already covers it).
3. **Architecture/boundaries** — confirmed the Plan-op/Transform-op pairing, executor split (no boundary violation), and minimal `exports:` add. **Blocker fixed**: widen `semantic?/1` (validation gate). **Should-fixes fixed**: `key_data.ex` mirror in cache key, constructor arity + imgproxy call site, plan_builder test asserts producer output only. Exhaustive change-site list added above.
