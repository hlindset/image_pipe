# imgproxy pixel-effects cluster: `adjust`, `colorize`, `gradient`

**Date:** 2026-06-19
**Status:** Design approved (pending written-spec review)

## Overview

Add three imgproxy **Pro** processing options to `ImagePipe.Parser.Imgproxy`:

- `adjust` / `a` — meta-option fanning out to brightness/contrast/saturation.
- `colorize` / `col` — solid color overlay.
- `gradient` / `gr` — transparency→color ramp overlay.

All three are imgproxy Pro, so there is **no OSS differential oracle and no accessible Pro source**. Acceptance is ImagePipe's own pixel fixtures (intent-compatible), exactly as the already-shipped Pro filters `monochrome`/`duotone`/`brightness`/`contrast`/`saturation` are accepted — not a differential bake. They occupy imgproxy's stage-9 `applyFilters` region and are realized as transform-chain operations (`colorize`, `gradient`) or pure parser sugar (`adjust`).

### In scope

`adjust`, `colorize`, `gradient` — **plus realigning the existing `brightness`/`contrast`/`saturation` argument semantics to be 1:1 with imgproxy** (required for `adjust` to be faithful; see "Realign br/co/sa" below). Backwards-compat is a non-concern (greenfield/unreleased), so changing already-shipped option behavior is in bounds.

**Argument parity, not pixel parity.** All options here are imgproxy **Pro** with no OSS bake and no accessible Pro source. "1:1" means the **arguments** match imgproxy's documented contract — accepted ranges/types, the additive-vs-multiplicative operation, and the value that means "unchanged" (`0` for brightness, `1` for contrast/saturation). Exact pixel output stays ImagePipe's own interpretation, locked by fixtures (same as `mc`/`dt`).

### Out of scope (deferred to their own issues)

- `progressive_blur` / `pbl` (#346) — **currently missing from `docs/imgproxy_support_matrix.md` entirely**; shares `direction`/`start`/`stop` machinery with `gradient`. Issue covers implementation + adding the matrix row.
- `unsharp_masking` / `ush` (#347) — redefines an unsharp-masking *config* baseline ImagePipe does not have; semantically orphaned, needs its own design.
- `blur_areas` / `ba` (#348) — area coords are in the **source EXIF frame** but are rotated/flipped by user `rotate`/`flip`; a deferred-orientation (#182 family) frame-mapping problem, not a flat overlay.

## Option semantics (imgproxy docs, `docs/usage/processing.mdx`)

### Realign `brightness` / `contrast` / `saturation` (prerequisite)

The existing options share one `:adjustment` parser type (`-100..100`) and a multiplier transform (`(100+v)/100`), which is **not** imgproxy's argument model. Realign each to imgproxy's documented contract:

| Option | imgproxy arg | Unchanged at | Operation |
| --- | --- | --- | --- |
| `brightness` / `br` | integer `-255..255` | `0` (no-op → emit nothing) | **additive** offset (vips `linear` addend on the 0–255 scale) |
| `contrast` / `co` | positive float (`> 0`) | `1` (no-op → emit nothing) | multiplicative around mid-gray; pass the float as the contrast factor |
| `saturation` / `sa` | positive float (`> 0`) | `1` (no-op → emit nothing) | saturation factor where `1` = unchanged |

Concrete changes:

- **Parser:** replace the shared `:adjustment` type for these three with per-option types — `brightness` → signed integer in `-255..255`; `contrast`/`saturation` → positive float (reject `≤ 0`). (Other `:adjustment` users, if any, are unaffected; this is scoped to br/co/sa.)
- **Transform ops:** `Brightness` becomes additive (drop the `(100+v)/100` multiplier); `Contrast`/`Saturation` take the imgproxy float factor directly (1 = unchanged) instead of the `(100+v)/100` remap.
- **`Plan.Operation` constructors + field validation:** ranges/types above; the "unchanged" sentinel moves from `0` to `1` for contrast/saturation.
- **`plan_builder.ex` no-op guards:** skip `brightness` at `0`, `contrast` at `1`, `saturation` at `1` (currently all skip at `0`).
- **Existing tests:** update br/co/sa parser-range and transform assertions to the new contract.
- **`docs/imgproxy_support_matrix.md`:** the br/co/sa rows lose the "ImagePipe range `-100..100`" divergence and become argument-1:1 (keeping the "Pro, pixels not bake-verified" note).

### `adjust` / `a`

```
a:%brightness:%contrast:%saturation
```

Meta-option; all three args optional. Expands into the (now-faithful) `brightness`/`contrast`/`saturation` operations in their existing chain slots, with imgproxy defaults for omitted/empty segments: brightness `0`, contrast `1`, saturation `1` (each a no-op when omitted). `a:50` ≡ `br:50`; `a::1.5` ≡ `co:1.5`; `a:::0.8` ≡ `sa:0.8`.

No new transform op, no new `Plan.Operation`, no cache-key change beyond what br/co/sa already contribute, no new fiddle control (the long-form controls already exist — though they need their ranges/labels updated for the realignment).

### `colorize` / `col`

```
col:%opacity:%color:%keep_alpha
```

- `opacity` — overlay opacity; `0` (ratio `0/d`) is a **no-op** (emit no operation), matching the mc/dt `intensity:0` no-op pattern.
- `color` — optional hex (3/6 digit); default `000` (black).
- `keep_alpha` — optional boolean (default `false`). `true` → result alpha = source alpha. `false` → result is opaque (overlay covers transparency).

### `gradient` / `gr`

```
gr:%opacity:%color:%direction:%start:%stop
```

- `opacity` — gradient opacity; `0` is a **no-op**.
- `color` — optional hex; default `000`.
- `direction` — optional. Named (`down` = default, `up`, `right`, `left`) **or** an arbitrary clockwise angle in degrees. Convention: `0°` = down (top transparent → bottom opaque), increasing clockwise; named map: `down`→0°, `left`→90°, `up`→180°, `right`→270°.
- `start`, `stop` — optional relative ramp positions in `[0,1]`; defaults `0.0` / `1.0`.

Gradient affects RGB only and preserves the source alpha (no `keep_alpha` arg in the imgproxy grammar).

## Compositing model (ImagePipe's chosen interpretation)

Linear blend, locked by fixtures since there is no oracle:

- **colorize:** `out_rgb = src_rgb · (1 − o) + C · o`, where `o` = `opacity`, `C` = color. Alpha per `keep_alpha`.
- **gradient:** `out_rgb = src_rgb · (1 − o·r(p)) + C · (o·r(p))`, where `r(p) ∈ [0,1]` is the ramp value at normalized position `p` along the direction axis: `r = 0` at `start` (transparent), `r = 1` at `stop` (full color), clamped outside `[start, stop]`. Source alpha preserved.

The arbitrary-angle ramp is generated from a libvips coordinate field projected onto the (cos θ, sin θ) direction vector, normalized between `start`/`stop`, then clamped to `[0,1]`. Named directions resolve to their angle equivalents and exercise the same code path.

## Architecture / touchpoints

`colorize` and `gradient` each follow the `monochrome`/`duotone` template:

1. `lib/image_pipe/plan/operation/{colorize,gradient}.ex` — neutral `Plan.Operation.*` struct.
   - `Colorize`: `opacity :: Color.alpha()`, `color :: Color.t()`, `keep_alpha :: boolean()`.
   - `Gradient`: `opacity :: Color.alpha()`, `color :: Color.t()`, `angle :: number()` (canonical degrees), `start :: float()`, `stop :: float()`.
2. `lib/image_pipe/transform/operation/{colorize,gradient}.ex` — executable op (`use ImagePipe.Transform`, `name/1`, `execute/2`), libvips compositing. `requires_materialization?: false` (uniform/coordinate-field ops; sequential-safe — prove via the sequential-access gate, do not assert).
3. `lib/image_pipe/plan/operation.ex` — add to `effect_operation` type union + `Operation.colorize/…` / `Operation.gradient/…` constructors with field validation.
4. `lib/image_pipe/plan/key_data.ex` — cache-key contribution for both ops.
5. `lib/image_pipe/parser/imgproxy/`:
   - `effects.ex` — add `adjust` is **not** a field (it fans out); add `colorize`, `gradient` fields.
   - `options.ex` / `option_grammar.ex` — grammar for `a`/`adjust`, `col`/`colorize`, `gr`/`gradient`, including the named-or-angle `direction` parse and the bad-boolean strictness already standard for imgproxy booleans (issue #173) on `keep_alpha`.
   - `plan_builder.ex` — `adjust` expands to the existing brightness/contrast/saturation builders; append `colorize_operation/1` then `gradient_operation/1` **after `saturation_operation/1`** in the ordered effect list (lines ~510–520).
6. `fiddle/assets/` — new controls + URL state for `colorize` and `gradient` (`ImgproxyControls.svelte`, `fiddle-url-state.ts`, `processing-path.ts`). No control for `adjust`. **Also update the existing `brightness`/`contrast`/`saturation` controls** to the realigned ranges/defaults (brightness `-255..255`; contrast/saturation positive float centered at `1`).
7. Docs:
   - `docs/imgproxy_support_matrix.md` — flip `adjust`, `colorize`, `gradient` rows to ✅ in "Background, effects, and overlays" (**surface** axis); update the stage-9 row to list the two new overlay ops; **also add the missing `progressive_blur`/`pbl` ⭕ row** (matrix-gap fix).
   - `docs/transform_operations.md` — extend the effect-order list (`…saturation, colorize, gradient`).

## Orientation

`colorize` is uniform → commutes with orientation. `gradient` has a direction but runs at stage-9 **after** the orientation flush, so its direction is display-frame — matching imgproxy (which special-cases EXIF only for `blur_areas`, not gradient). No special handling; lock with a display-frame gradient test (EXIF-rotated source + directional gradient → ramp lands on the display edge).

## Testing strategy

- **br/co/sa realignment** (update existing parser + transform tests): new arg contract — brightness signed integer `-255..255`, contrast/saturation positive float rejecting `≤ 0`; no-op sentinels brightness `0` / contrast `1` / saturation `1`; brightness additive vs contrast/saturation factor-at-1. Update or remove fixtures asserting the old `-100..100`/multiplier behavior.
- **Parser** (`test/.../parser/imgproxy/…`): grammar for `a`/`col`/`gr` including aliases, optional/omitted args, defaults, no-op opacity, named-and-angle direction, invalid color and invalid boolean (`keep_alpha`) errors, `adjust` → brightness/contrast/saturation expansion with imgproxy defaults (brightness `0`, contrast/saturation `1`) for empty segments.
- **Transform pixel fixtures** (ImagePipe-owned, not a bake): colorize opaque vs `keep_alpha`, gradient per named direction + one oblique angle + a non-default `start`/`stop`, opacity no-ops. Same fixture style as `monochrome`/`duotone`.
- **Sequential-access gate** (`test/.../transform/sequential_access_test.exs`): add `colorize`/`gradient` to the per-op sequential-vs-random equivalence + property coverage to justify `requires_materialization?: false`.
- **Cache key**: distinct keys for distinct colorize/gradient params; `adjust` keys identical to the equivalent `br/co/sa` request.
- **Wire** (`imgproxy_wire_conformance_test.exs`): one representative request per option decoding the body and asserting pixel change vs baseline (the no-geometry form too, per the request-boundary test guideline).

## Review

Per project guidelines, run the parallel reviewer cycle on this plan before implementation. At least one reviewer on the **compatibility** lens (semantics vs the local imgproxy checkout / docs), even though there is no bake — the surface grammar and defaults must match imgproxy. Other lenses: transform/libvips correctness, and parser/architecture-boundary.
