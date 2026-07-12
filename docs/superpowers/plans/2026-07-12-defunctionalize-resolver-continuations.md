# Defunctionalize Resolver Continuations + Collapse Executor Layers — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the resolver column's anonymous `:measure` closures with plain data tags plus one named `continue/4` behaviour callback, and merge `Transform.PlanExecutor` + `Transform.ResolveDriver` into a single `Transform.Executor` (issue #446).

**Architecture:** The continuation becomes `{:advance, shape, state} | {:measure, tag, state}` — pure data. The driver, on a `:measure`, measures the live dims and calls the strategy's new `continue(tag, dims, shape, state)` callback (dispatched through the `ImagePipe.Resolver` facade, same quarantine as `resolve/3`), passing the *pre-op shape* the strategy saw at resolve time. Every "what happens after the resize?" becomes a named, grep-able clause in `NeutralResolver.continue/4`. `Resolver.rewrap/2` collapses to two data-substitution clauses; `PointFlow` carries `{point, entry_dims}` as data across the seam instead of wrapping closures. Then the thin `PlanExecutor` (preamble seeding) merges into the driver as one `ImagePipe.Transform.Executor`.

**Tech Stack:** Elixir, ExUnit, Boundary. All commands run through `mise exec -- …`.

## Global Constraints

- **Results-identical.** No pixel/geometry behavior change. Pinned by the resolver/driver/strategy unit tests and the imgproxy + TwicPics differential suites (both run on the default `mix test` lane). No `behavior_version/0` bumps — this is an encoding change, not a resolution-rule change.
- **Keep the `chain:` seam.** The issue proposed dropping it *if* the driver tests can live with `measure_dims` alone — they cannot: the golden ±1 tests (`resolved_plan_golden_test.exs` "±1 divergence" describe block, 4 tests) use an injected capturing chain as their no-pixel harness. Decision: keep both seams.
- **Boundary discipline.** Dynamic strategy dispatch stays quarantined in the `ImagePipe.Resolver` facade (`resolve/3` and the new `continue/5`). The new `Executor` stays unexported inside the `ImagePipe.Transform` boundary; `ImagePipe.Transform.execute_plan/3` remains the facade entry.
- **Docs in the same change**: `docs/execution_flow.md`, `docs/custom_parser_guide.md` (resolver section), `AGENTS.md` boundary-guidelines wording.
- Gates before finishing: `mise run precommit` (format, compile --warnings-as-errors, credo --strict, full test).
- Worktree quirks: run everything via `mise exec -- …`; if `mix format --check-formatted` fails repo-wide, check for a dangling `.credo.exs` symlink.

## Design Reference (read before any task)

### New `ImagePipe.Resolver` contract

```elixir
@type strategy_state :: term()
@type strategy :: {module(), strategy_state()}
@type tag :: term()   # strategy-private; opaque to the driver

@type continuation ::
        {:advance, SourceShape.t(), strategy_state()}
        | {:measure, tag(), strategy_state()}

@typedoc "What continue/4 returns: the final post-op {shape, state}, or a further {ops, continuation} stage (multi-executable expansion split at the realized-dims seam, spec §4.4)."
@type continue_result ::
        {SourceShape.t(), strategy_state()}
        | {[struct()], continuation()}

@callback init() :: strategy_state()
@callback resolve(SourceShape.t(), strategy_state(), struct()) :: {[struct()], continuation()}
@callback continue(tag(), {pos_integer(), pos_integer()}, SourceShape.t(), strategy_state()) ::
            continue_result()
@callback behavior_version() :: pos_integer()
```

**Driver ↔ strategy contract for `continue/4`:** `dims` are the measured live-image dims; `shape` is **the pre-op shape the strategy's `resolve/3` saw for the current plan op** (the driver holds it across all stages of one plan op — this replaces what the closures used to capture); `strategy_state` is the state carried in the `{:measure, tag, state}` tuple (NOT the resolve-time strategy tuple's state).

### The five neutral tags (owned by `NeutralResolver`, `strategy_state` always `nil`)

| Tag | Emitted by (resolve row) | `continue/4` does |
|---|---|---|
| `:rotate` | arbitrary-angle / mirrored `%PlanRotate{}` | final `{%{shape \| width: w, height: h, frame: :display, pending_orientation: nil}, nil}` |
| `:trim` | `%PlanTrim{}` | re-derives `pending` from `pending_class(shape)` (`:pending` → keep, else `nil`); final `{%{shape \| width: w, height: h, pending_orientation: pending, decode_shrink: nil}, nil}` |
| `:resize` | bare plain resize (`plain_resize_stage([resize])`) | final `{%{shape \| width: w, height: h, decode_shrink: nil}, nil}` |
| `{:resize_tail, tail}` | plain staged resize (`plain_resize_stage([resize \| tail])`) | `{box_w, box_h} = staged_tail_dims(tail, dims)`; stage `{tail, {:advance, %{shape \| width: box_w, height: box_h, decode_shrink: nil}, nil}}` |
| `{:resize_flush_tail, tail}` | pending-orientation resize (tail already compensated at resolve) | `po = shape.pending_orientation`; `{box_w, box_h} = staged_tail_dims(tail, dims)`; swap for quarter turn; stage `{tail ++ [%Flush{}], {:advance, %{shape \| width: display_w, height: display_h, frame: :display, pending_orientation: nil, decode_shrink: nil}, nil}}` |

Equivalence arguments (each closure captured exactly what the tag + pre-op shape reconstruct):
- rotate closure captured `shape` only → shape is now a `continue` arg. ✓
- trim closure captured `shape` + `pending` (derived from `pending_class(shape)` at resolve time) → recomputed identically in `continue` from the same shape, pure. ✓
- pending-resize closure captured `shape`, `po` (= `shape.pending_orientation`, non-nil in that branch) and the compensated `tail` → shape is an arg, `po` re-read from it, `tail` rides in the tag. ✓
- plain staged closure captured `shape` + `tail`. ✓

### `rewrap/2` becomes data threading

```elixir
def rewrap({:advance, shape, nil}, strategy_state), do: {:advance, shape, strategy_state}
def rewrap({:measure, tag, nil}, strategy_state), do: {:measure, tag, strategy_state}
```

The nil-match crash-on-misuse semantics are preserved. Recursion disappears (a staged expansion's inner continuation is re-wrapped when the stage is produced by the dialect's `continue/4`, see below).

### Dialect `continue/4` implementations

imgproxy (carry substitution around the neutral delegate):

```elixir
@impl ImagePipe.Resolver
def continue(tag, dims, %SourceShape{} = shape, carry) do
  case NeutralResolver.continue(tag, dims, shape, nil) do
    {%SourceShape{} = final, nil} -> {final, carry}
    {ops, continuation} when is_list(ops) -> {ops, ImagePipe.Resolver.rewrap(continuation, carry)}
  end
end
```

TwicPics: `PointFlow`'s measure-seam state is the tuple `{:seam, point, entry_dims}` (what the closure used to capture); `TwicPics.Resolver.continue/4` delegates to `PointFlow.continue/4`, which scales the point at the seam and, on a staged expansion, walks the stage exactly as today.

### Executor merge

`lib/image_pipe/transform/plan_executor.ex` + `lib/image_pipe/transform/resolve_driver.ex` → one `lib/image_pipe/transform/executor.ex` (`ImagePipe.Transform.Executor`, `@moduledoc false`). Public functions: `execute/3` (plan entry, ex-PlanExecutor) and `run/5` (pipeline loop with `measure_dims`/`chain` seams, ex-ResolveDriver — kept public for the golden/driver tests). `Transform.execute_plan/3` facade unchanged in signature, now calls `Executor.execute/3`.

---

### Task 1: Defunctionalize the continuation (contract + neutral + driver + both dialect strategies)

This is one atomic compile unit — the continuation shape flows through `resolver.ex`, `neutral_resolver.ex`, `resolve_driver.ex`, `imgproxy/resolver.ex`, `twic_pics/{resolver,point_flow}.ex` and their tests. Tests are rewritten first (they fail to compile / fail on shape), then the implementation lands, then the full suite pins results-identical.

**Files:**
- Modify: `lib/image_pipe/resolver.ex`
- Modify: `lib/image_pipe/transform/neutral_resolver.ex`
- Modify: `lib/image_pipe/transform/resolve_driver.ex`
- Modify: `lib/image_pipe/parser/imgproxy/resolver.ex`
- Modify: `lib/image_pipe/parser/twic_pics/resolver.ex`
- Modify: `lib/image_pipe/parser/twic_pics/point_flow.ex`
- Test: `test/image_pipe/resolver_test.exs`
- Test: `test/image_pipe/transform/neutral_resolver_test.exs`
- Test: `test/image_pipe/transform/resolve_driver_test.exs`
- Test: `test/image_pipe/parser/imgproxy/resolver_test.exs`
- Test: `test/image_pipe/parser/twic_pics/resolver_test.exs`

**Interfaces:**
- Consumes: current `ImagePipe.Resolver` behaviour, `SourceShape`, `PendingOrientation`, `Crop.resolved_box_dims/3`, `Focus` helpers.
- Produces (later tasks and all strategy code rely on these exact names):
  - `ImagePipe.Resolver` types `tag/0`, `continuation/0` (3-tuple `:measure`), `continue_result/0`; callback `continue/4`; facade `ImagePipe.Resolver.continue(strategy, tag, dims, shape, strategy_state)`; `rewrap/2` (data form).
  - `NeutralResolver.continue/4` handling tags `:rotate`, `:trim`, `:resize`, `{:resize_tail, tail}`, `{:resize_flush_tail, tail}`.
  - `ImagePipe.Parser.Imgproxy.Resolver.continue/4`, `ImagePipe.Parser.TwicPics.Resolver.continue/4`, `ImagePipe.Parser.TwicPics.PointFlow.continue/4` with seam state `{:seam, point, entry_dims}`.

- [ ] **Step 1: Rewrite `test/image_pipe/resolver_test.exs` to the new contract**

Full new file content:

```elixir
defmodule ImagePipe.ResolverTest do
  use ExUnit.Case, async: true
  alias ImagePipe.Resolver
  alias ImagePipe.Transform.SourceShape

  defmodule Dummy do
    @behaviour ImagePipe.Resolver
    @impl true
    def init, do: %{n: 0}
    @impl true
    def behavior_version, do: 1
    @impl true
    def resolve(%SourceShape{} = shape, %{n: n}, op),
      do: {[{:emitted, op}], {:advance, shape, %{n: n + 1}}}

    @impl true
    def continue({:finish, extra}, {w, h}, %SourceShape{} = shape, %{n: n}),
      do: {%{shape | width: w, height: h}, %{n: n + extra}}
  end

  setup do
    shape =
      SourceShape.seed(%{width: 10, height: 10, pending_orientation: nil, decode_shrink: nil})

    %{shape: shape}
  end

  test "resolve/3 dispatches, threads strategy_state via the continuation", %{shape: shape} do
    {ops, cont} = Resolver.resolve({Dummy, Dummy.init()}, shape, :op)
    assert ops == [{:emitted, :op}]
    assert {:advance, ^shape, %{n: 1}} = cont
  end

  test "continue/5 dispatches with the continuation-carried state, not the strategy tuple's",
       %{shape: shape} do
    # The strategy tuple carries the stale resolve-time state; the state that
    # travels is the one in the {:measure, tag, state} continuation.
    assert {%SourceShape{width: 7, height: 5}, %{n: 42}} =
             Resolver.continue({Dummy, %{n: 999}}, {:finish, 40}, {7, 5}, shape, %{n: 2})
  end

  describe "rewrap/2" do
    setup %{shape: shape} do
      %{shape: shape, carry: %{scale: 2.5}}
    end

    test "substitutes the carry into a stateless :advance", %{shape: shape, carry: carry} do
      assert Resolver.rewrap({:advance, shape, nil}, carry) == {:advance, shape, carry}
    end

    test "substitutes the carry into a stateless :measure", %{carry: carry} do
      assert Resolver.rewrap({:measure, {:resize_tail, [:crop]}, nil}, carry) ==
               {:measure, {:resize_tail, [:crop]}, carry}
    end
  end
end
```

- [ ] **Step 2: Run it to verify it fails**

Run: `mise exec -- mix test test/image_pipe/resolver_test.exs`
Expected: FAIL — `Resolver.continue/5 is undefined`, rewrap `FunctionClauseError` on the 3-tuple, and a `continue/4 not implemented` behaviour warning under `--warnings-as-errors` later. (Compile may fail outright; that is the expected red.)

- [ ] **Step 3: Implement the new `lib/image_pipe/resolver.ex`**

Full new file content:

```elixir
defmodule ImagePipe.Resolver do
  @moduledoc """
  Neutral behaviour + dispatch facade for geometry resolution (spec §4.2/§5.1).
  A plan carries a `strategy` (`{module, strategy_state}`); the driver calls
  `resolve/3` per plan op and `continue/5` per measure seam; the dynamic calls
  to the carried module are quarantined here (mirrors `ImagePipe.Renderer`).

  The continuation is plain data and the only `strategy_state` channel:
  `{:advance, shape, state}` when the strategy computed the post-op geometry
  purely, or `{:measure, tag, state}` when it cannot be known without looking
  at the realized image. The driver measures the live dims and calls
  `continue(tag, dims, shape, state)` on the strategy — `shape` being the
  pre-op shape the strategy's `resolve/3` saw for the current plan op — which
  returns the final `{shape, state}` or a further `{ops, continuation}` stage:
  a multi-executable expansion split at the realized-dims seam (spec §4.4
  Stage 3), which the driver executes and continues. Tags are strategy-private
  vocabulary; the driver never inspects them.

  The facade passes shape opaquely — no runtime reference to `SourceShape` —
  so this boundary stays `deps: [ImagePipe.Plan]`.
  """
  use Boundary, top_level?: true, deps: [ImagePipe.Plan], exports: []

  alias ImagePipe.Transform.SourceShape

  @type strategy_state :: term()
  @type strategy :: {module(), strategy_state()}

  @typedoc """
  A strategy-private continuation tag: names what happens after the measure
  (e.g. `ImagePipe.Transform.NeutralResolver`'s `{:resize_flush_tail, tail}`).
  Opaque to the driver.
  """
  @type tag :: term()

  @type continuation ::
          {:advance, SourceShape.t(), strategy_state()}
          | {:measure, tag(), strategy_state()}

  @typedoc """
  What `continue/4` returns: the final post-op `{shape, strategy_state}`, or a
  further `{ops, continuation}` stage — a multi-executable expansion split at
  the realized-dims seam (spec §4.4). The driver executes the stage's ops and
  continues; shape measurement stays the driver's one seam, just allowed to
  fire more than once per plan op.
  """
  @type continue_result ::
          {SourceShape.t(), strategy_state()}
          | {[struct()], continuation()}

  @callback init() :: strategy_state()
  @callback resolve(SourceShape.t(), strategy_state(), struct()) ::
              {[struct()], continuation()}

  @doc """
  Continue a `{:measure, tag, strategy_state}` continuation once the realized
  dims are known. `shape` is the pre-op shape `resolve/3` saw for the current
  plan op; `strategy_state` is the state carried in the continuation.
  """
  @callback continue(tag(), {pos_integer(), pos_integer()}, SourceShape.t(), strategy_state()) ::
              continue_result()

  @doc """
  Behavioral version of this strategy's resolution algorithms. Enters
  `ImagePipe.Cache.Key.plan_material/2` (hence the ETag material): bump it when
  any resolution rule this strategy owns changes algorithm, so stale-but-
  differently-resolved bytes cannot be revalidated through a stable ETag
  (spec §7). Orthogonal to the key schema version.
  """
  @callback behavior_version() :: pos_integer()

  @spec resolve(strategy(), shape :: term(), struct()) :: {[struct()], continuation()}
  def resolve({module, strategy_state}, shape, op) do
    module.resolve(shape, strategy_state, op)
  end

  @spec continue(strategy(), tag(), {pos_integer(), pos_integer()}, term(), strategy_state()) ::
          continue_result()
  def continue({module, _resolve_state}, tag, dims, shape, strategy_state) do
    module.continue(tag, dims, shape, strategy_state)
  end

  @doc """
  Substitute the caller's `strategy_state` into a continuation produced by a
  stateless (nil-state) strategy so the carry survives the advance.

  The standard carried-state pattern delegates shared geometry to a stateless
  strategy (`ImagePipe.Transform.NeutralResolver`) and layers dialect decisions
  on top. The delegate threads `nil` into every continuation it builds, so a
  carried strategy that returns those continuations unmodified loses its state
  at the first `:advance`. A carried strategy's `continue/4` delegates the tag
  the same way and re-wraps any staged expansion's continuation it gets back.

  Matching the inner state to `nil` is deliberate: re-wrapping a continuation
  whose strategy carries its own state would silently discard it, so that
  misuse crashes instead.

  A strategy whose state must be *transformed* per emitted op (not carried
  unchanged) walks the emission itself; see
  `ImagePipe.Parser.TwicPics.PointFlow`.
  """
  @spec rewrap(continuation(), strategy_state()) :: continuation()
  def rewrap({:advance, shape, nil}, strategy_state), do: {:advance, shape, strategy_state}
  def rewrap({:measure, tag, nil}, strategy_state), do: {:measure, tag, strategy_state}
end
```

- [ ] **Step 4: Defunctionalize `lib/image_pipe/transform/neutral_resolver.ex`**

Six edits. Add a `measure/1` helper next to `advance/1`, replace the five closure sites with tags, and add the `continue/4` clauses. Keep everything else (lowering, compensation, pending_class, etc.) untouched.

4a. Arbitrary/mirrored rotate row — replace the `after_measure` closure:

```elixir
  # Arbitrary angle or mirror: a materializing op. An explicit flush before the
  # rotate lands the rotation in the display frame (EXIF auto-orient -> then
  # user rotation). decode_shrink stays untouched (nothing clears it at a
  # rotate; no parser places a shrink consumer after rotation).
  defp do_resolve(%PlanRotate{} = operation, %SourceShape{} = shape) do
    ops = Lowering.executable_operations(operation, shape)

    case pending_class(shape) do
      :pending -> {[%Flush{} | ops], measure(:rotate)}
      _none_or_identity -> {ops, measure(:rotate)}
    end
  end
```

4b. Pending-resize row — the `stage` closure becomes a tag carrying the compensated tail:

```elixir
  defp do_resolve(%PlanResize{} = operation, %SourceShape{} = shape) do
    case pending_class(shape) do
      :pending ->
        po = shape.pending_orientation
        [resize | tail] = pending_resize_ops(operation, po, shape)
        {[resize], measure({:resize_flush_tail, tail})}

      _none_or_identity ->
        # An identity pending is kept (this row is not a flush site); the
        # pipeline boundary clears it without pixels.
        plain_resize_stage(Lowering.executable_operations(operation, shape))
    end
  end
```

4c. Trim row — drop the closure (the pending decision moves to `continue/4`, derived from the same shape):

```elixir
  defp do_resolve(%PlanTrim{} = operation, %SourceShape{} = shape) do
    {Lowering.executable_operations(operation, shape), measure(:trim)}
  end
```

(Keep the existing trim row comment block; append one line to it: `# The post-trim pending decision lives in continue(:trim, …).`)

4d. `plain_resize_stage` loses its shape parameter (the closures were its only use):

```elixir
  # A plain resize with an empty tail is the final form (bare [resize]); with a
  # result-crop tail it stages, advancing the shape from the measured dims.
  defp plain_resize_stage([resize]), do: {[resize], measure(:resize)}
  defp plain_resize_stage([resize | tail]), do: {[resize], measure({:resize_tail, tail})}
```

4e. Add the `continue/4` clauses right after `resolve/3` (before `do_resolve`), plus the `measure/1` helper next to `advance/1`:

```elixir
  # ── continue: the named post-measure clauses (issue #446) ─────────────────
  # One clause per tag; `shape` is the pre-op shape resolve/3 saw (the driver
  # threads it), so each clause reconstructs its result from the tag, the
  # pre-op shape, and the measured dims alone.

  @impl ImagePipe.Resolver
  def continue(:rotate, {w, h}, %SourceShape{} = shape, nil),
    do: {%{shape | width: w, height: h, frame: :display, pending_orientation: nil}, nil}

  def continue(:trim, {w, h}, %SourceShape{} = shape, nil) do
    pending =
      case pending_class(shape) do
        :pending -> shape.pending_orientation
        _none_or_identity -> nil
      end

    {%{shape | width: w, height: h, pending_orientation: pending, decode_shrink: nil}, nil}
  end

  def continue(:resize, {w, h}, %SourceShape{} = shape, nil),
    do: {%{shape | width: w, height: h, decode_shrink: nil}, nil}

  def continue({:resize_tail, tail}, {w, h}, %SourceShape{} = shape, nil) do
    {box_w, box_h} = staged_tail_dims(tail, {w, h})
    {tail, advance(%{shape | width: box_w, height: box_h, decode_shrink: nil})}
  end

  # The pending-resize stage: the (already compensated) tail runs, then the
  # flush; the shape advances to the display frame with the quarter-turn swap.
  def continue({:resize_flush_tail, tail}, {w, h}, %SourceShape{} = shape, nil) do
    po = shape.pending_orientation
    {box_w, box_h} = staged_tail_dims(tail, {w, h})
    {display_w, display_h} = swap_if_quarter_turn({box_w, box_h}, po)

    {tail ++ [%Flush{}],
     advance(%{
       shape
       | width: display_w,
         height: display_h,
         frame: :display,
         pending_orientation: nil,
         decode_shrink: nil
     })}
  end
```

and next to `defp advance/1`:

```elixir
  defp measure(tag), do: {:measure, tag, nil}
```

4f. Update the module's top comment block: replace the sentence about continuation classification with

```elixir
  # Continuation classification: :measure iff the post-op dims cannot be
  # computed purely — resize, trim, and arbitrary-angle/mirrored rotate;
  # everything else advances the shape purely. Each :measure carries a named
  # tag ({:measure, tag, nil}); the matching continue/4 clause below is the
  # single place that says what happens after the measure.
```

Also update the moduledoc's delegation sentence to mention that carried strategies delegate `continue/4` tags back to this module (see Step 6/7 call shapes).

- [ ] **Step 5: Rework the driver loop in `lib/image_pipe/transform/resolve_driver.ex`**

The pre-op shape must now thread through the stages. Replace `run/5`'s reduce body, `execute_stages`, and the two `continue` clauses (module comment: update the `:measure` sentence to "…or, for a `{:measure, tag, state}` continuation, from the measured post-execution dims via the strategy's `continue/4` (spec §4.4 Stage 3), recursing until a final `{shape, strategy_state}`"):

```elixir
    pipeline
    |> Enum.reduce_while({:ok, shape, strategy, state}, fn operation, acc ->
      {:ok, shape, strategy, state} = acc
      state = overlay(state, shape)

      {ops, continuation} = Resolver.resolve(strategy, shape, operation)

      case execute_stages(ops, continuation, shape, strategy, state, chain, measure_dims, opts) do
        {:ok, shape, strategy, state} -> {:cont, {:ok, shape, strategy, state}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
```

```elixir
  # One resolve may execute in several stages: run this stage's ops, then either
  # finish (final {shape, strategy_state}) or measure the realized dims and run
  # the next stage the strategy's continue/4 returns. `resolve_shape` is the
  # pre-op shape the strategy resolved against — the continue/4 contract.
  # Recursion depth is the emission's stage count (2 for a cover) — never
  # unbounded.
  defp execute_stages(ops, continuation, resolve_shape, strategy, state, chain, measure_dims, opts) do
    case chain.(state, ops, opts) do
      {:ok, %State{} = state} ->
        continue(continuation, resolve_shape, strategy, state, chain, measure_dims, opts)

      {:error, _reason} = error ->
        error
    end
  end

  defp continue(
         {:advance, %SourceShape{} = shape, strategy_state},
         _resolve_shape,
         {module, _},
         state,
         _chain,
         _measure_dims,
         _opts
       ),
       do: {:ok, shape, {module, strategy_state}, state}

  defp continue(
         {:measure, tag, strategy_state},
         resolve_shape,
         {module, _} = strategy,
         state,
         chain,
         measure_dims,
         opts
       ) do
    case Resolver.continue(strategy, tag, measure_dims.(state.image), resolve_shape, strategy_state) do
      {%SourceShape{} = shape, strategy_state} ->
        {:ok, shape, {module, strategy_state}, state}

      {ops, continuation} when is_list(ops) ->
        execute_stages(ops, continuation, resolve_shape, strategy, state, chain, measure_dims, opts)
    end
  end
```

- [ ] **Step 6: Update `lib/image_pipe/parser/imgproxy/resolver.ex`**

Add after `resolve/3`'s clauses (the existing `rewrap` call sites in `resolve/3` stay exactly as they are — `rewrap/2`'s new implementation does the same substitution on data):

```elixir
  @impl ImagePipe.Resolver
  def continue(tag, dims, %SourceShape{} = shape, carry) do
    case NeutralResolver.continue(tag, dims, shape, nil) do
      {%SourceShape{} = final, nil} -> {final, carry}
      {ops, continuation} when is_list(ops) -> {ops, ImagePipe.Resolver.rewrap(continuation, carry)}
    end
  end
```

Update the "── delegation ──" comment to: "Re-wrap the neutral continuation (resolve) and re-attach the carry around the neutral continue (measure seams) so the imgproxy carry survives — a trim between resize and padding must not lose the stashed DprScale."

- [ ] **Step 7: Update `lib/image_pipe/parser/twic_pics/point_flow.ex` and `resolver.ex`**

`point_flow.ex` — replace the closure-wrapping `rewrap/4` with data, expose `continue/4`, and hang the seam state off a named tuple. Full new module body below the moduledoc/comment (keep the existing step/3 clauses, `scale_at_seam/3` becomes seam scaling inside `continue/4`, `substituted_gravity/3` unchanged; update the moduledoc bullet for %Resize{} to say the factor is "applied in `continue/4` at the stage seam"):

```elixir
  @typedoc "Measure-seam carry: the point plus the dims entering the measured stage."
  @type seam_state :: {:seam, Focus.point() | nil, {pos_integer(), pos_integer()}}

  @spec advance([struct()], Resolver.continuation(), Focus.point() | nil, SourceShape.t()) ::
          {[struct()], Resolver.continuation()}
  def advance(ops, continuation, point, %SourceShape{} = shape) do
    walk_stage(ops, continuation, point, SourceShape.live_dims(shape), shape.pending_orientation)
  end

  @doc """
  Continue a measure seam: scale the carried point by the realized per-axis
  factor (every TwicPics-reachable seam follows a %Resize{}, the terminal-op
  invariant — measured/entry is the same integer pair Resize.execute realized),
  delegate the tag to the neutral resolver, and walk any staged expansion.
  """
  @spec continue(Resolver.tag(), {pos_integer(), pos_integer()}, SourceShape.t(), seam_state()) ::
          Resolver.continue_result()
  def continue(tag, measured, %SourceShape{} = shape, {:seam, point, entry_dims}) do
    point = scale_at_seam(point, entry_dims, measured)

    case NeutralResolver.continue(tag, measured, shape, nil) do
      {%SourceShape{} = final, nil} ->
        {final, point}

      {ops, continuation} when is_list(ops) ->
        walk_stage(ops, continuation, point, measured, shape.pending_orientation)
    end
  end

  defp walk_stage(ops, continuation, point, entry_dims, po) do
    {ops, {point, dims}} = Enum.map_reduce(ops, {point, entry_dims}, &step(&1, &2, po))
    {ops, rewrap(continuation, point, dims)}
  end

  defp rewrap({:advance, %SourceShape{} = shape, nil}, point, _dims),
    do: {:advance, shape, point}

  defp rewrap({:measure, tag, nil}, point, dims),
    do: {:measure, tag, {:seam, point, dims}}
```

Add `alias ImagePipe.Transform.NeutralResolver` to point_flow.ex. `resolver.ex` gains the delegating callback:

```elixir
  @impl ImagePipe.Resolver
  def continue(tag, measured, %SourceShape{} = shape, seam_state),
    do: PointFlow.continue(tag, measured, shape, seam_state)
```

- [ ] **Step 8: Update the four strategy/driver test files**

8a. `test/image_pipe/transform/neutral_resolver_test.exs` — mechanical closure→tag rewrites; each `after_measure.(dims)` becomes a `NeutralResolver.continue(tag, dims, resolve_shape, nil)` call where `resolve_shape` is the same shape passed to `resolve/3`:

- "trim → :measure…" test (line ~50): `{ops, {:measure, :trim, nil}} = NeutralResolver.resolve(s, nil, %Trim{…})` … `{shape2, nil} = NeutralResolver.continue(:trim, {90, 70}, s, nil)`
- "trim under a non-identity pending…" (line ~68): same substitution with its local `s`.
- "resize under a non-identity pending stages…" (line ~145): `{[%ExecResize{}], {:measure, {:resize_flush_tail, _} = tag, nil}} = NeutralResolver.resolve(s, nil, resize)` then `{stage_ops, {:advance, shape2, nil}} = NeutralResolver.continue(tag, {50, 40}, s, nil)`. Update the comment above it ("the stage the after_measure returns" → "the stage continue/4 returns").
- "resize with no pending…" (line ~166): `{ops, {:measure, :resize, nil}} = …` then `{shape2, nil} = NeutralResolver.continue(:resize, {50, 40}, s, nil)`
- §4.7 "measure-classified ops" (line ~259): `assert match?({:measure, _tag, nil}, continuation), …`
- §4.7 "a resize is the terminal op of its stage" (line ~287): destructure `{ops, {:measure, tag, nil}} = NeutralResolver.resolve(s, nil, op)` and `case NeutralResolver.continue(tag, {50, 40}, s, nil) do` with the same two case arms. Update the comment ("any tail arrives via the stage the after_measure returns" → "any tail arrives via the stage continue/4 returns").
- Add one new test (the `:rotate` tag is otherwise only exercised end-to-end):

```elixir
  test "arbitrary rotate → :measure; continue lands the display frame", %{shape: s} do
    {ops, {:measure, :rotate, nil}} =
      NeutralResolver.resolve(s, nil, %PlanRotate{angle: 45, mirror: false})

    refute ops == []
    {shape2, nil} = NeutralResolver.continue(:rotate, {128, 128}, s, nil)
    assert shape2.frame == :display
    assert shape2.pending_orientation == nil
    assert {shape2.width, shape2.height} == {128, 128}
    assert shape2.decode_shrink == s.decode_shrink
  end
```

8b. `test/image_pipe/transform/resolve_driver_test.exs` — the Probe strategy defunctionalizes; the assertions and seams stay identical:

```elixir
  defmodule Probe do
    @behaviour ImagePipe.Resolver

    @impl true
    def init, do: nil

    @impl true
    def behavior_version, do: 1

    @impl true
    def resolve(%SourceShape{} = shape, agent, :pure) do
      {[], {:advance, %{shape | width: shape.width + 1}, agent}}
    end

    def resolve(%SourceShape{}, agent, :opaque) do
      {[], {:measure, :probe, agent}}
    end

    @impl true
    def continue(:probe, {w, h}, %SourceShape{} = shape, agent) do
      Agent.update(agent, &[{:measured, w, h} | &1])
      {%{shape | width: w, height: h}, agent}
    end
  end
```

8c. `test/image_pipe/parser/imgproxy/resolver_test.exs` — the `carry_of/1` helper becomes pure destructuring (deliberate: it now asserts the carry is present in the data tuple; carry survival *through* the seam gets its own direct assertion below — do not reintroduce a closure invocation):

```elixir
  defp carry_of({:advance, _shape, carry}), do: carry
  defp carry_of({:measure, _tag, carry}), do: carry
```

And in the "#237 resize stashes the padding scales" test, after the existing `assert top == round(10 * scale)`, add a direct pin on the seam re-attachment (`ImgproxyResolver.continue/4` delegating the neutral `:resize` tag and re-attaching the carry):

```elixir
    assert {%SourceShape{}, ^carry} =
             ImgproxyResolver.continue(:resize, {100, 75}, shape(800, 600), carry)
```

8d. `test/image_pipe/parser/twic_pics/resolver_test.exs` — the four staged-cover tests stop invoking closures. In each, replace the `{:measure, stage}` destructure + `stage.(dims)` invocation with the tag/`continue` pair, keeping every assertion byte-identical. Pattern (test "a staged cover substitutes :deferred…"):

```elixir
    {[%ExecResize{}], {:measure, tag, seam}} =
      TwicPicsResolver.resolve(shape(400, 400), point, resize)

    {[%Crop{gravity: gravity}], {:advance, _shape, carried}} =
      TwicPicsResolver.continue(tag, {200, 200}, shape(400, 400), seam)
```

Same shape for "a nil point substitutes the centred anchor" (`continue(tag, {200, 200}, shape(400, 400), seam)`), and for the two pending-orientation tests the resolve shape is `shape(40, 80, po)` and the dims `{20, 40}`:

```elixir
    {[%ExecResize{mode: :force}], {:measure, tag, seam}} =
      TwicPicsResolver.resolve(shape(40, 80, po), point, resize)

    {[%Crop{gravity: gravity}, %Flush{}], {:advance, advanced, carried}} =
      TwicPicsResolver.continue(tag, {20, 40}, shape(40, 80, po), seam)
```

- [ ] **Step 9: Run the focused suites to green**

Run:
```bash
mise exec -- mix test test/image_pipe/resolver_test.exs \
  test/image_pipe/transform/neutral_resolver_test.exs \
  test/image_pipe/transform/resolve_driver_test.exs \
  test/image_pipe/transform/resolved_plan_golden_test.exs \
  test/image_pipe/transform/plan_executor_test.exs \
  test/image_pipe/parser/imgproxy/resolver_test.exs \
  test/image_pipe/parser/twic_pics/resolver_test.exs
```
Expected: PASS (golden + plan_executor pass untouched — the seams and results are unchanged).

- [ ] **Step 10: Run the full suite (results-identical pin: imgproxy + TwicPics differential lanes included)**

Run: `mise exec -- mix test`
Expected: PASS, zero failures.

- [ ] **Step 11: Compile-warnings + commit**

Run: `mise exec -- mix compile --warnings-as-errors && mise exec -- mix format`
Then:
```bash
git add -A
git commit -m "Defunctionalize resolver continuations: {:measure, tag, state} + continue/4 (#446)"
```

---

### Task 2: Merge PlanExecutor + ResolveDriver into Transform.Executor

**Files:**
- Create: `lib/image_pipe/transform/executor.ex`
- Delete: `lib/image_pipe/transform/plan_executor.ex`, `lib/image_pipe/transform/resolve_driver.ex`
- Modify: `lib/image_pipe/transform.ex` (alias + call site)
- Rename: `test/image_pipe/transform/plan_executor_test.exs` → `test/image_pipe/transform/executor_test.exs` (absorbs `resolve_driver_test.exs`, which is deleted)
- Modify: `test/image_pipe/transform/resolved_plan_golden_test.exs`, `test/image_pipe/architecture_boundary_test.exs`
- Modify (comment-only sweep): `lib/image_pipe/transform/state.ex`, `lib/image_pipe/transform/decode_planner.ex`, `lib/image_pipe/transform/focus.ex`, `lib/image_pipe/transform/orientation.ex`, `lib/image_pipe/transform/input_color_management.ex`, `lib/image_pipe/transform/operation/crop.ex`, `lib/image_pipe/request/processor.ex`, `docs/imgproxy_support_matrix.md` (line ~117, `PlanExecutor.execute/3` mention), `docs/iiif_3_support_matrix.md` (line ~127), `bench/oversized_buffer_highwater.exs` (lines ~21, ~214), plus test-side comments (`focus_test.exs`, `deferred_orientation*_test.exs`, `resize_dimension_test.exs`, `imgproxy_wire_conformance_test.exs`, `test/support/image_pipe/test/resolved_plan_cases.ex`, `resolved_plan_expected.exs`, `imgproxy_differential/constellations.ex`)

**Interfaces:**
- Consumes: Task 1's driver internals (verbatim — this task moves code, it does not change logic).
- Produces: `ImagePipe.Transform.Executor.execute(plan, state, opts)` (plan entry) and `ImagePipe.Transform.Executor.run(pipeline_ops, shape, strategy, state, opts)` (pipeline loop, `opts[:measure_dims]`/`opts[:chain]` seams kept). `ImagePipe.Transform.execute_plan/3` signature unchanged.

- [ ] **Step 1: Create `lib/image_pipe/transform/executor.ex`**

Content = concatenation of the two modules, logic-identical: `@moduledoc false`; a merged header comment (PlanExecutor's "orchestrates plan execution" paragraph followed by ResolveDriver's per-pipeline loop/overlay/strategy-state paragraphs, with intra-references updated to "this module"); PlanExecutor's `execute/3`, `seed_color_management/2`, `run_color_management/2`, `exif_orientation/1`, `execute_pipelines/4`, `execute_pipeline/4` — with `execute_pipeline/4`'s last line now `run(operations, shape, {resolver, resolver.init()}, state, opts)` — then ResolveDriver's `run/5` (made `@doc false` public as today — keep its `opts \\ []` default arg), `overlay/2`, `execute_stages/8`, `continue/7`, `default_measure_dims/1`, `flush_boundary/4`, `boundary_source_dimensions/1`. Alias set = union of both modules' aliases minus `ResolveDriver`/`PlanExecutor`.

- [ ] **Step 2: Point the facade at it and delete the old files**

In `lib/image_pipe/transform.ex`: `alias ImagePipe.Transform.PlanExecutor` → `alias ImagePipe.Transform.Executor`; `PlanExecutor.execute(plan, state, opts)` → `Executor.execute(plan, state, opts)`. Then `git rm lib/image_pipe/transform/plan_executor.ex lib/image_pipe/transform/resolve_driver.ex` (after the new file carries their content).

- [ ] **Step 3: Migrate the tests**

- `git mv test/image_pipe/transform/plan_executor_test.exs test/image_pipe/transform/executor_test.exs`; in it: `defmodule ImagePipe.Transform.ExecutorTest`, alias/call rename `PlanExecutor` → `Executor`.
- Move the single test from `resolve_driver_test.exs` into `executor_test.exs` as a new `describe "run/5 (pipeline loop)"` block (Probe module moves along, renamed references `ResolveDriver.run` → `Executor.run`); delete `resolve_driver_test.exs`.
- `resolved_plan_golden_test.exs`: `alias ImagePipe.Transform.ResolveDriver` → `alias ImagePipe.Transform.Executor`; the four `ResolveDriver.run(` call sites → `Executor.run(`; comment mentions updated.
- Other test files: rename `PlanExecutor` aliases/calls to `Executor` in `focus_test.exs`, `deferred_orientation_test.exs`, `deferred_orientation_frame_test.exs`.
- `architecture_boundary_test.exs`: replace the module/name-list entries — `@post_fetch_transform_state_modules [ImagePipe.Transform.Executor]`, `@cache_prefetch_forbidden_transform_state_names [:Executor]`, `@runtime_forbidden_transform_execution_names [:Executor]`, and the AST-matching clauses/string lists that today spell `:PlanExecutor` / `"PlanExecutor.execute"` / `"Transform.PlanExecutor.execute"` / `"ImagePipe.Transform.PlanExecutor.execute"` / `"ImagePipe.Transform.PlanExecutor"` → the `Executor` spellings (lines ~97–102, ~1014–1027, ~1228–1241, ~1389–1406; this enumeration is not exhaustive — the Step 4 sweep is the completeness check, and also catches the comment at line ~728).

- [ ] **Step 4: Comment sweep**

Run: `rg -n "PlanExecutor|ResolveDriver" lib test bench docs AGENTS.md -g '!docs/superpowers/**'` and update every remaining mention (all comments/docs — including `docs/imgproxy_support_matrix.md`, `docs/iiif_3_support_matrix.md`, and `bench/oversized_buffer_highwater.exs`) to `ImagePipe.Transform.Executor`. These support-matrix edits are name-only mention updates, no conformance-axis change. Do NOT touch `docs/superpowers/plans/*` or `docs/superpowers/specs/*` (historical records). Expected end state: the sweep command returns no hits.

- [ ] **Step 5: Verify + commit**

Run: `mise exec -- mix compile --warnings-as-errors && mise exec -- mix test`
Expected: PASS. (Boundary + the architecture test validate the merged module's placement; the full suite re-pins results.)

```bash
git add -A
git commit -m "Collapse PlanExecutor + ResolveDriver into Transform.Executor (#446)"
```

---

### Task 3: Documentation — execution_flow.md, custom_parser_guide.md, AGENTS.md

**Files:**
- Modify: `docs/execution_flow.md`
- Modify: `docs/custom_parser_guide.md`
- Modify: `AGENTS.md` (boundary-guidelines parser bullet)

**Interfaces:** Consumes the exact names from Tasks 1–2 (`Executor.execute/run`, `continue/4`, the five neutral tags, `{:seam, point, entry_dims}`). Produces nothing downstream.

- [ ] **Step 1: Rewrite the affected `docs/execution_flow.md` sections**

- Call-spine box: replace the `PlanExecutor.execute` / `ResolveDriver.run` lines with the single module:

```
      └─ ImagePipe.Transform.execute_plan
         └─ ImagePipe.Transform.Executor.execute
            ├─ seed EXIF orientation (pending, deferred) + input color management
            └─ per pipeline: seed ImagePipe.Transform.SourceShape, fresh strategy state
               └─ Executor.run — the resolve loop                 ← the heart
                  loop over PLAN operations:
                  ├─ overlay shape → State                       (the one sync site)
                  ├─ ImagePipe.Resolver.resolve    ②             → {executable_ops, continuation}
                  ├─ ImagePipe.Transform.Chain.execute  ③        (materialize-if-needed + op.execute)
                  └─ continuation                  ④
                       {:advance, shape, state}      → next plan op
                       {:measure, tag, state}        → measure dims → strategy continue(tag, …), maybe more stages
```

- "The two operation vocabularies": `ResolveDriver.run` mention → `Executor.run`.
- "The resolve loop and continuations": `PlanExecutor` → `Executor` in the seeding sentence; step 4 becomes:

```markdown
4. **Continue.** The continuation is plain data saying how to learn the
   post-op geometry:
   - `{:advance, new_shape, new_state}` — the strategy computed it purely;
     move to the next plan op.
   - `{:measure, tag, state}` — it can't be known without looking (after a
     trim; after a resize whose realized dims may round ±1). The driver
     measures the live image's dimensions and calls the strategy's
     `continue(tag, {w, h}, shape, state)` — `shape` being the pre-op shape
     the strategy resolved against — which returns either the final
     `{shape, state}` or **another** `{ops, continuation}` stage to execute —
     that is how a cover emits its result crop parameterized against the
     *measured* post-resize dims. Recursion depth equals the emission's stage
     count (2 for a cover), never unbounded. Every tag is a named clause in
     the strategy — grep `NeutralResolver.continue` for the full vocabulary
     (`:rotate`, `:trim`, `:resize`, `{:resize_tail, …}`,
     `{:resize_flush_tail, …}`).
```

- "Delegation re-wraps" bullet: replace the closure phrasing — `rewrap/2` "substitutes the carry into the stateless continuation (plain data threading)", and note a dialect's `continue/4` delegates the tag to `NeutralResolver.continue/4` and re-attaches its carry.
- Dispatch table: row ② "defaulting to `NeutralResolver` in `PlanExecutor`" → "…in `Executor`"; row ③ `ResolveDriver` → `Executor`; row ④ becomes:

| # | Call site | What it dispatches to | How to navigate |
|---|---|---|---|
| ④ | `Resolver.continue(strategy, tag, …)` in `Executor` | The strategy's `continue/4` — one named clause per tag | Tags are data: grep the tag atom (e.g. `:resize_flush_tail`) to land on both the emitting resolve row and the continue clause. Neutral tags live in `NeutralResolver.continue/4`; dialect strategies delegate the tag and re-attach their carry |

- Reading order: items 3–4 become `ImagePipe.Transform.Executor.execute_pipeline/4` and `ImagePipe.Transform.Executor.run/5`; add to item 5's NeutralResolver line: "…one `do_resolve/2` clause per plan op, one `continue/4` clause per measure tag."

- [ ] **Step 2: Update `docs/custom_parser_guide.md` resolver section**

- Behaviour snippet (line ~397) gains the callback:

```elixir
@callback init() :: strategy_state
@callback resolve(SourceShape.t(), strategy_state, plan_op :: struct()) ::
            {[executable_op :: struct()], continuation}
@callback continue(tag, measured_dims :: {pos_integer, pos_integer}, SourceShape.t(), strategy_state) ::
            {[executable_op :: struct()], continuation} | {SourceShape.t(), strategy_state}
@callback behavior_version() :: pos_integer()
```

- Execution-model step 2's `:measure` bullet:

```markdown
   - `{:measure, tag, state}` — you can't know the post-op geometry without
     measuring (e.g. after a trim). The driver measures the realized
     dimensions of the live image and calls your `continue(tag, {w, h},
     shape, state)` with the pre-op shape your `resolve/3` saw; it returns
     either the final `{shape, state}` or *another* `{ops, continuation}`
     stage to execute — a staged expansion for multi-step lowering. The tag
     is your private vocabulary: plain data naming what happens after the
     measure, never inspected by the driver.
```

- "Re-wrap the continuation" paragraph: keep the `delegate/3` snippet, replace the closure description ("substitutes the carry through `:advance`, through `:measure`, and through every stage" → "substitutes the carry into the stateless `:advance`/`:measure` data"), and append the imgproxy `continue/4` snippet from Task 1 Step 6 with one sentence: "Delegation has two halves: `resolve/3` re-wraps the returned continuation, and `continue/4` delegates the tag to the neutral resolver and re-attaches the carry (re-wrapping any staged expansion it returns)."
- TwicPics pattern block: append the delegating `continue/4` clause from Task 1 Step 7 to the code sample.
- Strategy-SDK bullet for `ImagePipe.Resolver`: "the behaviour (including `continue/4`), plus `rewrap/2` for carry-preserving delegation."
- Strategy-SDK bullet for `ImagePipe.Transform.NeutralResolver` (line ~511): "the delegate (`resolve/3` and `continue/4`) and its two advance helpers (`display_frame_advance/2`, `plain_advance/2`) for composing your own lowering with the neutral orientation-flush policy."
- "Testing a parser" resolver bullet: "…drive `resolve/3` and `continue/4` directly with `SourceShape` values and assert emitted executables, continuation tags, and carry survival across `:measure` — tags are plain data, so assert on them directly."

- [ ] **Step 3: Update `AGENTS.md`**

In the Boundary-library-guidelines `parser` bullet, change "the per-op resolve dispatch stays quarantined in the `Resolver` facade" → "the per-op resolve/continue dispatch stays quarantined in the `Resolver` facade". (`CLAUDE.md` is a symlink; edit `AGENTS.md`.)

- [ ] **Step 4: Doc checks + commit**

Run: `mise exec -- mix docs 2>&1 | tail -5` (expect success, no broken-ref warnings for the renamed modules) and `rg -n "after_measure|PlanExecutor|ResolveDriver" lib test bench docs AGENTS.md -g '!docs/superpowers/**'` (expect no hits).

```bash
git add -A
git commit -m "Docs: defunctionalized continuations + Executor merge (#446)"
```

---

### Task 4: Final gates and branch finish

- [ ] **Step 1: Full precommit gate**

Run: `mise run precommit`
Expected: format ✓, compile --warnings-as-errors ✓, credo --strict ✓, full test suite ✓ (includes both differential lanes).

- [ ] **Step 2: Final-diff review + finish**

Per the repo's process: one final parallel review of the complete diff (`git diff main...HEAD`), then use superpowers:finishing-a-development-branch — rename the branch (suggest `refactor/defunctionalize-resolver-continuations`) before first push; PR body carries a bare `Fixes #446` line.

---

## Self-Review (done at plan time)

- **Spec coverage:** issue item 1 (defunctionalize) → Task 1; item 2a (merge executor layers) → Task 2; item 2b (chain seam) → resolved as *keep* with recorded rationale (golden ±1 harness); constraints (results-identical, no behavior_version bump, docs, AGENTS.md) → Tasks 1/3 + global constraints. Sequencing constraint (land after the `:measure` rename PR) → satisfied: PR #449 is merged.
- **Placeholder scan:** all code steps carry the actual code; test edits enumerate exact per-test substitutions.
- **Type consistency:** `continue/4` (behaviour) vs `Resolver.continue/5` (facade, takes the strategy tuple) — used consistently in driver Step 5, tests, and docs. Tags `:rotate`/`:trim`/`:resize`/`{:resize_tail, t}`/`{:resize_flush_tail, t}` consistent across Task 1 Steps 4/8 and Task 3. Seam state `{:seam, point, entry_dims}` consistent between point_flow.ex and the TwicPics tests (opaque `seam` binding in tests, so its exact shape is not pinned by tests — deliberate).
