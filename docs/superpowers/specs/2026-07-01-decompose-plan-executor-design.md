# Decompose `Transform.PlanExecutor` by concern

**Issue:** #433 — Refactor: decompose the oversized Transform.PlanExecutor by concern
**Type:** pure structural refactor (no observable behavior change)
**Date:** 2026-07-01

## Problem

`lib/image_pipe/transform/plan_executor.ex` has grown to ~1240 lines and blends
several distinct concerns behind one `@moduledoc false` module. It is correct
and heavily tested, but any single change now requires holding the whole file in
context. This decomposes it into focused transform-internal modules.

## Constraints (from the issue)

- **No observable behavior change.** Same pixels, statuses, telemetry, cache
  keys. Compatibility reviewer optional; lenses are architecture/boundary +
  correctness/test-preservation.
- **Lean on the existing suite as the safety net.** The orientation-deferral
  (#146/#182/#185/#211) and imgproxy resize-parity logic is subtle. The refactor
  *moves* code, it does not rewrite behavior. **If a test needs to change, stop
  and reconsider** (mechanical relocation of a test is fine; changing an
  assertion is a signal).
- Respect the `Transform.*` namespace/`Boundary` rules in `AGENTS.md`. Keep
  `Boundary` deps/exports minimal; the `plan → transform` direction stays
  forbidden (only `transform → plan`).

## Fixed points (things the refactor must not disturb)

- **`PlanExecutor.execute/3` stays the public entry point.** It is the sole
  production caller path (`Transform.execute_plan/3 → PlanExecutor.execute/3`)
  and every test drives `PlanExecutor.execute/3` directly. Its signature and
  module location are unchanged.
- Everything else in the module is private and free to relocate. No test calls
  any other `PlanExecutor` function (verified by grep across `test/`).
- All new modules live under `ImagePipe.Transform.*`, are `@moduledoc false`,
  and are used only within the `Transform` boundary — **no new `Boundary`
  exports are required** (PlanExecutor itself is unexported today).
- The `architecture_boundary_test.exs` guard that request/source/response code
  must not call `PlanExecutor.execute` directly is unaffected — PlanExecutor
  remains the orchestrator behind the `Transform` facade.

## Module split (4 modules)

### 1. `Transform.PlanExecutor` — orchestration + dispatch (slims to ~250 lines)

Owns:
- `execute/3`: sets `detector`/`detector_required`/`telemetry_opts`, seeds EXIF
  `pending_orientation` and runs the color-management preamble (both gated on the
  `seed_orientation` opt, both kept **inline** here — they are the small
  real-execution preamble; ~40 lines: `seed_color_management`,
  `run_color_management`, `exif_orientation`).
- `execute_pipelines/3`, `execute_pipeline/3`: the reduce-over-pipelines /
  reduce-over-operations loops, threading `State` + execution context, halting on
  error. The pipeline-boundary flush delegates to
  `OrientationScheduler.flush_if_pending/1`.
- `execute_operation/4`: the dispatch table. Orientation-aware ops delegate to
  `OrientationScheduler`; plain ops go through `run_executable/4`.
- `run_executable/4` (translate via `Lowering` then `Chain.execute/3`) and the
  `update_execution_context/3` threading, which calls `ResizePlanning` to compute
  the padding-scale context entries.

Depends on: `OrientationScheduler`, `Lowering`, `ResizePlanning`, `Chain`,
`Materializer` (indirect), `InputColorManagement`, `Telemetry`, `PendingOrientation`,
`State`, `Plan`.

### 2. `Transform.Lowering` — Plan→Transform op translation + shrink rescale (~350 lines)

The mechanical `Plan.Operation.* → Transform.Operation.*` translation. Owns:
- All `executable_operations/3` clauses (the per-`Plan.Operation` translation to
  a list of executable `Transform.Operation.*` structs).
- Tagged-value helpers: `tagged_executable_gravity`,
  `tagged_executable_resize_dimension`, `tagged_executable_optional_resize_dimension`,
  `tagged_dpr_float`, `tagged_ratio_to_float`, `tagged_logical_pixels`,
  `crop_dimension`, `crop_coordinate`, `canvas_dimension`, `canvas_rule`,
  `scale_canvas_dimension`, `scale_extend_offset`, `scaled_padding_side`,
  `executable_fill`, `round_half_to_even`.
- `resize_from/2`, `resize_mode/2`.
- Shrink-on-load coordinate rescale (concern 6 — it is part of lowering a crop):
  `rescale_crop_for_decode_shrink`, `shrink_abs_dimension`, `shrink_crop_from`,
  `shrink_abs_coordinate`, `shrink_abs_offset`.
- `reject_region_out_of_bounds?/2` (region-crop lowering detail).

Depends on: `Plan`, `Plan.Color`, `ResizePlanning`, `Transform.Operation.*`,
`Geometry`, `State`.

### 3. `Transform.ResizePlanning` — imgproxy resize-parity expansion (~350 lines)

The fit/cover/auto expansion and scale arithmetic. Owns:
- Resize expansion: `fit_resize_and_result_crop`, `fit_result_crop_bites?`,
  `fit_axis_exceeds?`, `result_box_crop_dimension`, `cover_resize_and_crop`,
  `cover_resize_and_crop_display_frame`, `tagged_executable_resize_operations`,
  `cover_resize?`.
- Branch classification: `plan_resize_branch`, `resize_auto_branch`,
  `auto_branch`, `orientation_diff`.
- Padding-scale: `resize_padding_scale`, `max_padding_scale_without_enlarge`,
  `compensate_no_enlarge_padding_scale`, `clamp_padding_scale`,
  `effective_padding_scale`.
- Display-frame dim helpers: `display_source_dims`, `display_live_dims` (both a
  function of `State.effective_source_dims` / live image dims + a pending
  quarter-turn swap; used by the branch/padding logic and by the executor's
  `SetFocus` resolve).

Note: `resize_from` and the `tagged_executable_*` helpers it calls live in
`Lowering`; `ResizePlanning` calls back into `Lowering` for those. To keep the
dependency edge one-directional (`Lowering → ResizePlanning`), the small set of
builder helpers `ResizePlanning` needs (`resize_from`, `tagged_executable_gravity`,
`result_box_crop_dimension` is local to ResizePlanning) will be resolved during
implementation by placing the primitive builders where the acyclic edge holds —
see "Open implementation detail" below.

Depends on: `Plan`, `Transform.Operation.Resize`, `Transform.Operation.Crop`,
`State`, `PendingOrientation`.

### 4. `Transform.OrientationScheduler` — deferred-orientation policy + compensation (~350 lines)

Lives next to the existing `Orientation` / `OrientationFlush` /
`PendingOrientation` family. Owns the orientation-aware execution policy:
- The orientation-aware `execute_operation` bodies: rotate/flip fold into
  `pending_orientation`; resize compensate-then-flush (including the quarter-turn
  display-frame cover path); padding/pixelate/gradient flush-first; trim
  materialize-without-orientation; region/gravity crop flush-and-compensate.
- `flush_if_pending/1`, `do_execute_crop/4`, `clear_source_frame/1`.
- Compensation: `compensate_crop/2`, `compensate_resize/2`, `orient_decode_shrink/2`,
  `split_offset/1`, `materializing_gravity?/1`.

`OrientationScheduler` builds executables via `Lowering` (and resize expansions
via `ResizePlanning` through `Lowering`), then applies compensation to the built
structs before `Chain.execute/3`.

Depends on: `Lowering`, `ResizePlanning`, `Orientation`, `PendingOrientation`,
`Materializer`, `Chain`, `State`, `Focus`.

## Dependency direction (acyclic)

```
PlanExecutor → OrientationScheduler, Lowering, ResizePlanning, Chain, Materializer
OrientationScheduler → Lowering, ResizePlanning, Orientation, PendingOrientation, Materializer, Chain
Lowering → ResizePlanning, Geometry, Operation.*
ResizePlanning → Operation.Resize, Operation.Crop, PendingOrientation, State
```

No cycles. `plan → transform` remains forbidden; all edges are within the
`Transform` boundary, so no `Boundary` `deps`/`exports` change is needed.

## Settled implementation detail (was open; resolved in the plan + plan review)

`cover_resize_and_crop_display_frame` and the fit/cover/auto builders computed
`tagged_executable_gravity(operation.guide)` internally — a helper that belongs to
`Lowering`. **Resolution (no leaf module, honoring the 4-module decision):** move
the resize-only primitives (`resize_from`, `resize_mode`,
`tagged_executable_resize_dimension`, `tagged_dpr_float`, `tagged_logical_pixels`)
into `ResizePlanning`, and **thread the already-translated `gravity` value into
`ResizePlanning` as a parameter** so `ResizePlanning` never calls
`tagged_executable_gravity`. This keeps the edge one-directional
(`Lowering → ResizePlanning`, never the reverse) with no shared leaf module.

Both plan reviewers (architecture/boundary + correctness) confirmed acyclicity
under this resolution and caught that **four** internal sites compute the gravity
today, not three — the `:auto`-branch `tagged_executable_resize_operations`
sub-clauses were the missed pair. The corrected full site list and the
gravity-threading chain live in the implementation plan
(`docs/superpowers/plans/2026-07-01-decompose-plan-executor.md`). No observable
behavior consequence.

## Verification

- **No new tests; no test behavior changes.** Relocating a test file/alias is
  fine; changing an assertion is a stop signal.
- Gate: `mise run precommit` (`mix format --check-formatted`,
  `mix compile --warnings-as-errors`, `mix credo --strict`, `mix test`).
- `architecture_boundary_test.exs` must stay green (it already asserts the
  PlanExecutor/transform-module rules).
- Because the safety net is behavioral equivalence, implementation proceeds by
  **moving code in small, compilable steps** (extract one module, keep the gate
  green, repeat), not by rewriting logic.

## Acceptance (from the issue)

- [x] Brief design note on the module split (this document), reviewed before
  implementation.
- [ ] `plan_executor.ex` reduced to orchestration + dispatch; concerns extracted
  into `Lowering`, `ResizePlanning`, `OrientationScheduler`.
- [ ] Full gate green with no test behavior changes.
- [ ] `Boundary` deps/exports still minimal and correct.
