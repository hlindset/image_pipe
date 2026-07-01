# Resolve Stage 1 — Substrate + Orientation Dissolution — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans (recommended — inline, batched at the parity gates) or superpowers:subagent-driven-development. Steps use checkbox (`- [ ]`) syntax for tracking.

> **Revision 2 (2026-07-02), after a four-lens parallel plan review.** Load-bearing changes from revision 1:
> 1. **A single driver-owned `State` overlay** synchronizes the threaded `SourceShape` into the `State` that `Lowering`/`OrientationFlush`/op `execute` still read (rev 1 advanced the shape but never wrote it back — user rotate/flip folds were dropped and the #180 crop clear never reached the next op's lowering).
> 2. **The resolver signature gains a driver-supplied `env` channel (arity-4)**, dissolving rev 1's contradiction between the `{State, ctx}`-as-carry wiring and the facade's carry-threading contract.
> 3. **`Materializer` flips copy-only at the Task 5 cutover** (rev 1 deferred this to an optional Task 9 whose "behavior-equivalent" premise was false). One orientation applier — `%Flush{}` — and nothing else; the trim driver-detect hack and `materialize_without_orientation` disappear.
> 4. **Two missing scheduler clauses are now mapped**: arbitrary-angle/mirrored rotate (explicit `[%Flush{}, rotate]`) and `SetFocus` (via the new generic `%StateUpdate{}` op), plus an explicit no-Flush row for canvas/background/effects.
> 5. **The `Flush` op keeps the `{:materialize_error, _}` tag and the `[:transform, :materialize]` span** (rev 1 silently changed the flush-failure HTTP class and dropped the span; `materialize_span_test.exs` is now updated deliberately).
> 6. **The golden bakes its expected op streams from the OLD pipeline before the cutover** (rev 1 captured from the new pipeline — a self-consistency pin, not a net) and builds its plans through the imgproxy parser on real fixture images.

**Goal:** Introduce `SourceShape`, the `Resolver` behaviour + neutral facade, an injectable dim-acquisition seam, a neutral `Flush` op, and a driver that resolves each plan op through the resolver — replacing `OrientationScheduler`'s fused resolve+execute with resolver-owned op emission (explicit `Flush` at every current flush site, including the formerly implicit orient-at-materialize for arbitrary rotate) — all **results-identical**. imgproxy resolution *math* stays physically in `ResizePlanning`/`Resize`.

**Architecture:** A driver threads a pure `%SourceShape{}` + strategy carry through `Resolver.resolve(spec, shape, env, op)`, which returns `{executable_ops, continuation, spec}`. Continuation is `{:advance, shape, carry}` (pure) or `{:acquire, then_fn}` (driver reads realized dims via an injectable seam, then `then_fn` interprets them, declaring the frame). Three sync rules make this sound while `Lowering`/`Resize.execute`/`OrientationFlush` still read `State`:

1. **The overlay (driver-owned, one site):** before resolving each op the driver writes the shape's geometry into the `State` it hands `env` and `Chain`: `pending_orientation`, `decode_shrink`, and `source_dimensions: {shape.width, shape.height}`. Value-equal to today's mutations whenever the shape advance is correct — which is exactly what the golden + differential prove.
2. **One orientation applier:** `Materializer.materialize/1` becomes copy-only at the cutover; pending orientation is applied by `%Flush{}` and nothing else. Trim (and any `requires_materialization?` op) therefore materializes to the **storage** frame with pending intact automatically — no special-casing.
3. **Non-geometry `State` writes flow through an emitted op:** the generic `%StateUpdate{}` op (pixel-untouched) is the resolver's channel to commit resolved values the shape doesn't carry — `focus` (from `SetFocus`) is the only Stage-1 producer.

**Tech Stack:** Elixir, `Vix.Vips` (libvips), ExUnit, StreamData, `Boundary`. Existing: `ImagePipe.Transform.{PlanExecutor, OrientationScheduler, OrientationFlush, Materializer, Chain, ResizePlanning, Lowering, Geometry, Focus}`, `ImagePipe.Transform.Operation.Resize`, `ImagePipe.Transform.PendingOrientation`.

## Global Constraints

- **Run through mise:** `mise exec -- mix …`. On a `rustler_precompiled` `validate_quote` crash, prefix `env PATH="$(mise where elixir)/bin:$PATH" mix …` (Homebrew Elixir shadow).
- **Results-identical is the contract.** The imgproxy differential bake and imgproxy wire conformance suite MUST stay green after every behavior-adjacent task. No decoded-pixel or decoded-dimension change. One declared, parser-unreachable exception is pinned in the Task 4 rotate row.
- **No cache key/ETag change.** Do not touch `Plan.Key`/`Plan.KeyData`/`Request.HttpCache`. No key data version bump.
- **imgproxy math stays put.** Do NOT modify `ResizePlanning`, `Operation.Resize.resolve_dimensions`, or `Geometry` arithmetic. The neutral resolver *delegates* to them; it never re-derives geometry.
- **No boundary move this stage.** `SourceShape` under `transform`; `ImagePipe.Resolver` is a new top-level boundary, `deps: [ImagePipe.Plan]`. The facade must **not** runtime-reference `SourceShape` (pass the shape opaquely; `SourceShape` appears in `Resolver` only in typespecs, which Boundary ignores — but a `%SourceShape{}` pattern-match in the facade IS caught by Boundary's struct-expansion check, so keep the facade blind). No `transform → parser` edge (no parser-owned strategies yet). *Deliberate pull-forward from spec §9 Stage 2:* the behaviour + facade + `transform → resolver` edge land now because the Stage-1 driver needs the seam; the parser-owned strategy still waits for Stage 2.
- **Error mapping is part of the contract.** A flush failure surfaces as `{:materialize_error, reason}` today (→ decode failure → 415). The `Flush` op and the driver must preserve that tag; `Chain` passes `{:materialize_error, _}` op errors through un-wrapped instead of re-tagging them `{:transform_error, _}` (Task 3).
- **Telemetry: no new event names.** `[:transform, :operation]` gains two new `:operation` values (`:flush`, `:state_update`) — existing event, allowed, no Logger/OTel subscription change. The `[:transform, :materialize]` span's *emission sites* shift (flushes now run inside the `Flush` op's operation span): update `test/image_pipe/telemetry/trace/materialize_span_test.exs` and the relevant `docs/telemetry.md` wording in the same change (Task 5), and confirm `logger_test.exs`/`otel_replay_test.exs` tolerate the new operation values.
- **Gate before finishing:** `mise run precommit` (`format --check-formatted`, `compile --warnings-as-errors`, `credo --strict`, `test`). Remove any dangling untracked `.credo.exs` symlink first.
- **Elixir idioms:** predicates end in `?`; no `String.to_atom/1` on request input; struct field access, not `struct[:field]`.

## Deferred / out of scope (declared)

- **Delivery-boundary materialize backstop: unchanged.** It lives in `Request.Processor.materialize_for_delivery` (processor.ex:299-311) → `Materializer.materialize` — not in `OrientationScheduler` — so Task 8's deletion doesn't touch it, and after the copy-only flip it still forces pixels to RAM (by pipeline end the driver's boundary rule guarantees pending is cleared, so it was already a plain copy). The spec §4.6 re-home to the #262 `:transformed_pixels` tap is deferred to #262.
- **Stage 2 (spec §9):** boundary move of the imgproxy column, strategy behavioral version tags in `plan_material`, focus → TwicPics strategy carry, support-matrix update, closing #434. **Spec delta to fold back into §9 Stage 2's list:** re-signaturing `Lowering`/`ResizePlanning` to shape-based inputs (dims + `decode_shrink` instead of `State`) — that is the actual precondition for retiring the Stage-1 `env.state` channel, and the spec's Stage-2 list currently omits it. Also note for Stage 2: a parser-owned strategy pattern-matching `%SourceShape{}` creates a `parser → transform` struct-expansion edge Boundary **does** check — decide `SourceShape`'s final home (or a `resolver`-owned shape) then.
- **Stage 3 (spec §9):** the optional B-promotion (pure resize advance) and focus read-back retirement.

---

## File Structure

**Create:**
- `lib/image_pipe/transform/source_shape.ex` — pure `%SourceShape{}` + `seed/1` + `quarter_turn?/1`.
- `lib/image_pipe/resolver.ex` — `Resolver` behaviour (`init/0`, `resolve/4`) + facade (`resolve/4`) + `continuation` type. New top-level boundary.
- `lib/image_pipe/transform/operation/flush.ex` — neutral orientation-applying op (`requires_materialization?: false`, self-managing).
- `lib/image_pipe/transform/operation/state_update.ex` — generic pixel-untouched `State`-write op (`fields` merged into `State`; Stage-1 producer: `SetFocus` → `focus`).
- `lib/image_pipe/transform/neutral_resolver.ex` — Stage-1 strategy: emits today's ops + explicit `Flush`/`StateUpdate`, classifies advance/acquire, computes shape advance.
- `lib/image_pipe/transform/resolve_driver.ex` — op-by-op driver + State overlay + injectable acquire seam + ctx recompute + pipeline-boundary flush.
- Tests: `test/image_pipe/transform/{source_shape,resolve_driver,neutral_resolver,resolved_plan_golden}_test.exs`, `test/image_pipe/resolver_test.exs`, `test/image_pipe/transform/operation/{flush,state_update}_test.exs`, `test/support/image_pipe/test/resolved_plan_cases.ex` (with its own `use Boundary, top_level?: true` declaration, matching every other `test/support` module), and a case in `test/image_pipe/transform/sequential_access_test.exs`.

**Modify:**
- `lib/image_pipe/transform/plan_executor.ex` — replace the per-pipeline `execute_operation` reduce with `ResolveDriver.run/…`; keep the preamble (detector/telemetry/EXIF seed/color management) and remove the now-dead `execute_operation`/`run_executable`/`update_execution_context` once the driver subsumes them.
- `lib/image_pipe/transform.ex` — add `ImagePipe.Resolver` to `deps`; export `Operation.Flush`, `Operation.StateUpdate`.
- `lib/image_pipe/transform/materializer.ex` — Task 3: add `flush/1` (span-wrapped orienting flush, `{:materialize_error, _}` tag). Task 5 cutover: `materialize/1` becomes copy-only; delete `materialize_without_orientation/1`.
- `lib/image_pipe/transform/chain.ex` — pass `{:materialize_error, _}` op errors through un-wrapped (Task 3).
- `lib/image_pipe/transform/state.ex` — doc-only: the `source_dimensions` field doc gains the driver-overlay meaning (resolver-tracked logical frame, not only the shrink-on-load original).
- `test/image_pipe/telemetry/trace/materialize_span_test.exs`, `docs/telemetry.md` — Task 5 (span emission-site shift).

**Delete (Task 8, after green):** `lib/image_pipe/transform/orientation_scheduler.ex` (verified: no test file references it; the behavior tests all drive `PlanExecutor.execute/3` and survive as nets). `Materializer.materialize_without_orientation/1` dies earlier, in the Task 5 cutover.

**Do NOT modify:** `ResizePlanning`, `Operation.Resize` internals, `Geometry`, `OrientationFlush` (the `Flush` op delegates to it).

---

## Task 1: `SourceShape` value

**Files:** Create `lib/image_pipe/transform/source_shape.ex`; Test `test/image_pipe/transform/source_shape_test.exs`.

**Interfaces — Produces:**
- `%ImagePipe.Transform.SourceShape{width: pos_integer(), height: pos_integer(), frame: :storage | :display, pending_orientation: PendingOrientation.t() | nil, decode_shrink: %{w: float(), h: float()} | nil}`
- `seed(%{width, height, pending_orientation, decode_shrink}) :: t()` (frame `:storage`).
- `quarter_turn?(t()) :: boolean()` (false when `pending_orientation` nil).

The shape's `width`/`height` are the **logical source-frame dims** — `State.effective_source_dims/1` semantics: the full-resolution original extent while shrink-on-load is live (`decode_shrink` non-nil), the current op-result extent otherwise — in the frame named by `frame:`.

- [ ] **Step 1: Failing test**

```elixir
defmodule ImagePipe.Transform.SourceShapeTest do
  use ExUnit.Case, async: true
  alias ImagePipe.Transform.{PendingOrientation, SourceShape}

  test "seed builds a storage-frame shape" do
    po = PendingOrientation.from_exif(6, true)
    shape = SourceShape.seed(%{width: 4000, height: 3000, pending_orientation: po, decode_shrink: %{w: 2.0, h: 2.0}})
    assert %SourceShape{width: 4000, height: 3000, frame: :storage, pending_orientation: ^po, decode_shrink: %{w: 2.0, h: 2.0}} = shape
  end

  test "quarter_turn? reflects pending, false when nil" do
    q = SourceShape.seed(%{width: 10, height: 10, pending_orientation: PendingOrientation.from_exif(6, true), decode_shrink: nil})
    h = SourceShape.seed(%{width: 10, height: 10, pending_orientation: PendingOrientation.from_exif(3, true), decode_shrink: nil})
    n = SourceShape.seed(%{width: 10, height: 10, pending_orientation: nil, decode_shrink: nil})
    assert SourceShape.quarter_turn?(q)
    refute SourceShape.quarter_turn?(h)
    refute SourceShape.quarter_turn?(n)
  end
end
```

- [ ] **Step 2: Run — fails** `mise exec -- mix test test/image_pipe/transform/source_shape_test.exs` → undefined.
- [ ] **Step 3: Implement**

```elixir
defmodule ImagePipe.Transform.SourceShape do
  @moduledoc false
  # Pure geometry value threaded by the resolve driver (spec §4.3). Subsumes
  # State.source_dimensions/decode_shrink/pending_orientation. Never in telemetry.
  alias ImagePipe.Transform.PendingOrientation

  @enforce_keys [:width, :height, :frame]
  defstruct [:width, :height, :frame, pending_orientation: nil, decode_shrink: nil]

  @type t :: %__MODULE__{
          width: pos_integer(), height: pos_integer(),
          frame: :storage | :display,
          pending_orientation: PendingOrientation.t() | nil,
          decode_shrink: %{w: float(), h: float()} | nil}

  @spec seed(%{width: pos_integer(), height: pos_integer(),
              pending_orientation: PendingOrientation.t() | nil,
              decode_shrink: %{w: float(), h: float()} | nil}) :: t()
  def seed(%{width: w, height: h, pending_orientation: po, decode_shrink: shrink})
      when is_integer(w) and w > 0 and is_integer(h) and h > 0,
      do: %__MODULE__{width: w, height: h, frame: :storage, pending_orientation: po, decode_shrink: shrink}

  @spec quarter_turn?(t()) :: boolean()
  def quarter_turn?(%__MODULE__{pending_orientation: nil}), do: false
  def quarter_turn?(%__MODULE__{pending_orientation: po}), do: PendingOrientation.quarter_turn?(po)
end
```

- [ ] **Step 4: Run — passes** (2 tests).
- [ ] **Step 5: Commit** `feat(transform): add SourceShape virtual-buffer value`

---

## Task 2: `Resolver` behaviour + opaque facade (arity-4: shape, env, carry, op)

**Files:** Create `lib/image_pipe/resolver.ex`; Modify `lib/image_pipe/transform.ex` (deps); Test `test/image_pipe/resolver_test.exs`.

**Interfaces — Produces:**
- `@type Resolver.spec :: {module(), strategy_state :: term()}`
- `@type Resolver.env :: term()` — an opaque, driver-supplied per-op channel for whatever the strategy needs beyond the shape and its own carry. Stage 1: `%{state: State.t(), ctx: map()}` so the neutral resolver can call `Lowering`. It is **not** threaded — the driver rebuilds it every op; only `strategy_state` threads.
- `@type continuation :: {:advance, SourceShape.t(), term()} | {:acquire, ({pos_integer(), pos_integer()} -> {SourceShape.t(), term()})}`
- `@callback init() :: term()`; `@callback resolve(SourceShape.t(), env(), strategy_state :: term(), struct()) :: {[struct()], continuation(), term()}`
- Facade `Resolver.resolve(spec, shape, env, op) :: {[struct()], continuation(), spec}` — dispatches to the carried module; **does not pattern-match `%SourceShape{}`** (passes `shape` and `env` opaquely) so `Resolver` needs no `transform` dep.

> **Note (deliberate divergence from spec §4.2):** the spec's `resolve(spec, shape, strategy_state, op)` assumed resolution needs nothing but the shape and the carry. Stage 1 (and Stage 2, until `Lowering` is re-signatured to shape-based inputs) needs a lowering context, so the signature gains the separate `env` argument rather than smuggling `{State, ctx}` through `strategy_state` — that keeps the carry honest (the neutral strategy's carry is `nil`) and the facade's threading contract real. Don't "correct" it back.

- [ ] **Step 1: Failing test**

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
    def resolve(%SourceShape{} = shape, env, %{n: n}, op),
      do: {[{:emitted, op, env}], {:advance, shape, %{n: n + 1}}, %{n: n + 1}}
  end

  test "facade dispatches, passes env opaquely, threads strategy_state via the spec" do
    shape = SourceShape.seed(%{width: 10, height: 10, pending_orientation: nil, decode_shrink: nil})
    {ops, cont, {Dummy, st}} = Resolver.resolve({Dummy, Dummy.init()}, shape, :env_token, :op)
    assert ops == [{:emitted, :op, :env_token}]
    assert {:advance, ^shape, %{n: 1}} = cont
    assert st == %{n: 1}
  end
end
```

- [ ] **Step 2: Run — fails** → undefined.
- [ ] **Step 3: Implement**

```elixir
defmodule ImagePipe.Resolver do
  @moduledoc """
  Neutral behaviour + dispatch facade for geometry resolution (spec §4.2/§5.1).
  A plan carries a strategy `spec` (`{module, strategy_state}`); the driver calls
  `resolve/4`; the dynamic call to the carried module is quarantined here (mirrors
  `ImagePipe.Renderer`). `env` is an opaque, driver-supplied per-op channel (not
  threaded); `strategy_state` is the strategy's own threaded carry. The facade
  passes shape and env opaquely — no runtime reference to `SourceShape` — so this
  boundary stays `deps: [ImagePipe.Plan]`.
  """
  use Boundary, top_level?: true, deps: [ImagePipe.Plan], exports: []

  alias ImagePipe.Transform.SourceShape

  @type strategy_state :: term()
  @type env :: term()
  @type spec :: {module(), strategy_state()}
  @type continuation ::
          {:advance, SourceShape.t(), strategy_state()}
          | {:acquire, ({pos_integer(), pos_integer()} -> {SourceShape.t(), strategy_state()})}

  @callback init() :: strategy_state()
  @callback resolve(SourceShape.t(), env(), strategy_state(), struct()) ::
              {[struct()], continuation(), strategy_state()}

  @spec resolve(spec(), shape :: term(), env(), struct()) :: {[struct()], continuation(), spec()}
  def resolve({module, strategy_state}, shape, env, op) do
    {ops, cont, next} = module.resolve(shape, env, strategy_state, op)
    {ops, cont, {module, next}}
  end
end
```

Add to `lib/image_pipe/transform.ex`: `deps: [ImagePipe.Plan, ImagePipe.Telemetry, ImagePipe.Resolver]` and `exports: [..., Operation.Flush, Operation.StateUpdate]` (ops added in Task 3).

- [ ] **Step 4: Run test + `mise exec -- mix compile --warnings-as-errors`** — pass, no Boundary violation (confirm no `resolver → transform` edge; if reported, the facade is still matching the struct somewhere — remove it. Boundary ignores typespec references but **does** check struct expansion).
- [ ] **Step 5: Commit** `feat(resolver): add neutral Resolver behaviour + opaque facade`

---

## Task 3: Neutral `Flush` + `StateUpdate` ops

**Files:** Create `lib/image_pipe/transform/operation/flush.ex`, `lib/image_pipe/transform/operation/state_update.ex`; Modify `lib/image_pipe/transform/materializer.ex` (add `flush/1`), `lib/image_pipe/transform/chain.ex` (error pass-through); Tests `test/image_pipe/transform/operation/flush_test.exs`, `test/image_pipe/transform/operation/state_update_test.exs` + a case in `sequential_access_test.exs`.

**Interfaces — Produces:**
- `%ImagePipe.Transform.Operation.Flush{}` implementing `ImagePipe.Transform`; `name/1 -> :flush`; `requires_materialization?/1 -> false` (self-managing); `execute/2` delegates to the new `Materializer.flush/1`.
- `Materializer.flush(State.t()) :: {:ok, State.t()} | {:error, {:materialize_error, term()}}` — wraps `OrientationFlush.flush/1` in the same `[:transform, :materialize]` span `materialize/1` uses, and tags failures `{:materialize_error, reason}` (preserving today's decode-failure → 415 mapping from `flush_if_pending`, orientation_scheduler.ex:49-52).
- `Chain`: an op returning `{:error, {:materialize_error, _} = err}` halts with `err` un-wrapped (a clause next to the existing `maybe_materialize` error path) instead of being re-tagged `{:transform_error, _}`.
- `%ImagePipe.Transform.Operation.StateUpdate{fields: %{optional(atom()) => term()}}`; `name/1 -> :state_update`; `requires_materialization?/1 -> false`; `execute/2` returns `{:ok, struct!(state, fields)}` — the image is untouched. The generic channel for a resolver to commit non-geometry `State` writes; the only Stage-1 producer is the `SetFocus` row (Task 4) writing `:focus`.

> **Why `Flush` is `requires_materialization?: false`:** `OrientationFlush.flush/1` already does `prepare_random_access` + `copy_memory` internally (orientation_flush.ex:15-26, 58-64). If `Flush` were `requires_materialization?: true`, `Chain` would pre-materialize first — before the Task 5 flip that pre-materialize *orients* (a wasted duplicate copy at best), and after the flip it is a pointless extra copy. Self-managing is right in both worlds.

- [ ] **Step 1: Failing tests**

```elixir
defmodule ImagePipe.Transform.Operation.FlushTest do
  use ExUnit.Case, async: true
  alias ImagePipe.Transform.Operation.Flush
  alias ImagePipe.Transform.{PendingOrientation, State}

  test "quarter-turn flush swaps dims and clears pending" do
    {:ok, img} = Image.new(40, 30)
    state = %State{image: img, pending_orientation: %PendingOrientation{user_angle: 90}}
    {:ok, %State{image: out, pending_orientation: nil, materialized?: true}} = Flush.execute(%Flush{}, state)
    assert Image.width(out) == 30 and Image.height(out) == 40
  end

  test "nil pending is a plain copy, dims unchanged" do
    {:ok, img} = Image.new(40, 30)
    {:ok, %State{image: out}} = Flush.execute(%Flush{}, %State{image: img, pending_orientation: nil})
    assert Image.width(out) == 40 and Image.height(out) == 30
  end

  test "requires_materialization? is false (self-managing)" do
    refute Flush.requires_materialization?(%Flush{})
  end
end

defmodule ImagePipe.Transform.Operation.StateUpdateTest do
  use ExUnit.Case, async: true
  alias ImagePipe.Transform.Operation.StateUpdate
  alias ImagePipe.Transform.State

  test "merges fields into State without touching the image" do
    {:ok, img} = Image.new(4, 4)
    state = %State{image: img}
    {:ok, %State{focus: {:fp, 0.25, 0.75}, image: ^img}} =
      StateUpdate.execute(%StateUpdate{fields: %{focus: {:fp, 0.25, 0.75}}}, state)
  end

  test "requires_materialization? is false" do
    refute StateUpdate.requires_materialization?(%StateUpdate{fields: %{}})
  end
end
```

- [ ] **Step 2: Run — fails** → undefined.
- [ ] **Step 3: Implement** both ops (each `use ImagePipe.Transform`; `Flush.execute` → `Materializer.flush(state)`), `Materializer.flush/1` (span + `OrientationFlush.flush` + `{:materialize_error, _}` tag), and the `Chain` `{:materialize_error, _}` pass-through clause. Assert the tag via a `Flush.execute` typespec/clause and the `Chain` clause's unit coverage in `chain` tests if one exists; forcing a real `copy_memory` failure in a unit test is not required.
- [ ] **Step 4: Run tests + sequential-safety gate.** Add to `sequential_access_test.exs` a case proving `Flush` on a genuinely streamed-open source (`access: :sequential`, `fail_on: :error`) is pixel-equivalent to random access for a quarter turn. (The **identity-streaming** guarantee — identity pending emits no `Flush` and triggers no materialization — is a *resolver/driver* property, not a `Flush`-op property: executing `%Flush{}` always copies. It is asserted in Task 4 Step 1 (no `%Flush{}` emitted for identity pending) and Task 6 (a streaming pipeline under identity pending ends `materialized?: false`).) Run `mise exec -- mix test test/image_pipe/transform/operation test/image_pipe/transform/sequential_access_test.exs` → pass.
- [ ] **Step 5: Commit** `feat(transform): add neutral Flush + StateUpdate ops (Materializer.flush, error-tag parity)`

---

## Task 4: `NeutralResolver` — emit today's ops + explicit `Flush`, classify advance/acquire

**Files:** Create `lib/image_pipe/transform/neutral_resolver.ex`; Test `test/image_pipe/transform/neutral_resolver_test.exs`.

**Interfaces — Consumes:** `Lowering.executable_operations/3`, `ResizePlanning` (via Lowering + its public compensate/display-frame helpers), `SourceShape`, `PendingOrientation`, `Focus`, and the driver-built `env = %{state: State.t(), ctx: map()}`. **Produces:** `NeutralResolver` implementing `ImagePipe.Resolver`; `init/0 -> nil` (the neutral carry is genuinely `nil`; everything situational arrives via `env`).

**Contract this task must satisfy (the parity core):** `resolve(shape, env, nil, op)` returns `{ops, continuation, nil}` where `ops` is byte-identical to what today's `PlanExecutor`/`OrientationScheduler` run for the same op and state, **except** every `flush_if_pending` call — and the one *implicit* orient-at-materialize (arbitrary rotate) — becomes an explicit `%Flush{}` in `ops` at the right position, and every zero-op `State` write becomes either a shape advance (geometry) or an emitted `%StateUpdate{}` (non-geometry).

**Classification (`:acquire` iff the post-op dims cannot be computed purely):**
- `:acquire`: `%PlanResize{}`; `%PlanTrim{}`; `%PlanRotate{}` with `angle not in [0, 90, 180, 270] or mirror == true`.
- `:advance`: everything else. Right-angle non-mirrored rotate and flip fold into `pending_orientation` and emit **zero** ops: `{[], {:advance, %{shape | pending_orientation: folded}, nil}, nil}` (scheduler:60-64, 73-76).

**General rules (apply to every row):**

- **R1 — lowering frame.** The resolver lowers via `Lowering.executable_operations(op, lowering_state, ctx)` where `lowering_state` starts from `env.state` (already overlaid from the shape by the driver, Task 5). For **flush-before** rows, rebuild it from the **post-Flush shape** (dims swapped if quarter turn, `pending_orientation: nil`, per-row shrink) so lowering — including `reject_region_out_of_bounds?` (lowering.ex:223-229) — sees the display frame exactly as today's post-flush lowering does. Declaring the lowering frame is the resolver's job; getting it wrong is the #182 class.
- **R2 — crop bookkeeping.** The #185 per-axis `decode_shrink` quarter-turn swap (`orient_decode_shrink`) is applied when building the *lowering input* for crops under a quarter-turn pending. The #180 clear applies to **all** crops — region, gravity, smart/detect, with or without pending (scheduler:100-110, 245-246) — as the shape advance: `dims = crop result box, decode_shrink: nil`. (Today's transient-vs-persisted distinction between the gravity and region clauses is behaviorally inert past lowering — the load-bearing persisted piece is `pending_orientation: nil`, which the explicit `%Flush{}` now owns on `State`.)
- **R3 — identity pending.** Never emit `%Flush{}`. At the first would-be flush site, clear `pending_orientation` on the shape (the driver overlay propagates the clear to `State`; the driver's boundary rule clears any survivor). Emit today's plain ops. This is the streaming fast path (scheduler:45-47).
- **R4 — SetFocus.** Resolve the operand exactly as scheduler:83-91 does — `ResizePlanning.display_live_dims(env.state)`, live storage dims off `env.state.image`, `env.state.decode_shrink`, `Focus.resolve(operand, focus_ctx, shape.pending_orientation)` — and emit `[%StateUpdate{fields: %{focus: resolved}}]`, `:advance`, shape unchanged. *Declared Stage-1 live-image read:* `display_live_dims` reads the real decoded frame, which the shape cannot supply; this row is TwicPics-only, is not in the imgproxy golden matrix, and moves into the TwicPics strategy carry in Stage 2 (spec §4.4).
- **R5 — no-clause ops.** Canvas, Background, Blur, Sharpen, Brightness, Contrast, Saturation, Colorize, Monochrome, Duotone, Gray, Bitonal have **no scheduler clause today — absence is the behavior** (plan_executor.ex:174-176): they run plain, in the **storage frame**, with pending intact, and never trigger a flush. Emit today's ops, never a `%Flush{}`, `:advance` (canvas/padding-class ops advance dims exactly per their geometry in the shape's current frame; effects are dimension-neutral). Do not "fix" this toward the spec's display-frame rationale — that would be a pixel change for rotate+canvas-without-resize plans.

**Flush-position map (from `orientation_scheduler.ex`, preserve exactly; rows are the pending-non-identity behavior — R3 covers identity):**

| Op | Emitted ops | Continuation / shape advance |
|---|---|---|
| region crop | `[%Flush{}, crop…]` (flush before; lower per R1 against post-Flush shape) | `:advance` — frame `:display`, dims = crop box, `decode_shrink: nil` (R2) |
| gravity crop (non-smart) | `[compensated_crop…]` — crop pre-flush in the **storage** frame; **no** trailing `%Flush{}` (today's flush fires at the next flushing op or the pipeline boundary — preserve "crop then later flush") | `:advance` — frame `:storage`, pending **kept**, dims = crop box, `decode_shrink: nil` (R2; #185 swap feeds only the lowering input, scheduler:298-305) |
| smart/detect crop | `[%Flush{}, literal_crop]` (flush before; crop sees display pixels, emitted literal/uncompensated) | `:advance` — frame `:display`, pending nil, `decode_shrink: nil` |
| padding / pixelate / gradient | `[%Flush{}, op…]` (three distinct scheduler clauses with identical shape, scheduler:177-211) | `:advance` — frame `:display`, pending nil |
| resize (quarter-turn cover) | `[forcing_resize, compensated_crop, %Flush{}]` (scheduler:134-151) | `:acquire` → then_fn: frame `:display`, pending nil, `decode_shrink: nil` |
| resize (other) | `[compensated_resize, maybe_crop, %Flush{}]` (scheduler:153-163) | `:acquire` → then_fn: frame `:display`, pending nil, `decode_shrink: nil` |
| trim | `[trim]` — **no** `%Flush{}`; after the Task 5 flip, `requires_materialization?` + copy-only materialize trims the **storage** frame with pending intact, no special routing | `:acquire` → then_fn: frame `:storage`, pending **kept**, `decode_shrink: nil` (never-shrank reaffirmation — decode_planner returns 1.0 for trim chains) |
| **arbitrary-angle / mirrored rotate** | `[%Flush{}, rotate]` — **new row**: today's *implicit* orient-at-materialize (scheduler:69-71 comment; rotate.ex `requires_materialization?: true`) made explicit, per spec §4.6's same treatment of smart/detect | `:acquire` → then_fn: frame `:display`, pending nil, `decode_shrink` **unchanged** (nothing clears it at rotate today; no parser places a shrink consumer after rotation — IIIF rotation is last) |
| SetFocus | `[%StateUpdate{fields: %{focus: …}}]` (R4) | `:advance` — shape unchanged |
| canvas / background / effects | today's plain ops, no `%Flush{}` (R5) | `:advance` — dims per op geometry, frame/pending unchanged |

> **Pinned divergence (rotate row):** a pipeline containing *both* a trim and an arbitrary rotate would today rotate **un-oriented** pixels (trim's materialize sets `materialized?: true`, so Chain skips the orienting materialize at the rotate — chain.ex:89); the new row always flushes first. No parser can produce that pipeline (imgproxy `rot` is right-angle-only; IIIF has no trim; confirm TwicPics at port time — if a real producer exists, that combination's differential fixture gates this row instead). Per the greenfield guidelines we define, rather than preserve, parser-unreachable behavior. Every parser-reachable pipeline is pixel-identical: flush-then-rotate ≡ orient-at-materialize-then-rotate.

> **Parity-gated refactor task.** Reproduce each `orientation_scheduler.ex` clause per the rules and map above. Delegate all geometry to `Lowering`/`ResizePlanning` public helpers (`compensate_*`, display-frame helpers); re-derive nothing. Acceptance = Task 5's differential/wire gate + Task 6 golden + this task's unit tests.

- [ ] **Step 1: Failing unit tests** — assert continuation *tags*, emitted-op shapes, and the identity fast path (extend as clauses are ported):

```elixir
defmodule ImagePipe.Transform.NeutralResolverTest do
  use ExUnit.Case, async: true
  alias ImagePipe.Transform.{NeutralResolver, PendingOrientation, SourceShape, State}
  alias ImagePipe.Plan.Operation.{Blur, Padding, Trim}

  setup do
    {:ok, img} = Image.new(100, 80)
    shape = SourceShape.seed(%{width: 100, height: 80, pending_orientation: nil, decode_shrink: nil})
    env = %{state: %State{image: img}, ctx: %{effective_padding_scale: nil, canvas_preserving_padding_scale: nil}}
    %{env: env, shape: shape}
  end

  test "trim → :acquire, pending kept, storage frame, no Flush", %{shape: s, env: e} do
    {ops, {:acquire, then_fn}, nil} =
      NeutralResolver.resolve(s, e, nil, %Trim{threshold: 10, background: :auto, equal_hor: false, equal_ver: false})
    assert [%ImagePipe.Transform.Operation.Trim{}] = ops
    {shape2, nil} = then_fn.({90, 70})
    assert shape2.frame == :storage and shape2.width == 90
  end

  test "effect (blur) → :advance, dims unchanged, no Flush", %{shape: s, env: e} do
    {ops, {:advance, %SourceShape{width: 100, height: 80}, nil}, nil} =
      NeutralResolver.resolve(s, e, nil, %Blur{sigma: 1.0})
    assert [%ImagePipe.Transform.Operation.Blur{}] = ops
  end

  test "identity pending: no Flush emitted, pending cleared on the shape", %{env: e} do
    identity = PendingOrientation.from_exif(1, true)
    s = SourceShape.seed(%{width: 100, height: 80, pending_orientation: identity, decode_shrink: nil})
    {ops, {:advance, shape2, nil}, nil} = NeutralResolver.resolve(s, e, nil, %Padding{top: 2, right: 2, bottom: 2, left: 2})
    refute Enum.any?(ops, &match?(%ImagePipe.Transform.Operation.Flush{}, &1))
    assert shape2.pending_orientation == nil
  end
end
```

(Adjust the `%Padding{}` literal to the real struct's enforce-keys at port time; the assertion shape is the point.)

- [ ] **Step 2: Run — fails** → undefined.
- [ ] **Step 3: Implement `NeutralResolver`**, porting clauses per the rules + map. Structure: `resolve/4` → `classify(op)` → per-family `emit_*` building `{ops, continuation, nil}`. Delegate op-building to `Lowering.executable_operations(op, lowering_state, ctx)` with `lowering_state` built per R1/R2; call the existing public helpers on `ResizePlanning` — do not copy their bodies. Emit `%Flush{}`/`%StateUpdate{}` per the map.
- [ ] **Step 4: Run unit tests** → pass. (Full parity is proven in Task 5/6.)
- [ ] **Step 5: Commit** `feat(transform): add NeutralResolver emitting explicit Flush/StateUpdate (parity)`

---

## Task 5: `ResolveDriver` + State overlay + acquire seam; flip `Materializer`; wire `PlanExecutor`; prove results-identical

**Files:** Create `lib/image_pipe/transform/resolve_driver.ex`; Modify `lib/image_pipe/transform/plan_executor.ex`, `lib/image_pipe/transform/materializer.ex` (the flip), `lib/image_pipe/transform/state.ex` (doc), `test/image_pipe/telemetry/trace/materialize_span_test.exs`, `docs/telemetry.md`; Tests `resolve_driver_test.exs` + the parity gate.

**Interfaces — Produces:**
- `ResolveDriver.run(pipeline :: [struct()], SourceShape.t(), Resolver.spec(), State.t(), opts :: keyword()) :: {:ok, State.t()} | {:error, term()}`
- Seam: `opts[:acquire_dims]`, a fun `(Vix.Vips.Image.t() -> {pos_integer(), pos_integer()})`, default `&{Image.width(&1), Image.height(&1)}`.
- Capture seam for the golden: `opts[:chain]`, default `&Chain.execute/3`.

**The driver loop, per op — order matters:**

1. **Overlay (THE sync rule, one site):** `state = %State{state | pending_orientation: shape.pending_orientation, decode_shrink: shape.decode_shrink, source_dimensions: {shape.width, shape.height}}`. This is what routes every `State.effective_source_dims`/`decode_shrink`/pending read — `Lowering`, `ResizePlanning`, `Resize.execute` at pixel time (resize.ex:84), `OrientationFlush.flush` — through the resolver-advanced shape. It is value-equal to today's scattered mutations whenever the shape advance is correct (the golden + differential prove exactly that). Update the `source_dimensions` field doc in `state.ex` to name this second meaning. **Audit note:** `decode_shrink` is the only nil-as-flag field lowering branches on, and the overlay carries it faithfully; no in-repo reader treats `source_dimensions`-nil itself as a flag (verified against lowering.ex/resize.ex/state.ex — re-verify at port if new readers appeared).
2. **ctx recompute:** exactly today's `PlanExecutor.update_execution_context/3` (plan_executor.ex:184-197 — the two padding scales computed at `%PlanResize{}` from the **pre-op** overlaid state). Ported into the driver; the executor's copy is deleted at Step 6.
3. `env = %{state: state, ctx: ctx}`; `{ops, cont, spec} = Resolver.resolve(spec, shape, env, op)`.
4. `opts[:chain].(state, ops, opts)` (default `Chain.execute/3`). `%Flush{}` clears pending on `State` mid-list; `%StateUpdate{}` merges its fields; trim/rotate materialize copy-only via `requires_materialization?`.
5. Advance: `{:advance, shape2, _}` → continue; `{:acquire, then_fn}` → `then_fn.(opts[:acquire_dims].(state.image))` on the **post-execution** image.
6. **Pipeline boundary:** if `shape.pending_orientation` is non-identity → `opts[:chain].(state, [%Flush{}], opts)`; if identity → clear it on `State` **without materializing** (parity with `flush_if_pending`'s identity clause, scheduler:45-47 — keeps the streaming path streaming and the delivery backstop on its plain-copy branch).

**The `Materializer` flip (same commit as the wire, Step 6):** `materialize/1` becomes copy-only (the `[:transform, :materialize]` span stays; `do_materialize` stops calling `OrientationFlush.flush` and just `copy_memory`s); delete `materialize_without_orientation/1` and route trim through the plain `requires_materialization?` path — no driver-detect. **Precondition, guaranteed by the Task 4 map:** no op ever reaches a materialize with a non-identity pending that an emitted `%Flush{}` hasn't already cleared — smart/detect crop and arbitrary/mirror rotate get flush-before rows; trim *deliberately* materializes pre-orientation (storage frame), which is now the plain behavior of a copy-only materialize. One consequence to note in the commit: an identity pending now survives on `State` slightly longer (until the boundary clear) than today's clear-at-materialize — nothing branches on identity pending between those points (quarter-turn/vertical checks are all false for identity).

**Telemetry/error updates (this commit, per the Global Constraint):** `materialize_span_test.exs` — "mid-chain materializing op yields a materialize span nested under an operation" and "pipeline-boundary EXIF flush nests the materialize span under [:transform, :execute]" change shape: the flush's materialize span now nests under the `%Flush{}` op's `[:transform, :operation]` span (which itself sits where the old span sat); the "delivery backstop" test is unchanged. Update `docs/telemetry.md`'s materialize-span wording, and run `logger_test.exs` + `otel_replay_test.exs` to confirm the new `:flush`/`:state_update` operation values render/capture through the existing generic paths.

- [ ] **Step 1: Failing driver test (non-tautological — asserts the seam and the overlay)**

```elixir
defmodule ImagePipe.Transform.ResolveDriverTest do
  use ExUnit.Case, async: true
  alias ImagePipe.Transform.{ResolveDriver, SourceShape, State}

  defmodule Probe do
    @behaviour ImagePipe.Resolver
    @impl true
    def init, do: nil
    @impl true
    def resolve(%SourceShape{} = shape, env, agent, :pure) do
      Agent.update(agent, &[{:env_dims, env.state.source_dimensions} | &1])
      {[], {:advance, %{shape | width: shape.width + 1}, agent}, agent}
    end

    def resolve(%SourceShape{} = shape, _env, agent, :opaque) do
      then_fn = fn {w, h} ->
        Agent.update(agent, &[{:acquired, w, h} | &1])
        {%{shape | width: w, height: h}, agent}
      end
      {[], {:acquire, then_fn}, agent}
    end
  end

  test "acquire uses injected dims; advance is pure; overlay feeds env from the shape" do
    {:ok, img} = Image.new(10, 10)
    agent = start_supervised!({Agent, fn -> [] end})
    shape = SourceShape.seed(%{width: 10, height: 10, pending_orientation: nil, decode_shrink: nil})

    {:ok, %State{}} =
      ResolveDriver.run([:pure, :opaque, :pure], shape, {Probe, agent}, %State{image: img},
        acquire_dims: fn _ -> {77, 66} end)

    assert Agent.get(agent, &Enum.reverse/1) ==
             [{:env_dims, {10, 10}}, {:acquired, 77, 66}, {:env_dims, {77, 66}}]
  end
end
```

(The final `{:env_dims, {77, 66}}` is the load-bearing assertion: the third op's `env.state` must carry the *acquired* dims via the overlay, not the live blank image's.)

- [ ] **Step 2: Run — fails** → undefined.
- [ ] **Step 3: Implement `ResolveDriver`** per the loop above.
- [ ] **Step 4: Run driver unit test** → pass.
- [ ] **Step 5: Baseline + record (green before wiring).** Run `mise exec -- mix test test/image_pipe/imgproxy_wire_conformance_test.exs` and the differential lane (default `mix test` lane, per `test/support/image_pipe/test/imgproxy_differential/README.md`); record counts. **Then bake the golden's expected data from the OLD pipeline:** a small recorder harness (in `test/support/image_pipe/test/resolved_plan_cases.ex`) attaches a telemetry handler to `[:transform, :operation]` (whose metadata already carries the full executable op struct under `:params`, chain.ex:67) and `[:transform, :materialize]` (flush positions), runs today's `PlanExecutor.execute/3` over the Task 6 case matrix — plans parsed from real imgproxy URLs, real fixture images from the existing differential sources — and records, per case, the executed op sequence **and each op's realized post-op dims** (to feed the injection later). Commit the recordings as the `expected` data. Use a unique `telemetry_prefix` per the test guidelines.
- [ ] **Step 6: Wire `PlanExecutor.execute_pipeline/3` + flip `Materializer`** (one commit):

```elixir
defp execute_pipeline(%Pipeline{operations: operations}, %State{} = state, opts) do
  {w, h} = State.effective_source_dims(state)
  shape = SourceShape.seed(%{width: w, height: h, pending_orientation: state.pending_orientation, decode_shrink: state.decode_shrink})
  ResolveDriver.run(operations, shape, {NeutralResolver, NeutralResolver.init()}, state, opts)
end
```

Remove `PlanExecutor.execute_operation/*`, `run_executable/*`, `update_execution_context/*` (moved into the driver). Keep the `execute/3` preamble and the EXIF seed. Flip `Materializer.materialize/1` copy-only; delete `materialize_without_orientation/1`. Update `materialize_span_test.exs` + `docs/telemetry.md` per the note above.

- [ ] **Step 7: Run the full parity gate** — wire + differential + `mise exec -- mix test test/image_pipe/transform test/image_pipe/telemetry`. Must equal Step 5 counts. Any diff → bisect to the offending row in `NeutralResolver` (Task 4) and fix against the scheduler clause verbatim.
- [ ] **Step 8: Full suite + gate** — `mise exec -- mix test` (covers the TwicPics/IIIF paths — SetFocus, arbitrary rotate — that the imgproxy gates miss) and `mise run precommit`.
- [ ] **Step 9: Commit** `refactor(transform): drive execution via ResolveDriver + explicit Flush; Materializer copy-only (results-identical)`

---

## Task 6: ResolvedPlan golden (old-path-baked, injection-driven)

**Files:** Extend `test/support/image_pipe/test/resolved_plan_cases.ex` (created in Task 5 Step 5; carries its own `use Boundary, top_level?: true, deps: […]` like every other test-support module); Create `test/image_pipe/transform/resolved_plan_golden_test.exs`.

**Design:** each case = an imgproxy URL (parsed through the real imgproxy parser — no hand-built plan structs, per the test guidelines) + a fixture image drawn from the **existing** differential sources (reusing a source needs no `SourceInventory` change; adding one does — avoid it). `expected` = the op sequence + per-op realized dims recorded from the **old** pipeline in Task 5 Step 5 — so the golden is a genuine cross-implementation net, not a self-consistency pin. The test runs `ResolveDriver` with a **capturing chain** (`opts[:chain]` appends emitted ops to a `start_supervised!` Agent; pixels never run) and `acquire_dims` injecting the **recorded** realized dims per `:acquire`, then asserts recorded ops == `expected`. The Task 5 overlay is what makes this sound: lowering reads flow through the shape-fed `source_dimensions`/`decode_shrink`, so multi-op cases resolve against injected dims, not the stale blank/live image. (The golden cannot cover a row whose lowering reads the live image directly — that is only the SetFocus row, which is TwicPics-only and excluded from this imgproxy matrix by construction.)

**Case matrix (min):** plain fit; cover+result-crop; `auto` landscape→cover; `auto` portrait→fit; `min_width` coupling (#236); no-enlarge `dpr` cap, no geometry (#237); quarter-turn cover (#182) — assert the emitted list **includes the trailing `%Flush{}`** and the display-frame result box; shrink-on-load rescaled crop (#151) — the multi-op overlay proof; **trim under a pending quarter turn** (EXIF 6, real fixture with trimmable content) — assert storage-frame trim, `%Flush{}` NOT before trim, pending kept; **`fill_down`** (cover `down: true`, un-upscaled smaller than box) asymmetric crop; **resize → trim → padding** — proves the padding still resolves from the resize-stashed ctx scales across an intervening `:acquire` (spec §8's carry-threading case, in ctx form this stage); **identity-pending streaming** — EXIF orientation 1: assert no `%Flush{}` recorded anywhere AND a real (non-capturing) driver run of the same case ends `materialized?: false` (spec §8's streaming guard — a regression that always flushes fails here); **±1 divergence** — a resize followed by a percent/`min_*` consumer: inject `recorded_realized - 1` at the resize, assert the downstream box equals the integers hand-derived from `recorded_realized - 1` via the imgproxy math (`prepare.go`/`scale.go` — committed integers, not "sane"). This case documents that downstream consumers follow the *acquired* dims — the edge you cannot force against real libvips.

- [ ] **Step 1:** Golden test iterating cases: capturing-chain run + injected `acquire_dims` from recordings, assert recorded ops == `expected`. Run — red only if Task 5 introduced drift the wire/differential missed; otherwise green immediately (the recordings were baked pre-cutover — green *is* the finding).
- [ ] **Step 2:** Add the ±1 and identity-streaming cases (these are new assertions, not recordings). Cross-check the #182 and #236 expected boxes against imgproxy `prepare.go`/`scale.go` cited in the spec.
- [ ] **Step 3:** Run golden → pass. `mise exec -- mix test test/image_pipe/transform/resolved_plan_golden_test.exs`.
- [ ] **Step 4: Commit** `test(transform): old-path-baked ResolvedPlan golden (incl. trim+pending, fill_down, ±1, streaming guard)`

---

## Task 7: §4.7 narrowing gate (explicit enumerating test)

**Files:** Add to `neutral_resolver_test.exs`.

- [ ] **Step 1:** For a representative instance of **every** `Plan.Operation.*` variant, assert `NeutralResolver.resolve/4`'s continuation tag is `:acquire` iff the op is `%Trim{}` / `%Rotate{}` with `angle not in [0, 90, 180, 270] or mirror == true` / `%Resize{}`, else `:advance`. Include **both** rotate literals — `%Rotate{angle: 90, mirror: false}` (`:advance`, folds) and `%Rotate{angle: 90, mirror: true}` (`:acquire` — mirrored right-angle does **not** fold today, scheduler:60-64; pinned by `sequential_access_test.exs:197`). (Defining `classify/1` is not proving it — this enumeration is the gate, spec §8/§9; it pins the driver's core contract against drift.)
- [ ] **Step 2:** Run → pass. **Commit** `test(transform): gate the :acquire/:advance narrowing across all ops`

---

## Task 8: Retire `OrientationScheduler`

**Files:** Delete `lib/image_pipe/transform/orientation_scheduler.ex`; remove its references.

- [ ] **Step 1:** `mise exec -- grep -rn "OrientationScheduler" lib test` → confirm the only references are the module itself (+ any leftover alias in `plan_executor.ex`). Verified at plan time: **no test file references it** — the orientation behavior tests (`deferred_orientation_test.exs`, `deferred_orientation_frame_test.exs`, `focus_test.exs`, `resize_dimension_test.exs`, `plan_executor_test.exs`) all drive `PlanExecutor.execute/3` and survive as nets. If the neutral resolver still *calls* scheduler helpers, inline or move those helpers; do not leave a half-dead scheduler.
- [ ] **Step 2:** Delete the module + dead refs. Run `mise exec -- mix test` + `mise run precommit` → green.
- [ ] **Step 3: Commit** `refactor(transform): remove OrientationScheduler (subsumed by resolver)`

---

## Self-Review

- **Spec coverage (merged §9 Stage 1):** SourceShape (T1) ✓; Resolver behaviour+facade, opaque, `transform→resolver` dep (T2, declared pull-forward) ✓; two-variant continuation (T2/T4/T5) ✓; injectable acquire seam (T5) ✓; neutral `Flush`, self-managing, error-tag + span parity, sequential-safety (T3/T5) ✓; **`Chain`'s materialize made orientation-agnostic at the cutover** — the spec's staging-correction core — with explicit `Flush` at every flush site *including* the formerly implicit arbitrary/mirror rotate (T4 map row) and the smart/detect coupling (T4) ✓; identity fast path asserted at the resolver (T4 test), end-to-end (T6 streaming case), and at the boundary clear (T5 loop rule 6) ✓; trim storage-frame via plain copy-only materialize, no special routing (T4/T5) ✓; `SetFocus`/zero-op `State` writes via `%StateUpdate{}` (T3/T4 R4) ✓; **shape→`State` sync via the single driver overlay** (T5 loop rule 1, asserted by the Probe test's third-op env dims) ✓; ctx carry across an `:acquire` (T5 rule 2 + T6 resize→trim→padding case) ✓; old-path-baked injection golden incl. trim+pending / fill_down / #151 multi-op / concrete ±1 (T5 Step 5 + T6) ✓; §4.7 narrowing gate incl. the mirror literal (T7) ✓; results-identical via differential+wire equal-counts (T5 Steps 5/7) ✓; telemetry emission-site shift handled deliberately (`materialize_span_test`, `docs/telemetry.md`, logger/otel replay — T5) ✓; retire scheduler, no orphaned tests (T8, verified) ✓. **Deferred, declared:** delivery-backstop re-home (#262), boundary move/#434 + version tags + focus→strategy carry + `Lowering` re-signature spec delta (Stage 2), B-promotion (Stage 3).
- **Known pinned divergence:** trim + arbitrary rotate in one pipeline (parser-unreachable; T4 rotate-row note) — flush-before-rotate is defined behavior, not preserved behavior.
- **Placeholder scan:** T1–T3, T5 driver, T6/T7 tests are complete code. T4 (`NeutralResolver` clause port) and T5-wire are parity-gated refactor tasks — the rules R1–R5, the full clause→op map (now covering every scheduler clause: folds, SetFocus, both crop families, smart/detect, padding/pixelate/gradient, both resize branches, trim, arbitrary/mirror rotate, and the no-clause plain ops), and the gates are specified; per-clause bodies are ported from `orientation_scheduler.ex`, not fabricated.
- **Type consistency:** `Resolver.spec = {module, strategy_state}`; `resolve/4` = `(shape, env, strategy_state, op)`; facade `resolve/4` opaque in shape and env; `continuation = {:advance, SourceShape.t(), term()} | {:acquire, ({w,h} -> {SourceShape.t(), term()})}`; driver `run/5` with `acquire_dims`/`chain` opts; neutral carry = `nil`, env = `%{state, ctx}`; `%Flush{}`/`%StateUpdate{}` both `requires_materialization?: false`; flush failures `{:materialize_error, _}` end-to-end.
