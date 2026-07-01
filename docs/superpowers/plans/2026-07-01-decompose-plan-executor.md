# Decompose `Transform.PlanExecutor` Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans (inline, recommended for this plan) or superpowers:subagent-driven-development to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Split the ~1240-line `lib/image_pipe/transform/plan_executor.ex` into four focused transform-internal modules with zero observable behavior change.

**Architecture:** Extract by concern into `Transform.ResizePlanning`, `Transform.Lowering`, and `Transform.OrientationScheduler`, leaving `Transform.PlanExecutor` as orchestration + dispatch + the small inline color/EXIF preamble. Dependency edges stay acyclic (`PlanExecutor → OrientationScheduler → Lowering → ResizePlanning`), all within the existing `Transform` boundary, no new `Boundary` exports. This is a **move-refactor**: functions are relocated verbatim, not rewritten.

**Tech Stack:** Elixir, `Vix` (libvips), `Boundary`, ExUnit. Design note: [`docs/superpowers/specs/2026-07-01-decompose-plan-executor-design.md`](../specs/2026-07-01-decompose-plan-executor-design.md).

## Global Constraints

- **No observable behavior change.** Same pixels, statuses, telemetry, cache keys. This is verified behaviorally by the existing suite — there are **no new tests**.
- **No test behavior changes.** Relocating a test file or an `alias` is allowed; changing any assertion is a **stop-and-reconsider** signal (a required assertion change means the refactor altered behavior).
- **`PlanExecutor.execute/3` stays the public entry point** — same module, same signature. It is the sole caller path (`Transform.execute_plan/3`) and every test drives it directly.
- All new modules are under `ImagePipe.Transform.*`, `@moduledoc false`, used only within the `Transform` boundary → **no `Boundary` `deps`/`exports` changes**.
- The `plan → transform` dependency direction stays forbidden (only `transform → plan`).
- Run all tooling through `mise exec --`. The toolchain PATH caveat: prepend `$(mise where elixir)/bin` to PATH if `mise exec -- mix` resolves to the Homebrew shadow.
- Commit after each green task. This branch is a worktree branch; rename to a descriptive name (e.g. `refactor/decompose-plan-executor`) before the first push, not before commits.

## Test rhythm for this refactor

Because nothing user-visible changes, each task's "test" is: **the code compiles with no warnings, credo is clean, and the behavioral safety-net suite stays green.** The safety-net suite for the extracted logic is the transform test directory plus the wire-conformance and architecture-boundary tests:

```
mise exec -- mix compile --warnings-as-errors
mise exec -- mix credo --strict
mise exec -- mix test test/image_pipe/transform/ \
  test/image_pipe/imgproxy_wire_conformance_test.exs \
  test/image_pipe/architecture_boundary_test.exs
```

Call this the **TARGETED GATE**. The final task runs the **FULL GATE** (`mise run precommit`, i.e. format + compile + credo + full `mix test`, which includes the imgproxy differential lane).

If any targeted-gate test fails after a pure relocation, do **not** edit the test — re-examine the move for a dropped clause, a changed guard order, or a lost alias. A green targeted gate is the pass condition for every task.

**Targeted-gate blind spot (do not over-trust a green mid-refactor gate):** the cache-key, ETag, and output-negotiation tests are **not** in the targeted set — they run only at the FULL GATE (Task 4). This refactor consumes an already-built `Plan` and must not change the produced executable list in a way that alters any canonical-plan-derived value, but a regression there would surface only at the final full gate, not per-task. The move is verbatim so the risk is low; just don't read a green targeted gate as proving "same cache keys."

## Files

- Create: `lib/image_pipe/transform/resize_planning.ex` — imgproxy resize-parity resolution (Task 1).
- Create: `lib/image_pipe/transform/lowering.ex` — `Plan.Operation.* → Transform.Operation.*` translation + shrink rescale (Task 2).
- Create: `lib/image_pipe/transform/orientation_scheduler.ex` — deferred-orientation policy + compensation (Task 3).
- Modify: `lib/image_pipe/transform/plan_executor.ex` — shrinks to orchestration/dispatch across all tasks; final cleanup in Task 4.
- No test files change (aliases only, if a relocated helper is referenced — none are, per grep: tests use `PlanExecutor.execute/3` exclusively).

## The one settled implementation detail (from the spec's "open" item)

`ResizePlanning`'s crop-building helpers must not call `tagged_executable_gravity/1` (that helper stays in `Lowering`), so the `Lowering → ResizePlanning` edge stays one-directional with **no shared leaf module** (honoring the 4-module decision). Resolution: **thread the already-translated `gravity` value into `ResizePlanning` as a parameter.**

There are **four** internal sites in `ResizePlanning` that compute
`tagged_executable_gravity(operation.guide)` today; **all four** must switch to a
threaded `gravity` parameter, or a `tagged_executable_gravity` reference is
stranded in the leaf module and creates a `ResizePlanning → Lowering` cycle. (Both
plan reviewers flagged the original three-site list as missing the `:auto`-branch
site below — this is the corrected full set.)

- `cover_resize_and_crop/4` already takes `gravity` as a parameter — no change.
- `fit_resize_and_result_crop/3` currently computes it internally → change signature to `fit_resize_and_result_crop(resize, operation, state, gravity)` and use the passed `gravity`.
- `cover_resize_and_crop_display_frame/2` currently computes it internally → change to `cover_resize_and_crop_display_frame(operation, state, gravity)`.
- `tagged_executable_resize_operations/4` (reached only from `lower/4`'s `:auto` mode) computes `tagged_executable_gravity(operation.guide)` in its `:cover` sub-clause and passes `operation` into `fit_resize_and_result_crop` in its `:fit` sub-clause → change to `tagged_executable_resize_operations(branch, resize, operation, state, gravity)`; its `:cover` sub-clause passes the threaded `gravity` into `cover_resize_and_crop/4`, its `:fit` sub-clause passes it into `fit_resize_and_result_crop/4`.

Threading chain: `lower/4` holds `gravity` (passed by its caller) and forwards it to whichever of `cover_resize_and_crop/4`, `fit_resize_and_result_crop/4`, or `tagged_executable_resize_operations/5` its mode selects; `tagged_executable_resize_operations/5` forwards it again. No `ResizePlanning` function calls `tagged_executable_gravity`.

- Callers that compute the gravity: `Lowering`'s delegating `%PlanResize{}` clause (`ResizePlanning.lower(op, state, ctx, Lowering.tagged_executable_gravity(op.guide))` — an in-module call, `Lowering → ResizePlanning`), and `OrientationScheduler`'s quarter-turn cover clause (`ResizePlanning.cover_resize_and_crop_display_frame(op, state, Lowering.tagged_executable_gravity(op.guide))`).

`x_offset`/`y_offset` are untranslated pass-through values; `ResizePlanning` may read them off the operation struct directly (no `Lowering` dependency).

---

### Task 1: Extract `Transform.ResizePlanning`

**Files:**
- Create: `lib/image_pipe/transform/resize_planning.ex`
- Modify: `lib/image_pipe/transform/plan_executor.ex`

**Interfaces:**
- Produces (public, `@moduledoc false`, called only within the `Transform` boundary):
  - `lower(operation :: %Plan.Operation.Resize{}, state :: %State{}, context :: map(), gravity :: term()) :: [struct()]` — the `%PlanResize{}` → executable list for all four modes (`:fit`/`:cover`/`:stretch`/`:auto`). Wraps what were the four `executable_operations(%PlanResize{...})` clauses.
  - `cover_resize_and_crop(resize :: %Resize{}, state :: %State{}, gravity :: term(), {x_offset, y_offset}) :: [struct()]`
  - `cover_resize_and_crop_display_frame(operation :: %PlanResize{}, state :: %State{}, gravity :: term()) :: [struct()]`
  - `cover_resize?(operation :: %PlanResize{}, state :: %State{}) :: boolean()`
  - `resize_padding_scale(operation :: %PlanResize{}, state :: %State{}, mode :: :resize | :canvas_preserving) :: number()`
  - `display_source_dims(state :: %State{}) :: {pos_integer(), pos_integer()}`
  - `display_live_dims(state :: %State{}) :: {pos_integer(), pos_integer()}`
- Consumes: `ImagePipe.Plan.Operation.Resize`, `ImagePipe.Transform.Operation.Resize`, `ImagePipe.Transform.Operation.Crop`, `ImagePipe.Transform.State`, `ImagePipe.Transform.PendingOrientation`. Receives `gravity` pre-translated (see settled detail above).

- [ ] **Step 1: Create the module skeleton and move the resize-planning functions verbatim**

Create `lib/image_pipe/transform/resize_planning.ex` with `defmodule ImagePipe.Transform.ResizePlanning do @moduledoc false`. Move these functions **verbatim** out of `plan_executor.ex` (current line ranges as of this plan):

- Resize `executable_operations` clauses (currently lines 573–596: `:fit`, `:cover`, `:stretch`, `:auto`) → merge into a single public `lower/4` that dispatches on `operation.mode`. Each mode body is the current clause body, with `tagged_executable_gravity(operation.guide)` replaced by the passed-in `gravity` argument.
- `tagged_executable_resize_operations/4` (746–762) → `/5` taking `gravity` (see settled detail): its `:cover` sub-clause forwards `gravity` into `cover_resize_and_crop/4`, its `:fit` sub-clause forwards it into `fit_resize_and_result_crop/4`; drop both internal `tagged_executable_gravity(operation.guide)` calls
- `cover_resize_and_crop/4` (772–793) — unchanged
- `fit_resize_and_result_crop/3` (802–822) → `/4` taking `gravity`; replace the internal `tagged_executable_gravity(operation.guide)` with `gravity`
- `fit_result_crop_bites?/1`, `fit_axis_exceeds?/2`, `result_box_crop_dimension/1` (824–833)
- `cover_resize?/2` (837–842)
- `cover_resize_and_crop_display_frame/2` (857–884) → `/3` taking `gravity`; replace the internal `tagged_executable_gravity(operation.guide)` with `gravity`
- `resize_from/2`, `resize_mode/2` (886–907)
- `tagged_executable_resize_dimension/1`, `tagged_executable_optional_resize_dimension/1` (909–918)
- `resize_padding_scale/3`, `max_padding_scale_without_enlarge/2`, `compensate_no_enlarge_padding_scale/3`, `clamp_padding_scale/2` (1059–1130)
- `plan_resize_branch/2`, `resize_auto_branch/4`, `auto_branch/2`, `orientation_diff/2` (1132–1149, 1216–1242)
- `display_source_dims/1`, `display_live_dims/1` (1156–1171)
- `tagged_logical_pixels/1` (1209–1210), `tagged_dpr_float/1` (1212)

Add the aliases the moved code needs: `alias ImagePipe.Plan.Operation.Resize, as: PlanResize`, `alias ImagePipe.Transform.Operation.{Resize, Crop}`, `alias ImagePipe.Transform.{State, PendingOrientation}`, `alias Vix.Vips.Image, as: VipsImage` (for `display_live_dims`).

- [ ] **Step 2: Rewire `plan_executor.ex` to call `ResizePlanning`**

In `plan_executor.ex`:
- Add `alias ImagePipe.Transform.ResizePlanning`.
- Replace the four resize `executable_operations(%PlanResize{...})` clauses with one delegating clause:
  ```elixir
  defp executable_operations(%PlanResize{} = operation, %State{} = state, context) do
    ResizePlanning.lower(operation, state, context, tagged_executable_gravity(operation.guide))
  end
  ```
- In `update_execution_context/3`, replace `resize_padding_scale(...)` calls with `ResizePlanning.resize_padding_scale(...)`.
- Replace `cover_resize?(operation, state)` (in the orientation resize clause) with `ResizePlanning.cover_resize?(operation, state)`.
- Replace the quarter-turn `cover_resize_and_crop_display_frame(state)` pipeline call with `ResizePlanning.cover_resize_and_crop_display_frame(operation, state, tagged_executable_gravity(operation.guide))`.
- Replace `display_source_dims(state)` / `display_live_dims(state)` uses with `ResizePlanning.display_source_dims/1` / `ResizePlanning.display_live_dims/1`.
- Delete the now-moved private functions from `plan_executor.ex`. Keep `tagged_executable_gravity/1`, `tagged_ratio_to_float/1`, and the non-resize helpers in place (they move in Task 2).

Note: `tagged_executable_resize_dimension`, `tagged_dpr_float`, `tagged_logical_pixels` moved into `ResizePlanning`; if any remaining `plan_executor.ex` code still references them, that reference belongs to resize logic — verify none remain outside the moved set (`grep -n "tagged_dpr_float\|tagged_logical_pixels\|tagged_executable_resize_dimension" lib/image_pipe/transform/plan_executor.ex` should return nothing).

- [ ] **Step 3: Run the TARGETED GATE**

```
mise exec -- mix compile --warnings-as-errors
mise exec -- mix credo --strict
mise exec -- mix test test/image_pipe/transform/ test/image_pipe/imgproxy_wire_conformance_test.exs test/image_pipe/architecture_boundary_test.exs
```
Expected: compile clean (no unused-alias/function warnings), credo clean, all tests PASS. If a resize/padding/orientation test fails, a clause or the gravity threading was moved incorrectly — fix the move, do not touch the test.

- [ ] **Step 4: Commit**

```bash
git add lib/image_pipe/transform/resize_planning.ex lib/image_pipe/transform/plan_executor.ex
git commit -m "refactor(transform): extract ResizePlanning from PlanExecutor (#433)"
```

---

### Task 2: Extract `Transform.Lowering`

**Files:**
- Create: `lib/image_pipe/transform/lowering.ex`
- Modify: `lib/image_pipe/transform/plan_executor.ex`, `lib/image_pipe/transform/resize_planning.ex` (only if it needs `Lowering.tagged_executable_gravity` — it should NOT; verify)

**Interfaces:**
- Produces (public, `@moduledoc false`, boundary-internal):
  - `executable_operations(operation :: struct(), state :: %State{}, context :: map()) :: [struct()]` — the full `Plan.Operation.* → Transform.Operation.*` dispatch, including the `%PlanResize{}` clause that delegates to `ResizePlanning.lower/4`.
  - `tagged_executable_gravity(guide :: term()) :: term()`
  - `rescale_crop_for_decode_shrink(crop :: %Crop{}, decode_shrink :: nil | map()) :: %Crop{}`
- Consumes: `ResizePlanning` (for the resize clause + gravity threading), `Plan`, `Plan.Color`, `Plan.Operation.*`, `Transform.Operation.*`, `Transform.Geometry`, `Transform.State`.

- [ ] **Step 1: Create the module and move the lowering functions verbatim**

Create `lib/image_pipe/transform/lowering.ex` (`@moduledoc false`). Move **verbatim** from `plan_executor.ex`:

- All non-resize `executable_operations/3` clauses: `CropGuided`, `CropRegion`, `Canvas`, `PlanPadding`, `PlanBackground`, `PlanBlur`, `PlanSharpen`, `PlanPixelate`, `PlanMonochrome`, `PlanDuotone`, `PlanBrightness`, `PlanContrast`, `PlanBitonal`, `PlanGray`, `PlanRotate`, `PlanSaturation`, `PlanColorize`, `PlanGradient`, `PlanTrim` (currently 598–744).
- The delegating `executable_operations(%PlanResize{}, ...)` clause added in Task 1 (it calls `ResizePlanning.lower/4` and `tagged_executable_gravity/1`, both now in-module or via `ResizePlanning`).
- `crop_dimension/1`, `crop_coordinate/1` (920–925)
- `reject_region_out_of_bounds?/2` (927–942)
- `rescale_crop_for_decode_shrink/2`, `shrink_abs_dimension/2`, `shrink_crop_from/3`, `shrink_abs_coordinate/2`, `shrink_abs_offset/3` (955–994)
- `canvas_dimension/1`, `canvas_rule/2`, `scale_canvas_dimension/2`, `scale_extend_offset/2` (996–1018)
- `executable_fill/1` (1020–1027)
- `effective_padding_scale/3` (1029–1057) — **stays in Lowering, do NOT reunite with the similarly-named `resize_padding_scale/3` that moved to ResizePlanning in Task 1.** `effective_padding_scale` only reads precomputed values off the `context` map (set upstream by `update_execution_context → ResizePlanning.resize_padding_scale`); it does not call into ResizePlanning, so keeping it in Lowering creates no edge. Pulling `resize_padding_scale` back here by name would misplace resize-parity arithmetic in the lowering module.
- `scaled_padding_side/2` (1173), `round_half_to_even/1` (1175–1185)
- `tagged_executable_gravity/1` (all clauses, 1187–1207), `tagged_ratio_to_float/1` (1214)

Add aliases the moved code needs: the `Plan.Operation.*` plan-struct aliases (Background/Bitonal/Blur/Brightness/Canvas/Colorize/Contrast/CropGuided/CropRegion/Duotone/Gradient/Gray/Monochrome/Padding/Pixelate/Rotate/Saturation/Trim as their `Plan*` names + `Resize as PlanResize`), the `Transform.Operation.*` executable aliases, `alias ImagePipe.Plan.Color`, `alias ImagePipe.Transform.{Geometry, State, ResizePlanning}`.

- [ ] **Step 2: Rewire `plan_executor.ex` and `resize_planning.ex`**

- In `plan_executor.ex`: `run_executable/4` now calls `Lowering.executable_operations(operation, state, context)`. Add `alias ImagePipe.Transform.Lowering`. Remove all now-moved private functions and their now-unused `Plan.Operation.*` / `Transform.Operation.*` aliases. Where `plan_executor.ex` still needs `tagged_executable_gravity` for the quarter-turn display-frame call (added Task 1 Step 2), call `Lowering.tagged_executable_gravity/1`.
- In `resize_planning.ex`: confirm it does **not** reference `Lowering` (gravity is threaded in as a param). `grep -n "Lowering" lib/image_pipe/transform/resize_planning.ex` should return nothing.

- [ ] **Step 3: Run the TARGETED GATE** (same commands as Task 1 Step 3). Expected: all PASS, no warnings.

- [ ] **Step 4: Commit**

```bash
git add lib/image_pipe/transform/lowering.ex lib/image_pipe/transform/plan_executor.ex lib/image_pipe/transform/resize_planning.ex
git commit -m "refactor(transform): extract Lowering from PlanExecutor (#433)"
```

---

### Task 3: Extract `Transform.OrientationScheduler`

**Files:**
- Create: `lib/image_pipe/transform/orientation_scheduler.ex`
- Modify: `lib/image_pipe/transform/plan_executor.ex`

**Interfaces:**
- Produces (public, `@moduledoc false`, boundary-internal):
  - `execute_operation(operation :: struct(), state :: %State{}, context :: map(), opts :: keyword()) :: {:ok, %State{}} | {:error, term()}` — the orientation-aware execution for `%PlanRotate{}` (right-angle fold), `%PlanFlip{}`, `%SetFocus{}`, `%CropRegion{}`, `%CropGuided{}`, `%PlanResize{}` (with pending orientation), and `%PlanPadding{}`/`%PlanPixelate{}`/`%PlanGradient{}`/`%PlanTrim{}` (with pending orientation).
  - `flush_if_pending(state :: %State{}) :: {:ok, %State{}} | {:error, term()}`
- Consumes: `Lowering` (build executables to compensate), `ResizePlanning` (`cover_resize_and_crop_display_frame/3`, `cover_resize?/2`), `Transform.Orientation`, `Transform.PendingOrientation`, `Transform.Materializer`, `Transform.Chain`, `Transform.Focus`, `Transform.State`, `Transform.Operation.Crop`/`Resize`. Also needs a way to translate executables and run them — it calls `Lowering.executable_operations/3` then `Chain.execute/3`.

Note on the seam: `OrientationScheduler` needs the same "translate to executables then run" step `PlanExecutor.run_executable/4` does. Move `run_executable/4` into `OrientationScheduler` as a private helper (it's only used by orientation-aware paths after this task) **or** keep a shared private form. Simplest: `OrientationScheduler` has its own private `run_executable/4` calling `Lowering.executable_operations/3 |> Chain.execute/3`; `PlanExecutor` keeps its own for the plain-op path. Duplication is a 3-line function; acceptable, or extract later — do not add a module just for it.

- [ ] **Step 1: Create the module and move the orientation functions verbatim**

Create `lib/image_pipe/transform/orientation_scheduler.ex` (`@moduledoc false`). Move **verbatim** from `plan_executor.ex`:

- The orientation-aware `execute_operation/4` clauses: `%PlanRotate{... mirror: false}` right-angle fold + arbitrary-angle fallthrough (185–196), `%PlanFlip{}` (198–201), `%SetFocus{}` (208–216), `%CropRegion{}` (225–229), `%CropGuided{}` (231–235), `%PlanResize{}` with `not is_nil(po)` (248–286), `%PlanPadding{}`/`%PlanPixelate{}`/`%PlanGradient{}` with `not is_nil(po)` (299–333), `%PlanTrim{}` with `not is_nil(po)` (344–359).
- `flush_if_pending/1` (167–181)
- `do_execute_crop/4` (all clauses, 380–438)
- `clear_source_frame/1` (371–372)
- `orient_decode_shrink/2` (444–448)
- `materializing_gravity?/1` (450–453)
- `compensate_crop/2` (all clauses, 469–526)
- `split_offset/1` (531–535)
- `compensate_resize/2` (547–558)

Update the moved clauses' internal calls: `executable_operations(...)` → `Lowering.executable_operations(...)`; `cover_resize?(...)` → `ResizePlanning.cover_resize?(...)`; `cover_resize_and_crop_display_frame(operation, state)` → `ResizePlanning.cover_resize_and_crop_display_frame(operation, state, Lowering.tagged_executable_gravity(operation.guide))`; `run_executable(...)` → the module-local `run_executable/4` (add it: `operation |> Lowering.executable_operations(state, context) |> then(&Chain.execute(state, &1, opts))`); `display_live_dims(state)` → `ResizePlanning.display_live_dims(state)`.

Add aliases: `alias ImagePipe.Transform.{Lowering, ResizePlanning, Orientation, PendingOrientation, Materializer, Chain, Focus, State}`, `alias ImagePipe.Transform.Operation.{Crop, Resize}`, `alias ImagePipe.Plan.Operation.{Rotate, as: PlanRotate, ...}` (Rotate/Flip/Resize/Padding/Pixelate/Gradient/Trim as `Plan*`, plus `SetFocus`, `CropRegion`, `CropGuided`), `alias Vix.Vips.Image, as: VipsImage` (for `SetFocus`'s `display_live_dims`/storage read — note the storage tuple `{VipsImage.width(...), VipsImage.height(...)}` in the `SetFocus` clause).

- [ ] **Step 2: Rewire `plan_executor.ex` dispatch**

In `plan_executor.ex`, `execute_operation/4` becomes a thin dispatcher. The orientation-aware operations delegate; everything else uses the local plain-path `run_executable/4`:

```elixir
defp execute_operation(%PlanRotate{} = op, state, ctx, opts), do: OrientationScheduler.execute_operation(op, state, ctx, opts)
defp execute_operation(%PlanFlip{} = op, state, ctx, opts), do: OrientationScheduler.execute_operation(op, state, ctx, opts)
defp execute_operation(%SetFocus{} = op, state, ctx, opts), do: OrientationScheduler.execute_operation(op, state, ctx, opts)
defp execute_operation(%CropRegion{} = op, state, ctx, opts), do: OrientationScheduler.execute_operation(op, state, ctx, opts)
defp execute_operation(%CropGuided{} = op, state, ctx, opts), do: OrientationScheduler.execute_operation(op, state, ctx, opts)

# Resize / padding / pixelate / gradient / trim: orientation-aware only when a
# pending orientation exists; otherwise the plain path.
defp execute_operation(%PlanResize{} = op, %State{pending_orientation: po} = state, ctx, opts) when not is_nil(po),
  do: OrientationScheduler.execute_operation(op, state, ctx, opts)
defp execute_operation(%PlanPadding{} = op, %State{pending_orientation: po} = state, ctx, opts) when not is_nil(po),
  do: OrientationScheduler.execute_operation(op, state, ctx, opts)
defp execute_operation(%PlanPixelate{} = op, %State{pending_orientation: po} = state, ctx, opts) when not is_nil(po),
  do: OrientationScheduler.execute_operation(op, state, ctx, opts)
defp execute_operation(%PlanGradient{} = op, %State{pending_orientation: po} = state, ctx, opts) when not is_nil(po),
  do: OrientationScheduler.execute_operation(op, state, ctx, opts)
defp execute_operation(%PlanTrim{} = op, %State{pending_orientation: po} = state, ctx, opts) when not is_nil(po),
  do: OrientationScheduler.execute_operation(op, state, ctx, opts)

# Fallthrough: plain operation, no pending-orientation handling.
defp execute_operation(operation, %State{} = state, context, opts),
  do: run_executable(operation, state, context, opts)
```

Clause ordering matters: the pending-orientation resize/padding/pixelate/gradient/trim clauses must precede the fallthrough (they are guarded by `not is_nil(po)`, so a nil-po resize falls through to the plain path — identical to today, where the `not is_nil(po)` clause failed to match and dispatch fell to the generic `run_executable`). The arbitrary-angle `%PlanRotate{}` (mirror/non-right-angle) is handled inside `OrientationScheduler.execute_operation` (it owns both rotate clauses).

Update `execute_pipeline/3`'s boundary flush call `flush_if_pending(state)` → `OrientationScheduler.flush_if_pending(state)`. Add `alias ImagePipe.Transform.OrientationScheduler`. Keep `PlanExecutor`'s own private `run_executable/4` (plain path). Remove the moved functions and now-unused aliases from `plan_executor.ex`.

- [ ] **Step 3: Run the TARGETED GATE** (Task 1 Step 3 commands). Expected: all PASS. The `deferred_orientation_test.exs`, `deferred_orientation_frame_test.exs`, `focus_test.exs`, `orientation_flush_test.exs`, and wire-conformance orientation cases are the sharp edge here — if any fail, a clause moved incorrectly or the dispatch ordering is wrong. Fix the move, not the test.

- [ ] **Step 4: Commit**

```bash
git add lib/image_pipe/transform/orientation_scheduler.ex lib/image_pipe/transform/plan_executor.ex
git commit -m "refactor(transform): extract OrientationScheduler from PlanExecutor (#433)"
```

---

### Task 4: Final slim-down verification, boundary check, full gate

**Files:**
- Modify: `lib/image_pipe/transform/plan_executor.ex` (docstring/comment cleanup only)

**Interfaces:** none new.

- [ ] **Step 1: Confirm `PlanExecutor` is now orchestration + dispatch + preamble only**

`plan_executor.ex` should now contain only: `execute/3`, `seed_color_management/2`, `run_color_management/2`, `exif_orientation/1`, `execute_pipelines/3`, `execute_pipeline/3`, `execute_operation/4` (dispatch), `run_executable/4` (plain path), and `update_execution_context/3` (delegating to `ResizePlanning`). Verify the file is roughly ≤ 260 lines: `wc -l lib/image_pipe/transform/plan_executor.ex`. Trim the top-of-file deferred-orientation comment block (lines 4–11) so it references `OrientationScheduler` as the new owner of the scheduling detail rather than describing it as in-module — a one-line pointer, not a relocated essay. Do not leave a stray "moved to …" note in place of removed functions (per `AGENTS.md` clean-removal rule).

- [ ] **Step 2: Boundary / acyclicity check**

```
mise exec -- mix compile --warnings-as-errors
mise exec -- mix xref graph --label compile-connected --fail-above 0 2>/dev/null || true
```
Then confirm no cross-module cycle among the four: `grep -n "ResizePlanning" lib/image_pipe/transform/resize_planning.ex` (self only), `grep -n "Lowering\|OrientationScheduler" lib/image_pipe/transform/resize_planning.ex` (must be empty — ResizePlanning is the leaf), `grep -n "OrientationScheduler" lib/image_pipe/transform/lowering.ex` (must be empty — Lowering does not depend on the scheduler). The architecture-boundary test already asserts the request/source/response-can't-name-transform-ops rules; it must be green.

- [ ] **Step 3: Run the FULL GATE**

```
mise run precommit
```
Expected: `mix format --check-formatted`, `mix compile --warnings-as-errors`, `mix credo --strict`, and the complete `mix test` (including the imgproxy differential lane) all PASS. This is the definitive no-behavior-change proof. If format flags the new files, run `mise exec -- mix format` and re-commit.

- [ ] **Step 4: Commit**

```bash
git add lib/image_pipe/transform/plan_executor.ex
git commit -m "refactor(transform): slim PlanExecutor to orchestration + dispatch (#433)"
```

---

## Self-Review (completed)

- **Spec coverage:** All four modules from the spec are produced (PlanExecutor slim, Lowering, ResizePlanning, OrientationScheduler); the color/EXIF preamble stays inline in PlanExecutor (4-module decision); the spec's "open detail" is settled (gravity threaded, no leaf module); no `Boundary` export changes; acyclic edges verified in Task 4.
- **No new tests / no test changes:** enforced as a global constraint and a stop-signal in the test rhythm section; grep confirmed tests only call `PlanExecutor.execute/3`.
- **Type/name consistency:** `lower/4` (gravity param), `cover_resize_and_crop_display_frame/3` (gravity param), `fit_resize_and_result_crop/4` (gravity param), `flush_if_pending/1`, `execute_operation/4`, `executable_operations/3`, `tagged_executable_gravity/1`, `display_source_dims/1`, `display_live_dims/1` used consistently across tasks.
- **Line ranges** are as-of-plan-authoring anchors; the implementer should match by function name/head, not blindly by line number (earlier tasks shift later ranges).
