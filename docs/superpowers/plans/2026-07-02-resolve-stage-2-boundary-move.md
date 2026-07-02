# Resolve Stage 2 + 2b: Boundary Move & Plan De-dialecting — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Move the imgproxy resolution column behind the `ImagePipe.Resolver` boundary as a Plan-carried strategy (closes #434), then de-dialect the Plan surface: `SetFocus` → generic `Directive`, `State.focus` → neutral `carried_point` (closes #438).

**Architecture:** Per `docs/superpowers/specs/2026-07-01-resolve-stage-virtual-buffer-design.md` §9 Stage 2 (design settled 2026-07-02). `Lowering`/`ResizePlanning` re-signature to `SourceShape` inputs; the `Resolver` callback collapses to `resolve(shape, strategy_state, op) :: {ops, continuation}`; the Plan carries a strategy module (`resolver: module() | nil`); the imgproxy strategy under `parser/imgproxy/` owns `:auto` bucketing, the no-enlarge DPR/padding-scale cap + cross-op carry; the TwicPics strategy owns the `Directive` row. Executable `Resize`/`Crop` math and the focus-to-carry move are **out of scope** (Stage 3/4 per spec §9).

**Tech Stack:** Elixir, Vix/libvips, Boundary, ExUnit (+ existing golden/differential/wire suites).

## Global Constraints

- **Results-identical is the contract**: every task must leave `mise exec -- mix test` green — golden (`test/image_pipe/transform/resolved_plan_golden_test.exs`), imgproxy differential, and wire conformance included. No pixel or byte change anywhere.
- Run everything through `mise exec -- ...` (mise-managed toolchain).
- Two separately-green commit sequences on one branch/PR: Tasks 1–7 = Stage 2 (closes #434), Tasks 8–11 = Stage 2b (closes #438).
- Greenfield: reshape cache-key data in place, **no** key schema version bump (`AGENTS.md` cache guidelines). The `plan_material` gains a `resolver:` entry (intended, changes hashes/ETags — allowed).
- Impossible internal misuse crashes: no guards, no tidy errors, no tests for states no real producer constructs (`AGENTS.md`).
- No telemetry event changes in this plan — if you find yourself adding/renaming an event, stop; that's out of scope (and would trigger the Logger + OTel Capture sync rules).
- No fiddle changes: no parser option surface changes in this plan.
- Comment style: constraints only, no removal narration, no "was previously X" notes (`AGENTS.md`).

## File Structure

| File | Role in this plan |
|---|---|
| `lib/image_pipe/transform/lowering.ex` | Re-signature to `SourceShape`; padding/canvas split out with explicit scale |
| `lib/image_pipe/transform/resize_planning.ex` | Re-signature to `SourceShape`; loses the imgproxy decision column in Task 4 |
| `lib/image_pipe/transform/neutral_resolver.ex` | Shape-based lowering calls; public `display_frame_advance/2` + `plain_advance/2`; loses `:auto`/`:effective` handling and (2b) the `SetFocus` row |
| `lib/image_pipe/transform/resolve_driver.ex` | Loses the `ctx` channel; `env` retired in Task 5 |
| `lib/image_pipe/transform/source_shape.ex` | Gains public `live_dims/1` |
| `lib/image_pipe/resolver.ex` | `behavior_version/0`; callback collapse to `resolve/3` |
| `lib/image_pipe/plan.ex` | `resolver: module() \| nil` field + shape validation |
| `lib/image_pipe/transform/plan_executor.ex` | Strategy selection from the Plan |
| `lib/image_pipe/cache/key.ex` | `resolver:` entry in `plan_material` |
| `lib/image_pipe/parser/imgproxy/resolver.ex` | **Create**: the imgproxy strategy |
| `lib/image_pipe/parser/imgproxy/plan_builder.ex` | Sets `resolver:` on the Plan |
| `lib/image_pipe/parser/twic_pics/resolver.ex` | **Create** (2b): the TwicPics strategy |
| `lib/image_pipe/parser/twic_pics/plan_builder.ex` | (2b) Sets `resolver:`; emits `Directive` |
| `lib/image_pipe/plan/operation/directive.ex` | **Create** (2b); `set_focus.ex` deleted |
| `lib/image_pipe/plan/operation.ex`, `lib/image_pipe/plan/key_data.ex` | (2b) `Directive` constructor + generic key data |
| `lib/image_pipe/transform/state.ex`, `lib/image_pipe/transform/focus.ex` | (2b) `focus` → `carried_point`, neutral docs |
| `lib/image_pipe/parser.ex`, `lib/image_pipe/transform.ex` | Boundary deps/exports |
| `docs/imgproxy_support_matrix.md`, `docs/twicpics_support_matrix.md`, `AGENTS.md` | Doc sync |

---

## Stage 2 — the boundary move (Tasks 1–7; closes #434)

### Task 1: Re-signature `Lowering`/`ResizePlanning` to `SourceShape` inputs

The resolver stops reading `env.state`; every lowering input comes off the threaded shape. `env` narrows to `%{ctx: ctx}` (the DprScale pair — retired in Task 4).

**Files:**
- Modify: `lib/image_pipe/transform/source_shape.ex`
- Modify: `lib/image_pipe/transform/resize_planning.ex`
- Modify: `lib/image_pipe/transform/lowering.ex`
- Modify: `lib/image_pipe/transform/neutral_resolver.ex`
- Modify: `lib/image_pipe/transform/resolve_driver.ex`
- Test: `test/image_pipe/transform/source_shape_test.exs` (new `live_dims/1` cases); existing suites pin the rest

**Interfaces:**
- Produces: `SourceShape.live_dims(shape) :: {pos_integer(), pos_integer()}`;
  `ResizePlanning.lower(op, shape, gravity)`, `ResizePlanning.resize_padding_scale(op, shape, mode)`, `ResizePlanning.display_source_dims(shape)`, `ResizePlanning.cover_resize?(op, shape)`, `ResizePlanning.cover_resize_and_crop_display_frame(op, shape, gravity)`;
  `Lowering.executable_operations(op, shape)` (2-arity), `Lowering.padding_executables(op, scale)`, `Lowering.canvas_executables(op, scale)`.
- Consumed by: Tasks 3–5, 8.

- [ ] **Step 1: Failing test — `SourceShape.live_dims/1`**

Add to `test/image_pipe/transform/source_shape_test.exs`:

```elixir
describe "live_dims/1" do
  test "returns the shape dims when no shrink is outstanding" do
    shape = ImagePipe.Transform.SourceShape.seed(%{width: 800, height: 600, pending_orientation: nil, decode_shrink: nil})
    assert ImagePipe.Transform.SourceShape.live_dims(shape) == {800, 600}
  end

  test "round-trips the decoded extent through the realized shrink factor" do
    # original 1000x750 decoded at shrink 4.0 -> live 250x188 (factor = original / decoded)
    shape =
      ImagePipe.Transform.SourceShape.seed(%{
        width: 1000,
        height: 750,
        pending_orientation: nil,
        decode_shrink: %{w: 1000 / 250, h: 750 / 188}
      })

    assert ImagePipe.Transform.SourceShape.live_dims(shape) == {250, 188}
  end
end
```

- [ ] **Step 2: Run to verify it fails**

Run: `mise exec -- mix test test/image_pipe/transform/source_shape_test.exs`
Expected: FAIL — `live_dims/1` undefined.

- [ ] **Step 3: Move `live_dims` onto `SourceShape` (public)**

In `source_shape.ex`, add (body verbatim from `NeutralResolver.live_dims/1`, including its comment):

```elixir
# The live (decoded) image dims implied by the shape: the effective source
# dims divided by the realized shrink-on-load factor (exact — the factor is
# original ÷ decoded, so the division round-trips the decoded extent).
@spec live_dims(t()) :: {pos_integer(), pos_integer()}
def live_dims(%__MODULE__{width: w, height: h, decode_shrink: nil}), do: {w, h}

def live_dims(%__MODULE__{width: w, height: h, decode_shrink: %{w: sw, h: sh}}),
  do: {max(1, round(w / sw)), max(1, round(h / sh))}
```

In `neutral_resolver.ex`, delete the private `live_dims/1` and call `SourceShape.live_dims/1` at every former call site.

- [ ] **Step 4: Re-signature `ResizePlanning` to the shape**

In `resize_planning.ex`: replace `alias ImagePipe.Transform.State` with `alias ImagePipe.Transform.SourceShape`; drop the unused `context` param from `lower`; every `%State{} = state` becomes `%SourceShape{} = shape`; every `State.effective_source_dims(state)` becomes `{shape.width, shape.height}` (the driver overlay makes these value-equal today — the shape is authoritative). New public heads:

```elixir
@spec lower(PlanResize.t(), SourceShape.t(), term()) :: [struct()]
def lower(%PlanResize{mode: :fit} = operation, %SourceShape{} = shape, gravity) do
  fit_resize_and_result_crop(resize_from(operation, :fit), operation, shape, gravity)
end

def lower(%PlanResize{mode: :cover} = operation, %SourceShape{} = shape, gravity) do
  operation
  |> resize_from(:cover)
  |> cover_resize_and_crop(shape, gravity, {operation.x_offset, operation.y_offset})
end

def lower(%PlanResize{mode: :stretch} = operation, %SourceShape{}, _gravity) do
  [resize_from(operation, :stretch)]
end

def lower(%PlanResize{mode: :auto} = operation, %SourceShape{} = shape, gravity) do
  branch = plan_resize_branch(operation, shape)
  resize = resize_from(operation, branch)
  tagged_executable_resize_operations(branch, resize, operation, shape, gravity)
end
```

`cover_resize_and_crop/4`, `fit_resize_and_result_crop/4`, `cover_resize?/2`, `cover_resize_and_crop_display_frame/3`, `resize_padding_scale/3`, `max_padding_scale_without_enlarge/2`, `plan_resize_branch/2` all take the shape; their bodies are unchanged except `{src_w, src_h} = {shape.width, shape.height}`. `display_source_dims/1` becomes:

```elixir
# The source dims in the DISPLAY frame: the storage-frame effective source dims,
# with the axes swapped when a quarter turn is pending (the display width axis is
# the storage height axis, and vice versa). Used where imgproxy resolves against
# ExtractGeometry-swapped source dims — the ResizeAuto fill-vs-fit classification
# and the no-enlarge padding-scale cap.
@spec display_source_dims(SourceShape.t()) :: {number(), number()}
def display_source_dims(%SourceShape{pending_orientation: po} = shape) do
  if not is_nil(po) and PendingOrientation.quarter_turn?(po),
    do: {shape.height, shape.width},
    else: {shape.width, shape.height}
end
```

Delete `display_live_dims/1` (its one consumer, the `SetFocus` row, goes shape-based in Step 6) and the now-unused `Vix.Vips.Image` alias.

- [ ] **Step 5: Re-signature `Lowering`; split padding/canvas**

In `lowering.ex`: `alias ImagePipe.Transform.SourceShape` (drop `State`). New heads (bodies unchanged except the named substitutions):

```elixir
@spec executable_operations(struct(), SourceShape.t()) :: [struct()]
def executable_operations(%PlanResize{} = operation, %SourceShape{} = shape) do
  ResizePlanning.lower(operation, shape, tagged_executable_gravity(operation.guide))
end

def executable_operations(%CropGuided{} = operation, %SourceShape{} = shape) do
  # ...crop struct construction unchanged...
  [rescale_crop_for_decode_shrink(crop, shape.decode_shrink)]
end

def executable_operations(%CropRegion{} = operation, %SourceShape{} = shape) do
  # ...crop struct construction unchanged, with:
  #   reject_out_of_bounds: reject_region_out_of_bounds?(operation, shape)
  [rescale_crop_for_decode_shrink(crop, shape.decode_shrink)]
end
```

`reject_region_out_of_bounds?/2` reads `{src_w, src_h} = {shape.width, shape.height}`. Every effect/trim/rotate clause swaps `%State{}` → `%SourceShape{}` and drops `_context` — all of: `PlanBackground`, `PlanBlur`, `PlanSharpen`, `PlanPixelate`, `PlanMonochrome`, `PlanDuotone`, `PlanBrightness`, `PlanContrast`, `PlanBitonal`, `PlanGray`, `PlanRotate`, `PlanSaturation`, `PlanColorize`, `PlanGradient`, `PlanTrim`.

Delete the `%Canvas{}` and `%PlanPadding{}` `executable_operations` clauses and the `effective_padding_scale/3` helper (policy moves to `NeutralResolver`, Step 6). Add in their place:

```elixir
# Pure translation given an already-decided composition scale; the scale
# POLICY (literal ratio vs the resize-carried effective scale) belongs to the
# resolver/strategy that decided it.
@spec padding_executables(PlanPadding.t(), number()) :: [struct()]
def padding_executables(%PlanPadding{} = operation, scale) when is_number(scale) do
  [
    %Padding{
      top: scaled_padding_side(operation.top, scale),
      right: scaled_padding_side(operation.right, scale),
      bottom: scaled_padding_side(operation.bottom, scale),
      left: scaled_padding_side(operation.left, scale),
      fill: executable_fill(operation.fill)
    }
  ]
end

@spec canvas_executables(Canvas.t(), number()) :: [struct()]
def canvas_executables(%Canvas{} = operation, scale) when is_number(scale) do
  # (keep the existing imgproxy dpr-scaling comment block from the old clause)
  width = operation.width |> canvas_dimension() |> scale_canvas_dimension(scale)
  height = operation.height |> canvas_dimension() |> scale_canvas_dimension(scale)

  [
    %ExtendCanvas{
      rule: canvas_rule(width, height),
      gravity: tagged_executable_gravity(operation.placement),
      x_offset: scale_extend_offset(operation.x_offset, scale),
      y_offset: scale_extend_offset(operation.y_offset, scale),
      background: executable_fill(operation.fill)
    }
  ]
end
```

- [ ] **Step 6: Update `NeutralResolver` to shape-based lowering**

In `neutral_resolver.ex`, `env.state` disappears entirely:

1. Every `Lowering.executable_operations(operation, env.state, env.ctx)` → `Lowering.executable_operations(operation, shape)`.
2. `CropRegion` pending row — the `lowering_state` rebuild becomes a shape rebuild:

```elixir
{pf_w, pf_h} = post_flush_effective_dims(shape, po)

lowering_shape = %SourceShape{
  shape
  | width: pf_w,
    height: pf_h,
    frame: :display,
    pending_orientation: nil,
    decode_shrink: orient_decode_shrink(shape.decode_shrink, po)
}

[crop] = ops = Lowering.executable_operations(operation, lowering_shape)
```

3. `CropGuided` compensated row: `lowering_shape = %SourceShape{shape | decode_shrink: orient_decode_shrink(shape.decode_shrink, po)}`.
4. `SetFocus` row goes shape-derived (the Stage-1 live-image read dies; `live_dims/1` reconstructs the decoded frame exactly — spec §4.4):

```elixir
defp do_resolve(%SetFocus{point: operand}, %SourceShape{} = shape, _env) do
  {live_w, live_h} = SourceShape.live_dims(shape)

  display =
    case shape.pending_orientation do
      nil -> {live_w, live_h}
      po -> swap_if_quarter_turn({live_w, live_h}, po)
    end

  focus_ctx = %{display: display, storage: {live_w, live_h}, decode_shrink: shape.decode_shrink}
  resolved = Focus.resolve(operand, focus_ctx, shape.pending_orientation)
  {[%StateUpdate{fields: %{focus: resolved}}], advance(shape)}
end
```

Drop the now-unused `Vix.Vips.Image` and `State` aliases.

5. Padding/pixelate/gradient row: pixelate/gradient lower via `Lowering.executable_operations(operation, shape)`; padding via the split helper with the scale policy relocated here from `Lowering`:

```elixir
defp do_resolve(%PlanPadding{} = operation, %SourceShape{} = shape, env),
  do: resolve_display_frame_op(Lowering.padding_executables(operation, padding_scale(operation, env.ctx)), shape)

defp do_resolve(%PlanPixelate{} = operation, %SourceShape{} = shape, _env),
  do: resolve_display_frame_op(Lowering.executable_operations(operation, shape), shape)

defp do_resolve(%PlanGradient{} = operation, %SourceShape{} = shape, _env),
  do: resolve_display_frame_op(Lowering.executable_operations(operation, shape), shape)

# The composition-scale policy for a padding op (imgproxy pd:/dpr coupling):
# an :effective pixel_ratio reads the scale the resize row stashed on the
# per-pipeline context; a literal ratio is its own scale.
defp padding_scale(%PlanPadding{pixel_ratio: {:effective, _fb, :resize}}, %{effective_padding_scale: s}) when is_number(s), do: s
defp padding_scale(%PlanPadding{pixel_ratio: {:effective, _fb, :canvas_preserving}}, %{canvas_preserving_padding_scale: s}) when is_number(s), do: s
defp padding_scale(%PlanPadding{pixel_ratio: {:ratio, n, d}}, _ctx), do: n / d
defp padding_scale(%PlanPadding{pixel_ratio: {:effective, {:ratio, n, d}, _mode}}, _ctx), do: n / d
```

`resolve_display_frame_op/2` now takes the pre-lowered ops (first param) instead of the plan op + env; its body is otherwise unchanged.

6. Add an explicit `Canvas` clause before the catch-all (the catch-all no longer handles it since `Lowering` lost the clause):

```elixir
defp do_resolve(%Canvas{} = operation, %SourceShape{} = shape, env) do
  ops = Lowering.canvas_executables(operation, env.ctx.canvas_preserving_padding_scale || 1.0)
  {ops, advance(plain_ops_advance(ops, shape))}
end
```

(alias `ImagePipe.Plan.Operation.Canvas`.)

7. `pending_resize_ops/3` takes the shape instead of env: `ResizePlanning.cover_resize?(operation, shape)`, `ResizePlanning.cover_resize_and_crop_display_frame(operation, shape, …)`, `Lowering.executable_operations(operation, shape)` — pass `shape` from the callers.

- [ ] **Step 7: Driver — build `env` without `state`; ctx from the shape**

In `resolve_driver.ex`:

```elixir
      {ops, continuation, spec} =
        Resolver.resolve(spec, shape, %{ctx: ctx}, operation)
```

and `update_execution_context` computes from the shape (value-equal to the overlaid state):

```elixir
  defp update_execution_context(%PlanResize{} = operation, %SourceShape{} = shape, context) do
    scale = ResizePlanning.resize_padding_scale(operation, shape, :resize)

    canvas_preserving_scale =
      ResizePlanning.resize_padding_scale(operation, shape, :canvas_preserving)

    %{
      context
      | effective_padding_scale: scale,
        canvas_preserving_padding_scale: canvas_preserving_scale
    }
  end

  defp update_execution_context(_operation, %SourceShape{}, context), do: context
```

Call it with `shape` in the reduce. The `overlay/2` remains untouched — it now exists **solely** to feed the executables' execute-time `State` reads; update its comment to say exactly that.

- [ ] **Step 8: Full verification**

Run: `mise exec -- mix compile --warnings-as-errors && mise exec -- mix test`
Expected: PASS (results-identical; the golden/differential/wire suites are the gate).

- [ ] **Step 9: Commit**

```bash
git add -A
git commit -m "refactor: re-signature Lowering/ResizePlanning to SourceShape inputs (resolve Stage 2, #434)"
```

---

### Task 2: `behavior_version/0`, `Plan.resolver`, strategy selection, `plan_material` tag

**Files:**
- Modify: `lib/image_pipe/resolver.ex`
- Modify: `lib/image_pipe/transform/neutral_resolver.ex`
- Modify: `lib/image_pipe/plan.ex`
- Modify: `lib/image_pipe/transform/plan_executor.ex`
- Modify: `lib/image_pipe/cache/key.ex`
- Test: `test/image_pipe/plan_test.exs`, `test/image_pipe/cache/key_test.exs`

**Interfaces:**
- Produces: `ImagePipe.Resolver.behavior_version/0` callback; `%Plan{resolver: module() | nil}` (default `nil`); `Key.plan_material` gains `resolver: [strategy: module() | :neutral, version: pos_integer()]`.
- Consumed by: Tasks 4, 8 (parsers set `resolver:`), Task 6 (architecture test).

- [ ] **Step 1: Failing tests**

`test/image_pipe/plan_test.exs` — add:

```elixir
test "validate_shape rejects a non-module resolver" do
  plan = %{valid_plan() | resolver: "imgproxy"}
  assert {:error, {:invalid_resolver_plan, "imgproxy"}} = ImagePipe.Plan.validate_shape(plan)
end

test "validate_shape accepts a nil and a module resolver" do
  assert {:ok, _} = ImagePipe.Plan.validate_shape(valid_plan())
  assert {:ok, _} = ImagePipe.Plan.validate_shape(%{valid_plan() | resolver: ImagePipe.Transform.NeutralResolver})
end
```

(reuse the file's existing valid-plan fixture helper; if it has a different name, use that one.)

`test/image_pipe/cache/key_test.exs` — add:

```elixir
describe "plan_material resolver tag" do
  test "a nil-resolver plan tags the neutral strategy" do
    {:ok, material} = ImagePipe.Cache.Key.plan_material(plan_fixture(), [])

    assert material[:resolver] == [
             strategy: :neutral,
             version: ImagePipe.Transform.NeutralResolver.behavior_version()
           ]
  end

  test "a strategy-carrying plan tags the module and its behavioral version" do
    plan = %{plan_fixture() | resolver: ImagePipe.Transform.NeutralResolver}
    {:ok, material} = ImagePipe.Cache.Key.plan_material(plan, [])

    assert material[:resolver] == [
             strategy: ImagePipe.Transform.NeutralResolver,
             version: ImagePipe.Transform.NeutralResolver.behavior_version()
           ]
  end
end
```

(the first test doubles as the drift test pinning `Key`'s hardcoded neutral version to `NeutralResolver.behavior_version/0`; adapt the plan-fixture helper name to the file's existing one.)

- [ ] **Step 2: Run to verify failure**

Run: `mise exec -- mix test test/image_pipe/plan_test.exs test/image_pipe/cache/key_test.exs`
Expected: FAIL — no `resolver` key / no `behavior_version/0`.

- [ ] **Step 3: Implement**

`resolver.ex` — add to the behaviour:

```elixir
@doc """
Behavioral version of this strategy's resolution algorithms. Enters
`ImagePipe.Cache.Key.plan_material/2` (hence the ETag material): bump it when
any resolution rule this strategy owns changes algorithm, so stale-but-
differently-resolved bytes cannot be revalidated through a stable ETag
(spec §7). Orthogonal to the key schema version.
"""
@callback behavior_version() :: pos_integer()
```

`neutral_resolver.ex`:

```elixir
@impl ImagePipe.Resolver
def behavior_version, do: 1
```

`plan.ex` — struct field `resolver: nil`, typespec `resolver: module() | nil`, error type `| {:invalid_resolver_plan, term()}`, and in `validate_shape/1`'s `with`:

```elixir
:ok <- validate_resolver(plan.resolver),
```

```elixir
# The geometry-resolution strategy carried by the plan (spec §4.2): a module
# implementing ImagePipe.Resolver, selected by the parser; nil = the neutral
# resolver. Parsers are host-implementable, so the shape is validated like
# render:.
defp validate_resolver(nil), do: :ok
defp validate_resolver(module) when is_atom(module), do: :ok
defp validate_resolver(other), do: {:error, {:invalid_resolver_plan, other}}
```

`plan_executor.ex` — select the strategy per pipeline (per-pipeline `init/0`, spec §4.4):

```elixir
defp execute_pipelines(pipelines, resolver, %State{} = state, opts) do
  Enum.reduce_while(pipelines, {:ok, state}, fn pipeline, {:ok, state} ->
    case execute_pipeline(pipeline, resolver, state, opts) do
      {:ok, %State{} = state} -> {:cont, {:ok, state}}
      {:error, _reason} = error -> {:halt, error}
    end
  end)
end

defp execute_pipeline(%Pipeline{operations: operations}, resolver, %State{} = state, opts) do
  # ...shape seeding unchanged...
  ResolveDriver.run(operations, shape, {resolver, resolver.init()}, state, opts)
end
```

with `execute/3` passing `plan.resolver || NeutralResolver` (destructure `resolver` from the `%Plan{}` match).

`cache/key.ex` — in `plan_material/2`, after `transform:`:

```elixir
resolver: resolver_data(plan.resolver),
```

```elixir
# The carried strategy's behavioral version (spec §7). The neutral default's
# version is pinned here because cache does not depend on transform; the
# key_test drift assertion ties it to NeutralResolver.behavior_version/0.
defp resolver_data(nil), do: [strategy: :neutral, version: 1]
defp resolver_data(module), do: [strategy: module, version: module.behavior_version()]
```

- [ ] **Step 4: Run the new tests, then the key/ETag suites**

Run: `mise exec -- mix test test/image_pipe/plan_test.exs test/image_pipe/cache/key_test.exs test/image_pipe/cache/key_property_test.exs test/image_pipe/request`
Expected: PASS (key hashes change value — no test should pin a literal hash; if one does, it is asserting storage identity and must be updated to the new material, not reverted).

- [ ] **Step 5: Full verification and commit**

Run: `mise exec -- mix compile --warnings-as-errors && mise exec -- mix test`

```bash
git add -A
git commit -m "feat: Plan-carried resolver strategy + behavioral version in plan_material (#434)"
```

---

### Task 3: Boundary prep — exports, parser deps, public advance helpers

**Files:**
- Modify: `lib/image_pipe/transform.ex` (exports)
- Modify: `lib/image_pipe/parser.ex` (deps)
- Modify: `lib/image_pipe/transform/neutral_resolver.ex` (public helpers + `@moduledoc`)
- Modify: `AGENTS.md` (boundary table)

**Interfaces:**
- Produces: `NeutralResolver.display_frame_advance(ops, shape)` and `NeutralResolver.plain_advance(ops, shape)`, both `:: {[struct()], continuation}`; transform exports `SourceShape`, `NeutralResolver`, `Lowering`, `ResizePlanning`, `Focus`, `PendingOrientation`.
- Consumed by: Task 4 (imgproxy strategy), Task 8 (TwicPics strategy).

- [ ] **Step 1: Widen the boundary declarations**

`lib/image_pipe/transform.ex` — add to `exports:`: `SourceShape`, `NeutralResolver`, `Lowering`, `ResizePlanning`, `Focus`, `PendingOrientation`.

`lib/image_pipe/parser.ex` — deps become:

```elixir
    deps: [
      ImagePipe.Config,
      ImagePipe.Format,
      ImagePipe.Plan,
      ImagePipe.Renderer,
      ImagePipe.Resolver,
      ImagePipe.Transform
    ],
```

- [ ] **Step 2: Make the two advance helpers public**

In `neutral_resolver.ex`, `resolve_display_frame_op/2` becomes public `display_frame_advance/2` and gets a doc; add `plain_advance/2`:

```elixir
@doc """
Advance for an op that must decide in the DISPLAY frame (imgproxy order:
after rotateAndFlip): with a non-identity pending the flush fires first, an
identity pending clears without a flush (streaming fast path). Public so a
carried strategy can compose its own lowering (e.g. an effective padding
scale) with the neutral flush policy.
"""
@spec display_frame_advance([struct()], SourceShape.t()) ::
        {[struct()], ImagePipe.Resolver.continuation()}
def display_frame_advance(ops, %SourceShape{} = shape) do
  # body of the former resolve_display_frame_op/2, unchanged
end

@doc """
Plain advance: run in the current frame with any pending intact, never flush;
canvas geometry advances the shape, everything else is dimension-neutral.
"""
@spec plain_advance([struct()], SourceShape.t()) ::
        {[struct()], ImagePipe.Resolver.continuation()}
def plain_advance(ops, %SourceShape{} = shape),
  do: {ops, advance(plain_ops_advance(ops, shape))}
```

Update the internal padding/pixelate/gradient and `Canvas` rows to call them. Update the `@moduledoc` to state the module is the neutral default strategy and the delegation target for carried strategies.

- [ ] **Step 3: AGENTS.md boundary table**

In the *Boundary library guidelines* `deps:` list, change the `parser` line to:

```
  - `parser` → `plan`, `renderer`, `resolver`, `transform` (a dialect's carried
    resolver strategy under `parser/*` implements `ImagePipe.Resolver`, pattern-
    matches `SourceShape`, and emits executable transform ops — the declared
    static edge; the core stays adapter-ignorant, and dynamic dispatch stays
    quarantined in the `Resolver` facade)
```

- [ ] **Step 4: Verify and commit**

Run: `mise exec -- mix compile --warnings-as-errors && mise exec -- mix test test/image_pipe/transform test/image_pipe/architecture_boundary_test.exs`
Expected: PASS.

```bash
git add -A
git commit -m "refactor: export the strategy vocabulary; declare parser -> transform/resolver (#434)"
```

---

### Task 4: The imgproxy strategy — extraction, wiring, ctx retirement

The boundary move itself. The strategy owns the `:auto` bucketing, the no-enlarge DPR/padding-scale computation + carry, and the padding/canvas scale consumption; the driver `ctx` dies; the neutral column narrows (crash-by-omission on `mode: :auto` and `pixel_ratio: {:effective, …}`).

**Files:**
- Create: `lib/image_pipe/parser/imgproxy/resolver.ex`
- Test (create): `test/image_pipe/parser/imgproxy/resolver_test.exs`
- Modify: `lib/image_pipe/parser/imgproxy/plan_builder.ex`
- Modify: `lib/image_pipe/transform/resize_planning.ex` (delete the moved column; make `resize_from/2` public)
- Modify: `lib/image_pipe/transform/neutral_resolver.ex` (drop `:effective` padding clauses)
- Modify: `lib/image_pipe/transform/resolve_driver.ex` (delete ctx)
- Modify: `test/image_pipe/transform/resolved_plan_golden_test.exs` (carry-across-acquire golden)
- Modify: `test/image_pipe/cache/key_test.exs` (imgproxy tag)

**Interfaces:**
- Consumes: Task 1 signatures, Task 3 helpers/exports, Task 2 `resolver:` field.
- Produces: `ImagePipe.Parser.Imgproxy.Resolver` (implements `ImagePipe.Resolver`; `init/0` returns `%{effective_padding_scale: nil, canvas_preserving_padding_scale: nil}`); `ResizePlanning.resize_from/2` public. The Stage-1 `env`/`ctx` channel is gone from the driver (Task 5 removes the parameter).

- [ ] **Step 1: Failing strategy unit tests**

Create `test/image_pipe/parser/imgproxy/resolver_test.exs`:

```elixir
defmodule ImagePipe.Parser.Imgproxy.ResolverTest do
  use ExUnit.Case, async: true

  alias ImagePipe.Parser.Imgproxy.Resolver, as: ImgproxyResolver
  alias ImagePipe.Plan.Operation
  alias ImagePipe.Transform.Operation.Padding
  alias ImagePipe.Transform.Operation.Resize
  alias ImagePipe.Transform.SourceShape

  defp shape(w, h) do
    SourceShape.seed(%{width: w, height: h, pending_orientation: nil, decode_shrink: nil})
  end

  defp resolve(shape, carry, op) do
    ImgproxyResolver.resolve(shape, %{}, carry, op)
  end

  test "auto resize buckets landscape source x landscape target to cover (prepare.go:88-97)" do
    {:ok, op} = Operation.resize(:auto, {:px, 300}, {:px, 200})
    {[%Resize{mode: :fill} | _], _cont, _carry} = resolve(shape(800, 600), ImgproxyResolver.init(), op)
  end

  test "auto resize buckets landscape source x portrait target to fit" do
    {:ok, op} = Operation.resize(:auto, {:px, 200}, {:px, 300})
    {[%Resize{mode: :fit} | _], _cont, _carry} = resolve(shape(800, 600), ImgproxyResolver.init(), op)
  end

  test "a resize stashes the padding scales; a later padding consumes them (#237)" do
    {:ok, resize} = Operation.resize(:fit, {:px, 100}, {:px, 100}, dpr: {:ratio, 2, 1})
    {_ops, _cont, carry} = resolve(shape(800, 600), ImgproxyResolver.init(), resize)

    assert %{effective_padding_scale: scale} = carry
    assert is_number(scale)

    {:ok, padding} =
      Operation.padding({:px, 10}, {:px, 10}, {:px, 10}, {:px, 10},
        pixel_ratio: {:effective, {:ratio, 2, 1}, :resize}
      )

    {[%Padding{top: top} | _], _cont, _carry} = resolve(shape(100, 75), carry, padding)
    assert top == round(10 * scale)
  end

  test "a geometry-less dpr caps the padding scale to 1.0 (#237)" do
    {:ok, resize} = Operation.resize(:fit, :auto, :auto, dpr: {:ratio, 2, 1})
    {_ops, _cont, carry} = resolve(shape(800, 600), ImgproxyResolver.init(), resize)
    assert carry.effective_padding_scale == 1.0
  end
end
```

**Note:** check `ImagePipe.Plan.Operation`'s actual constructor arities/option names for `resize`/`padding` before running (`mise exec -- mix help` is no use here — read `lib/image_pipe/plan/operation.ex`); adjust the fixture calls to the real constructors, keeping the assertions. The expected `top` value must reproduce today's driver-ctx behavior — verify against a Task-1-era run if in doubt.

- [ ] **Step 2: Run to verify failure**

Run: `mise exec -- mix test test/image_pipe/parser/imgproxy/resolver_test.exs`
Expected: FAIL — module doesn't exist.

- [ ] **Step 3: Move the decision column out of `ResizePlanning`**

In `resize_planning.ex`:
- Make `resize_from/2` public with `@spec resize_from(PlanResize.t(), :fit | :cover | :stretch) :: Resize.t()` (mechanical plan→executable translation, including the `down: true` → `:fill_down` mode row — `down` is neutral Plan vocabulary; the imgproxy-only *behavior* lives in the executable's `fill_down` clauses, the shared column per spec §3).
- Delete: the `lower(%PlanResize{mode: :auto}, …)` clause, the `cover_resize?(%PlanResize{mode: :auto}, …)` clause, `plan_resize_branch/2`, `auto_branch/2`, `orientation_diff/2`, `tagged_logical_pixels/1`, `resize_padding_scale/3`, `max_padding_scale_without_enlarge/2`, `compensate_no_enlarge_padding_scale/3`, `clamp_padding_scale/2`, and `display_source_dims/1`. (They reappear inside the strategy, Step 4.) Keep `tagged_dpr_float/1` if still used by `resize_from`; otherwise it moves too.
- Update the `@moduledoc`: this module is now the *neutral* resize expansion (fit/cover/stretch + result-crop mechanics); mode selection and the padding-scale cap live in the imgproxy strategy.

- [ ] **Step 4: Create the strategy**

`lib/image_pipe/parser/imgproxy/resolver.ex`:

```elixir
defmodule ImagePipe.Parser.Imgproxy.Resolver do
  @moduledoc """
  imgproxy geometry-resolution strategy (spec §4.2/§4.4; #434).

  Owns the imgproxy *decision* column and delegates all shared resolution to
  `ImagePipe.Transform.NeutralResolver`:

  - `:auto` fill-vs-fit bucketing by the sign of width−height, square sharing
    the landscape bucket, on the DISPLAY axes (processing/prepare.go:88-97,
    #182) — rewritten to the concrete mode before delegation, so the neutral
    column never sees `:auto`.
  - The no-enlarge DPR/padding-scale cap (#237, imgproxy's unconditional
    `!Enlarge()` `DprScale = min(DPR, min(wshrink, hshrink))` block), computed
    once at the resize and carried as strategy state to later padding/canvas
    ops (compute-once-reuse, prepare.go calcScale → padding.go/extend.go).
  """

  @behaviour ImagePipe.Resolver

  alias ImagePipe.Plan.Operation.Canvas
  alias ImagePipe.Plan.Operation.Padding, as: PlanPadding
  alias ImagePipe.Plan.Operation.Resize, as: PlanResize
  alias ImagePipe.Transform.Lowering
  alias ImagePipe.Transform.NeutralResolver
  alias ImagePipe.Transform.Operation.Resize
  alias ImagePipe.Transform.PendingOrientation
  alias ImagePipe.Transform.ResizePlanning
  alias ImagePipe.Transform.SourceShape

  @impl ImagePipe.Resolver
  def init, do: %{effective_padding_scale: nil, canvas_preserving_padding_scale: nil}

  @impl ImagePipe.Resolver
  def behavior_version, do: 1

  @impl ImagePipe.Resolver
  def resolve(%SourceShape{} = shape, env, carry, %PlanResize{} = operation) do
    branch = resize_branch(operation, shape)

    carry = %{
      effective_padding_scale: padding_scale(operation, shape, branch, :resize),
      canvas_preserving_padding_scale: padding_scale(operation, shape, branch, :canvas_preserving)
    }

    delegate(%PlanResize{operation | mode: branch}, shape, env, carry)
  end

  def resolve(%SourceShape{} = shape, _env, carry, %PlanPadding{} = operation) do
    ops = Lowering.padding_executables(operation, padding_scale_for(operation, carry))
    {ops, continuation} = NeutralResolver.display_frame_advance(ops, shape)
    {ops, rewrap(continuation, carry), carry}
  end

  def resolve(%SourceShape{} = shape, _env, carry, %Canvas{} = operation) do
    ops = Lowering.canvas_executables(operation, carry.canvas_preserving_padding_scale || 1.0)
    {ops, continuation} = NeutralResolver.plain_advance(ops, shape)
    {ops, rewrap(continuation, carry), carry}
  end

  def resolve(%SourceShape{} = shape, env, carry, operation),
    do: delegate(operation, shape, env, carry)

  # ── delegation ────────────────────────────────────────────────────────────
  # The neutral resolver threads nil strategy state; re-wrap the continuation
  # so the imgproxy carry survives the advance (including through :acquire —
  # a trim between resize and padding must not lose the stashed DprScale).
  defp delegate(operation, shape, env, carry) do
    {ops, continuation, nil} = NeutralResolver.resolve(shape, env, nil, operation)
    {ops, rewrap(continuation, carry), carry}
  end

  defp rewrap({:advance, %SourceShape{} = shape, nil}, carry), do: {:advance, shape, carry}

  defp rewrap({:acquire, then_fn}, carry) do
    {:acquire,
     fn dims ->
       {%SourceShape{} = shape, nil} = then_fn.(dims)
       {shape, carry}
     end}
  end

  # ── :auto bucketing (moved from ResizePlanning) ───────────────────────────
  defp resize_branch(%PlanResize{mode: :fit}, %SourceShape{}), do: :fit
  defp resize_branch(%PlanResize{mode: :cover}, %SourceShape{}), do: :cover
  defp resize_branch(%PlanResize{mode: :stretch}, %SourceShape{}), do: :stretch

  defp resize_branch(%PlanResize{mode: :auto} = operation, %SourceShape{} = shape) do
    # imgproxy's ResizeAuto compares srcW−srcH against dstW−dstH on the DISPLAY
    # axes — ExtractGeometry swaps the source dims for a quarter turn before the
    # comparison (prepare.go). Classify against the display-frame source so an
    # EXIF 5–8 / rot:90/270 source is not judged on transposed axes (#182).
    {src_w, src_h} = display_source_dims(shape)

    auto_branch(
      orientation_diff(src_w, src_h),
      orientation_diff(
        tagged_logical_pixels(operation.width),
        tagged_logical_pixels(operation.height)
      )
    )
  end

  # imgproxy buckets fill-vs-fit by the sign of the width−height difference,
  # square (diff == 0) sharing the landscape bucket; cover fills only when both
  # land in the same bucket (processing/prepare.go:88-97). :unknown = an auto
  # (omitted) dimension, which keeps the conservative fit branch.
  defp auto_branch(:unknown, _target_diff), do: :fit
  defp auto_branch(_current_diff, :unknown), do: :fit

  defp auto_branch(current_diff, target_diff)
       when (current_diff >= 0 and target_diff >= 0) or
              (current_diff < 0 and target_diff < 0),
       do: :cover

  defp auto_branch(_current_diff, _target_diff), do: :fit

  defp orientation_diff(width, height) when is_integer(width) and is_integer(height),
    do: width - height

  defp orientation_diff(_width, _height), do: :unknown

  defp tagged_logical_pixels({:px, value}), do: value
  defp tagged_logical_pixels(_dimension), do: :unknown

  # ── no-enlarge padding/DPR scale (moved from ResizePlanning; #237) ────────
  defp padding_scale(%PlanResize{enlargement: :allow} = operation, %SourceShape{}, _branch, _mode),
    do: tagged_dpr_float(operation.dpr)

  defp padding_scale(%PlanResize{} = operation, %SourceShape{} = shape, branch, mode) do
    # imgproxy computes the no-enlarge padding/DPR cap entirely in the display
    # frame (#182): resolve `base` against the display-frame source so the
    # fitted dims match imgproxy's.
    {src_w, src_h} = display_source_dims(shape)
    requested_scale = tagged_dpr_float(operation.dpr)
    resize = ResizePlanning.resize_from(operation, branch)

    base =
      %Resize{resize | dpr: 1.0, enlarge: true}
      |> Resize.resolve_dimensions(source_width: src_w, source_height: src_h)

    max_without_enlarge = max_padding_scale_without_enlarge(base, shape)
    compensated = compensate_no_enlarge_padding_scale(requested_scale, max_without_enlarge, mode)

    min(compensated, max(max_without_enlarge, 1.0))
  end

  # No explicit geometry (auto/auto, no zoom): wshrink=hshrink=1, and imgproxy's
  # `!Enlarge()` block ALWAYS caps, so a geometry-less dpr caps to 1 (#237).
  defp max_padding_scale_without_enlarge(
         %{requested_width: :auto, requested_height: :auto},
         %SourceShape{}
       ),
       do: 1.0

  defp max_padding_scale_without_enlarge(
         %{requested_width: width, requested_height: height},
         %SourceShape{} = shape
       ) do
    {src_w, src_h} = display_source_dims(shape)
    min(src_w / width, src_h / height)
  end

  defp compensate_no_enlarge_padding_scale(requested_scale, _max, :canvas_preserving),
    do: requested_scale

  defp compensate_no_enlarge_padding_scale(requested_scale, max_without_enlarge, :resize)
       when max_without_enlarge < 1.0,
       do: requested_scale / max_without_enlarge

  defp compensate_no_enlarge_padding_scale(requested_scale, _max, _mode), do: requested_scale

  defp tagged_dpr_float({:ratio, numerator, denominator}), do: numerator / denominator

  # ── carry consumption ─────────────────────────────────────────────────────
  defp padding_scale_for(
         %PlanPadding{pixel_ratio: {:effective, _fb, :resize}},
         %{effective_padding_scale: scale}
       )
       when is_number(scale),
       do: scale

  defp padding_scale_for(
         %PlanPadding{pixel_ratio: {:effective, _fb, :canvas_preserving}},
         %{canvas_preserving_padding_scale: scale}
       )
       when is_number(scale),
       do: scale

  defp padding_scale_for(%PlanPadding{pixel_ratio: {:ratio, n, d}}, _carry), do: n / d

  defp padding_scale_for(%PlanPadding{pixel_ratio: {:effective, {:ratio, n, d}, _mode}}, _carry),
    do: n / d

  defp display_source_dims(%SourceShape{pending_orientation: po} = shape) do
    if not is_nil(po) and PendingOrientation.quarter_turn?(po),
      do: {shape.height, shape.width},
      else: {shape.width, shape.height}
  end
end
```

Keep the comment blocks — they carry the imgproxy-source citations the compatibility reviewer checks. If `%PlanResize{}` lacks a field named exactly as used (`enlargement`, `dpr`), mirror whatever the deleted `ResizePlanning` code read.

- [ ] **Step 5: Wire and retire**

1. `plan_builder.ex` (imgproxy, main `to_plan` clause only — the info renderer plan has no pipelines): add `resolver: ImagePipe.Parser.Imgproxy.Resolver` to the `%Plan{}`.
2. `resolve_driver.ex`: delete `@initial_ctx`, `update_execution_context/3`, the `ctx` element of the accumulator, and pass `%{}` as `env`:

```elixir
    pipeline
    |> Enum.reduce_while({:ok, shape, spec, state}, fn operation, acc ->
      {:ok, shape, spec, state} = acc
      state = overlay(state, shape)

      {ops, continuation, spec} = Resolver.resolve(spec, shape, %{}, operation)
      ...
```

(drop the `PlanResize`/`ResizePlanning` aliases.)
3. `neutral_resolver.ex`: delete the two `{:effective, …}` `padding_scale` clauses (imgproxy plans no longer reach the neutral resolver; an `:effective` padding here is impossible internal misuse — crash by no matching clause, no test). Same for the `Canvas` row: replace `env.ctx.canvas_preserving_padding_scale || 1.0` with the literal `1.0` (only non-imgproxy plans reach it; their scale was always 1.0). The neutral `resolve/4` now ignores `env` entirely.
4. `neutral_resolver.ex` moduledoc: note `mode: :auto` is imgproxy-strategy-resolved before delegation and unreachable here.

- [ ] **Step 6: Golden — carry survives an `:acquire`**

In `test/image_pipe/transform/resolved_plan_golden_test.exs`, add a case following the file's existing harness conventions (injected `acquire_dims`): drive `ResolveDriver.run/5` with spec `{ImagePipe.Parser.Imgproxy.Resolver, ImagePipe.Parser.Imgproxy.Resolver.init()}` over the op sequence **resize (with `dpr: {:ratio, 2, 1}`, no-enlarge) → trim → padding (`pixel_ratio: {:effective, {:ratio, 2, 1}, :resize}`)**, injecting dims for the resize and trim `:acquire`s, and assert the emitted `%Padding{}` sides equal the Task-1-era integers (compute them once against the pre-change code or derive from the stashed scale). This is the spec-§8 case proving `rewrap/2` threads the DprScale through an `:acquire` untouched.

- [ ] **Step 7: Key tag test**

In `test/image_pipe/cache/key_test.exs`, extend the resolver-tag describe: build a plan through the imgproxy parser fixture path used elsewhere in the test suite (or set `resolver: ImagePipe.Parser.Imgproxy.Resolver` on the fixture) and assert `material[:resolver] == [strategy: ImagePipe.Parser.Imgproxy.Resolver, version: 1]`.

- [ ] **Step 8: Full verification**

Run: `mise exec -- mix compile --warnings-as-errors && mise exec -- mix test`
Expected: PASS — in particular `test/image_pipe/imgproxy_resize_auto_test.exs`, the imgproxy differential, and wire conformance, which pin the moved column's behavior.

- [ ] **Step 9: Commit**

```bash
git add -A
git commit -m "feat: extract the imgproxy resolution column into a carried strategy (#434)"
```

---

### Task 5: Collapse the Resolver callback to `resolve/3`

`env` is dead (nothing reads it) and the trailing `strategy_state` was always redundant with the continuation.

**Files:**
- Modify: `lib/image_pipe/resolver.ex`
- Modify: `lib/image_pipe/transform/neutral_resolver.ex`
- Modify: `lib/image_pipe/parser/imgproxy/resolver.ex`
- Modify: `lib/image_pipe/transform/resolve_driver.ex`
- Test: `test/image_pipe/resolver_test.exs`, `test/image_pipe/transform/neutral_resolver_test.exs`, `test/image_pipe/parser/imgproxy/resolver_test.exs`

**Interfaces:**
- Produces (the frozen Stage-2 contract, spec §4.2):
  `@callback resolve(SourceShape.t(), strategy_state(), struct()) :: {[struct()], continuation()}`;
  facade `Resolver.resolve(spec, shape, op) :: {[struct()], continuation()}`.

- [ ] **Step 1: Update the behaviour + facade**

`resolver.ex`:

```elixir
@callback resolve(SourceShape.t(), strategy_state(), struct()) ::
            {[struct()], continuation()}

@spec resolve(spec(), shape :: term(), struct()) :: {[struct()], continuation()}
def resolve({module, strategy_state}, shape, op) do
  module.resolve(shape, strategy_state, op)
end
```

(update the `@moduledoc` — `env` no longer exists; the continuation is the only `strategy_state` channel.)

- [ ] **Step 2: Update both resolvers**

`neutral_resolver.ex`: `resolve(shape, nil, operation)`; `do_resolve/3` drops the `env` param → `do_resolve/2`; every clause loses its env argument; the return drops the trailing `nil` (rows already return `{ops, continuation}` pairs from `advance/1`/`{:acquire, then_fn}` — remove the outer 3-tuple wrapper in `resolve`).

`parser/imgproxy/resolver.ex`: heads become `resolve(shape, carry, op)`; `delegate/3` calls `NeutralResolver.resolve(shape, nil, operation)` and returns `{ops, rewrap(continuation, carry)}`; all clauses return 2-tuples.

- [ ] **Step 3: Update the driver**

`resolve_driver.ex`:

```elixir
      {ops, continuation} = Resolver.resolve(spec, shape, operation)

      case chain.(state, ops, opts) do
        {:ok, %State{} = state} ->
          {shape, spec} = advance(continuation, spec, state, acquire_dims)
          {:cont, {:ok, shape, spec, state}}
        ...
```

(`advance/4` is unchanged — it already takes the continuation + spec.)

- [ ] **Step 4: Update the tests**

Mechanically update `resolver_test.exs`, `neutral_resolver_test.exs`, and the strategy test to the 3-arity call and 2-tuple return (`resolve(shape, carry, op)` in the strategy test; drop `%{}` env args).

- [ ] **Step 5: Full verification and commit**

Run: `mise exec -- mix compile --warnings-as-errors && mise exec -- mix test`

```bash
git add -A
git commit -m "refactor: collapse Resolver callback to resolve/3, retire env (#434)"
```

---

### Task 6: Architecture test — strategy reach

**Files:**
- Modify: `test/image_pipe/architecture_boundary_test.exs`

- [ ] **Step 1: Add the scoping test**

Following the file's existing source-scanning conventions (this is the one file allowed to scan source, per AGENTS.md), add: for every `lib/image_pipe/parser/**/resolver.ex` file, assert it references **no** transform module outside the allowed set — `ImagePipe.Transform.SourceShape`, `ImagePipe.Transform.NeutralResolver`, `ImagePipe.Transform.Lowering`, `ImagePipe.Transform.ResizePlanning`, `ImagePipe.Transform.Focus`, `ImagePipe.Transform.PendingOrientation`, `ImagePipe.Transform.Operation.*` — i.e. it must not name `ImagePipe.Transform.Chain`, `ImagePipe.Transform.State`, `ImagePipe.Transform.Materializer`, or `ImagePipe.Transform.DecodePlanner` (strategies resolve geometry; they never touch execution state or pixel access).

- [ ] **Step 2: Verify and commit**

Run: `mise exec -- mix test test/image_pipe/architecture_boundary_test.exs`
Expected: PASS.

```bash
git add -A
git commit -m "test: scope what a carried resolver strategy may reach (#434)"
```

---

### Task 7: Stage-2 docs + full gate

**Files:**
- Modify: `docs/imgproxy_support_matrix.md`
- Modify: `docs/twicpics_support_matrix.md`

- [ ] **Step 1: imgproxy matrix — stage/order axis**

In the processing-pipeline section: resolution decisions (`:auto` bucketing, the no-enlarge DPR/padding-scale cap, `fill_down`) now live in the Plan-carried `ImagePipe.Parser.Imgproxy.Resolver` strategy; shared expansion mechanics (fit/cover/stretch, `cropToResult`, orientation compensation, shrink rescale) stay in the neutral transform column; `fixSize`/`limitScale` remain Output-boundary (spec §4.4/§4.7). No surface rows change; no "Diverges" change.

- [ ] **Step 2: TwicPics matrix — stage/order note**

Note that TwicPics plans resolve through the neutral strategy in Stage 2 (its own strategy arrives with the Directive work, below). No surface/pixel change.

- [ ] **Step 3: Stage-2 gate**

Run: `mise run precommit`
Expected: format, compile --warnings-as-errors, credo --strict, full test suite all green. Fix anything it flags before committing.

- [ ] **Step 4: Commit (Stage 2 complete)**

```bash
git add -A
git commit -m "docs: support-matrix stage/order sync for the resolver strategy move (#434)"
```

---

## Stage 2b — Plan-surface de-dialecting (Tasks 8–11; closes #438)

### Task 8: TwicPics strategy owns the focus row

**Files:**
- Create: `lib/image_pipe/parser/twic_pics/resolver.ex`
- Test (create): `test/image_pipe/parser/twic_pics/resolver_test.exs`
- Modify: `lib/image_pipe/parser/twic_pics/plan_builder.ex`
- Modify: `lib/image_pipe/transform/neutral_resolver.ex`

**Interfaces:**
- Produces: `ImagePipe.Parser.TwicPics.Resolver` (implements `ImagePipe.Resolver`; `init/0` → `nil`, `behavior_version/0` → `1`); owns the `%SetFocus{}` row (this task) / `%Directive{}` row (Task 9). The neutral resolver has **no** focus row afterwards.

- [ ] **Step 1: Failing test**

Create `test/image_pipe/parser/twic_pics/resolver_test.exs`:

```elixir
defmodule ImagePipe.Parser.TwicPics.ResolverTest do
  use ExUnit.Case, async: true

  alias ImagePipe.Parser.TwicPics.Resolver, as: TwicPicsResolver
  alias ImagePipe.Plan.Operation.SetFocus
  alias ImagePipe.Transform.Operation.StateUpdate
  alias ImagePipe.Transform.SourceShape

  test "resolves a focus operand against the shape and commits via StateUpdate" do
    shape = SourceShape.seed(%{width: 800, height: 600, pending_orientation: nil, decode_shrink: nil})
    op = %SetFocus{point: {:coord, {:px, 200}, {:px, 150}}}

    {[%StateUpdate{fields: %{focus: {x, y}}}], {:advance, ^shape, nil}} =
      TwicPicsResolver.resolve(shape, nil, op)

    assert x == {:ratio, 200, 1}
    assert y == {:ratio, 150, 1}
  end

  test "delegates non-focus ops to the neutral resolver" do
    shape = SourceShape.seed(%{width: 800, height: 600, pending_orientation: nil, decode_shrink: nil})
    {:ok, op} = ImagePipe.Plan.Operation.blur(2.0)

    assert TwicPicsResolver.resolve(shape, nil, op) ==
             ImagePipe.Transform.NeutralResolver.resolve(shape, nil, op)
  end
end
```

(check the real `Operation.blur/1` constructor and `SetFocus` operand shapes against `lib/image_pipe/plan/operation.ex`; the `{:ratio, 200, 1}` expectations mirror `Focus.resolve/3` for an unshrunken, unrotated shape.)

- [ ] **Step 2: Run to verify failure**

Run: `mise exec -- mix test test/image_pipe/parser/twic_pics/resolver_test.exs`
Expected: FAIL — module doesn't exist.

- [ ] **Step 3: Create the strategy; move the row**

`lib/image_pipe/parser/twic_pics/resolver.ex`:

```elixir
defmodule ImagePipe.Parser.TwicPics.Resolver do
  @moduledoc """
  TwicPics geometry-resolution strategy (spec §4.4; #438): owns positional
  focus resolution — the operand resolves against the live frame at its chain
  position and commits the carried point through an explicit state update —
  and delegates all other resolution to `ImagePipe.Transform.NeutralResolver`.
  """

  @behaviour ImagePipe.Resolver

  alias ImagePipe.Plan.Operation.SetFocus
  alias ImagePipe.Transform.Focus
  alias ImagePipe.Transform.NeutralResolver
  alias ImagePipe.Transform.Operation.StateUpdate
  alias ImagePipe.Transform.PendingOrientation
  alias ImagePipe.Transform.SourceShape

  @impl ImagePipe.Resolver
  def init, do: nil

  @impl ImagePipe.Resolver
  def behavior_version, do: 1

  @impl ImagePipe.Resolver
  def resolve(%SourceShape{} = shape, nil, %SetFocus{point: operand}) do
    {live_w, live_h} = SourceShape.live_dims(shape)

    display =
      case shape.pending_orientation do
        nil -> {live_w, live_h}
        po -> if PendingOrientation.quarter_turn?(po), do: {live_h, live_w}, else: {live_w, live_h}
      end

    focus_ctx = %{display: display, storage: {live_w, live_h}, decode_shrink: shape.decode_shrink}
    resolved = Focus.resolve(operand, focus_ctx, shape.pending_orientation)
    {[%StateUpdate{fields: %{focus: resolved}}], {:advance, shape, nil}}
  end

  def resolve(%SourceShape{} = shape, nil, operation),
    do: NeutralResolver.resolve(shape, nil, operation)
end
```

Then: delete the `%SetFocus{}` `do_resolve` clause (and the `SetFocus`/`Focus`/`StateUpdate` aliases if now unused) from `neutral_resolver.ex` — a `SetFocus` reaching the neutral resolver is impossible internal misuse (only TwicPics emits it, and TwicPics plans now carry this strategy) — and add `resolver: ImagePipe.Parser.TwicPics.Resolver` to the `%Plan{}` in `parser/twic_pics/plan_builder.ex`.

- [ ] **Step 4: Verify**

Run: `mise exec -- mix test test/image_pipe/parser/twic_pics/resolver_test.exs test/image_pipe/twic_pics_wire_conformance_test.exs test/image_pipe/twicpics_differential_conformance_test.exs test/image_pipe/transform`
Expected: PASS. Then `mise exec -- mix test` — PASS.

- [ ] **Step 5: Commit**

```bash
git add -A
git commit -m "feat: TwicPics resolver strategy owns positional focus resolution (#438)"
```

---

### Task 9: `Directive` replaces `SetFocus`

**Files:**
- Create: `lib/image_pipe/plan/operation/directive.ex`
- Delete: `lib/image_pipe/plan/operation/set_focus.ex`
- Modify: `lib/image_pipe/plan.ex` (exports), `lib/image_pipe/plan/operation.ex`, `lib/image_pipe/plan/key_data.ex`
- Modify: `lib/image_pipe/parser/twic_pics/plan_builder.ex`, `lib/image_pipe/parser/twic_pics/resolver.ex`
- Test: `test/image_pipe/plan/operation_test.exs`, `test/image_pipe/plan/key_data_test.exs` (or `operation_key_data_test.exs` — wherever `set_focus` key data is asserted today), `test/image_pipe/parser/twic_pics/resolver_test.exs`

**Interfaces:**
- Produces: `%ImagePipe.Plan.Operation.Directive{name: atom(), payload: term()}`; `Operation.directive(name, payload) :: {:ok, Directive.t()} | {:error, error()}`; key data `[op: :directive, name: name, payload: payload]`. `SetFocus` no longer exists anywhere.

- [ ] **Step 1: Failing tests**

In `test/image_pipe/plan/operation_test.exs`:

```elixir
test "directive/2 wraps a strategy-addressed pipeline entry" do
  assert {:ok, %ImagePipe.Plan.Operation.Directive{name: :set_focus, payload: {:coord, {:px, 1}, {:px, 2}}}} =
           ImagePipe.Plan.Operation.directive(:set_focus, {:coord, {:px, 1}, {:px, 2}})
end
```

In the key-data test file that currently asserts `op: :set_focus`:

```elixir
test "directive key data hashes name and payload generically" do
  {:ok, op} = ImagePipe.Plan.Operation.directive(:set_focus, {:coord, {:px, 1}, {:px, 2}})
  assert ImagePipe.Plan.KeyData.data(op) ==
           [op: :directive, name: :set_focus, payload: {:coord, {:px, 1}, {:px, 2}}]
end
```

- [ ] **Step 2: Run to verify failure**

Run: `mise exec -- mix test test/image_pipe/plan`
Expected: FAIL — no `Directive`.

- [ ] **Step 3: Implement the op**

`lib/image_pipe/plan/operation/directive.ex`:

```elixir
defmodule ImagePipe.Plan.Operation.Directive do
  @moduledoc """
  A pipeline entry addressed to the plan's carried resolver strategy
  (spec §4.4; #438) — the strategy analogue of the Renderer's
  `{:custom, module, params}`. The `payload` is a parser-produced plain
  canonical term (a parser contract, asserted in parser tests, not validated
  downstream); key data hashes it generically. The neutral resolver has no
  `Directive` clause: a directive reaching a strategy that doesn't own it is
  impossible internal misuse and crashes.
  """

  @enforce_keys [:name, :payload]
  defstruct @enforce_keys

  @type t :: %__MODULE__{name: atom(), payload: term()}
end
```

`operation.ex`: replace the `SetFocus` alias with `Directive`; `@type focus_operation :: Directive.t()` (or rename the type to `directive_operation` and update the union); replace `set_focus/1` with:

```elixir
@spec directive(atom(), term()) :: {:ok, Directive.t()} | {:error, error()}
def directive(name, payload) when is_atom(name) and not is_nil(name),
  do: {:ok, %Directive{name: name, payload: payload}}

def directive(name, _payload), do: invalid(:directive, [name])
```

`semantic?/1`: replace the `SetFocus` clause with `def semantic?(%Directive{name: name}) when is_atom(name), do: true` and delete `valid_set_focus_point?/1` (payload canonicality is the parser's contract). `key_data.ex`: replace the `SetFocus` clause + `set_focus_point_data/1` with:

```elixir
# A directive carries no pixel op itself, but the strategy decision it commits
# (e.g. the focal point the next cover/crop consumes) changes the stored
# bytes — so it contributes to the cache key (and, via the same material, the
# ETag). Hashed generically; payload canonicality is a parser contract.
def data(%Directive{name: name, payload: payload}), do: [op: :directive, name: name, payload: payload]
```

`plan.ex` exports: `Operation.SetFocus` → `Operation.Directive`. Delete `lib/image_pipe/plan/operation/set_focus.ex`.

- [ ] **Step 4: Swap the producers/consumers**

`parser/twic_pics/plan_builder.ex` — both emission sites call the new constructor with the same operand:

```elixir
defp focus_coordinates(args, acc) do
  with {:ok, {x, y}} <- Units.coordinates(args),
       {:ok, op} <- Operation.directive(:set_focus, {:coord, x, y}) do
    {:ok, %{acc | ops: [op | acc.ops], guide: :carried}}
  else
    _ -> {:error, {:unsupported_focus, args}}
  end
end

defp emit_focus(anchor, acc) do
  with {:ok, op} <- Operation.directive(:set_focus, anchor) do
    {:ok, %{acc | ops: [op | acc.ops], guide: :carried}}
  end
end
```

`parser/twic_pics/resolver.ex` — the row matches the directive:

```elixir
def resolve(%SourceShape{} = shape, nil, %Directive{name: :set_focus, payload: operand}) do
```

(alias `ImagePipe.Plan.Operation.Directive`; drop the `SetFocus` alias; update the strategy test's op construction; the `Focus.resolve/3` operand type reference in `focus.ex` — `@spec resolve(SetFocus.operand(), …)` — moves the operand type into `Focus` itself or inlines it, since `SetFocus` is gone: define `@type operand :: {:coord, measure, measure} | {:anchor, …}` locally in `focus.ex` and drop its `SetFocus` alias.)

- [ ] **Step 5: Full verification**

Run: `mise exec -- mix compile --warnings-as-errors && mise exec -- mix test`
Expected: PASS — TwicPics wire + differential prove byte-identical behavior; key data reshapes in place (greenfield, no version bump).

- [ ] **Step 6: Commit**

```bash
git add -A
git commit -m "feat: de-dialect the Plan surface — SetFocus becomes a generic strategy Directive (#438)"
```

---

### Task 10: `State.focus` → neutral `carried_point`

**Files:**
- Modify: `lib/image_pipe/transform/state.ex`, `lib/image_pipe/transform/focus.ex`
- Modify: `lib/image_pipe/transform/operation/crop.ex`, `lib/image_pipe/transform/operation/resize.ex`, `lib/image_pipe/transform/operation/extend_canvas.ex`, `lib/image_pipe/transform/orientation_flush.ex` (only if they pattern-match the field name — they call the `Focus.*` API, so most need no change)
- Modify: `lib/image_pipe/parser/twic_pics/resolver.ex` (StateUpdate field key)
- Test: `test/image_pipe/transform/focus_test.exs`, `test/image_pipe/transform/focus_property_test.exs`

- [ ] **Step 1: Rename the field**

In `state.ex`: `focus:` → `carried_point:` in `defstruct`, the typespec, and the field doc — rewritten neutrally:

```
- `carried_point`: the strategy-supplied carried point `{x, y}` (exact
  rationals, `ImagePipe.Plan.Measure.t()` shape) in the live-image frame,
  transformed by each geometry op via `ImagePipe.Transform.Focus`; `nil`
  defaults to center at a `:carried`-gravity consumer. Product-neutral: any
  carried strategy may supply a point (exactly as `:smart` gravity is neutral);
  today the TwicPics strategy is the one producer, committing it through
  `ImagePipe.Transform.Operation.StateUpdate`. Every `Focus.*` call is a no-op
  when it is `nil`, so point-free plans are unaffected.
```

In `focus.ex`: every `state.focus` read / `%State{focus: …}` match becomes `carried_point`; neutralize the `@moduledoc` (the module is the neutral point-transform math for the carried point; drop the "TwicPics carried focus point" framing — name the TwicPics strategy only as the current producer). In `crop.ex`: update the `:carried` clause docs to "reads the neutral carried point" (the `Focus.to_fp/1` call is unchanged). In `twic_pics/resolver.ex`: `%StateUpdate{fields: %{carried_point: resolved}}`.

- [ ] **Step 2: Grep gate**

Run: `grep -rn "state\.focus\|focus:" lib/image_pipe/transform/state.ex lib/image_pipe/transform/focus.ex lib/image_pipe/parser/twic_pics/`
Expected: no remaining `focus`-named field references (the `Focus` module name itself stays — it's the point-math namespace).

- [ ] **Step 3: Full verification and commit**

Run: `mise exec -- mix compile --warnings-as-errors && mise exec -- mix test`
Expected: PASS.

```bash
git add -A
git commit -m "refactor: neutralize the carried point — State.focus becomes carried_point (#438)"
```

---

### Task 11: Final gates and PR

- [ ] **Step 1: Full gate**

Run: `mise run precommit`
Expected: all green (format, compile --warnings-as-errors, credo --strict, full suite incl. golden + differential + wire).

- [ ] **Step 2: Spec/doc cross-check**

Confirm `docs/imgproxy_support_matrix.md` and `docs/twicpics_support_matrix.md` reflect the landed state (Task 7 + the TwicPics strategy from Tasks 8–9 — update the TwicPics stage/order note to name `ImagePipe.Parser.TwicPics.Resolver`). Tick the Stage-2/2b items in the spec's §9 if the team tracks them there.

- [ ] **Step 3: Branch + PR**

```bash
git branch -m refactor/resolve-stage-2-boundary-move
git push -u origin refactor/resolve-stage-2-boundary-move
```

PR body must contain, each as its own bare line (GitHub parses only this form):

```
Fixes #434
Fixes #438
```

Verify with: `gh pr view --json closingIssuesReferences`. End the body with the standard generated-with footer. Do not clobber any CodeRabbit summary block on later edits.

---

## Self-Review Notes (kept for the plan-review cycle)

- **Spec coverage:** §9 Stage 2 bullets map to: scope record (Global Constraints), `Plan.resolver` (Task 2), callback collapse (Task 5), imgproxy strategy + neutral narrowing (Task 4), `Lowering`/`ResizePlanning` re-signature (Task 1), boundary + architecture test (Tasks 3, 6), keys (Task 2/4), docs (Task 7), carry golden (Task 4). §9 Stage 2b maps to Tasks 8–10. Stage 3/4 items are explicitly out of scope.
- **Known judgment calls for reviewers:** (a) `resize_from/2` keeps the `down → :fill_down` translation in neutral `ResizePlanning` (mechanical plan-vocabulary mapping; the imgproxy-only behavior lives in the executable's shared column) — spec §4.2's "fill_down mapping" ownership is realized as the strategy being the only reachable path to `down: true`; (b) `Key.resolver_data(nil)` pins `[strategy: :neutral, version: 1]` because `cache` does not depend on `transform` — drift-tested against `NeutralResolver.behavior_version/0`; (c) strategy unit-test fixtures must be checked against the real `Plan.Operation` constructor signatures before first run.
- **Compatibility reviewer focus:** Task 4 (the moved `:auto`/`#237` code must stay line-faithful to `prepare.go`/`calc_position.go` citations), Task 1's `CropRegion`/`CropGuided` shape rebuilds (the `#185` swap and `#180` reset must survive verbatim), and the differential/wire suites at every task boundary.
