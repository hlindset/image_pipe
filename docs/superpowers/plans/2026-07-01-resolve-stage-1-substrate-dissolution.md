# Resolve Stage 1 — Substrate + Orientation Dissolution — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans (recommended — inline, batched at the parity gates) or superpowers:subagent-driven-development. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Introduce `SourceShape`, the `Resolver` behaviour + neutral facade, an injectable dim-acquisition seam, a neutral `Flush` op, and a driver that resolves each plan op through the resolver — replacing `OrientationScheduler`'s fused resolve+execute with resolver-owned op emission (explicit `Flush` at every current flush site) — all **results-identical**. imgproxy resolution *math* stays physically in `ResizePlanning`/`Resize`.

**Architecture:** A driver threads a pure `%SourceShape{}` + strategy carry through `Resolver.resolve(spec, shape, op)`, which returns `{executable_ops, continuation, spec}`. Continuation is `{:advance, shape, state}` (pure) or `{:acquire, then_fn}` (driver reads realized dims via an injectable seam, then `then_fn` interprets them, declaring the frame). The Stage-1 strategy is a **neutral resolver** that reproduces today's exact op emission, but emits an explicit `Flush` op wherever `OrientationScheduler` currently calls `flush_if_pending`. Because an orienting materialize on a `nil` pending is just a `copy_memory`, no change to `Materializer` is required for parity: explicit `Flush` clears pending before any downstream materialize, and `trim` keeps `materialize_without_orientation`.

**Tech Stack:** Elixir, `Vix.Vips` (libvips), ExUnit, StreamData, `Boundary`. Existing: `ImagePipe.Transform.{PlanExecutor, OrientationScheduler, OrientationFlush, Materializer, Chain, ResizePlanning, Lowering, Geometry}`, `ImagePipe.Transform.Operation.Resize`, `ImagePipe.Transform.PendingOrientation`.

## Global Constraints

- **Run through mise:** `mise exec -- mix …`. On a `rustler_precompiled` `validate_quote` crash, prefix `env PATH="$(mise where elixir)/bin:$PATH" mix …` (Homebrew Elixir shadow).
- **Results-identical is the contract.** The imgproxy differential bake and imgproxy wire conformance suite MUST stay green after every behavior-adjacent task. No decoded-pixel or decoded-dimension change.
- **No cache key/ETag change.** Do not touch `Plan.Key`/`Plan.KeyData`/`Request.HttpCache`. No key data version bump.
- **imgproxy math stays put.** Do NOT modify `ResizePlanning`, `Operation.Resize.resolve_dimensions`, or `Geometry` arithmetic. The neutral resolver *delegates* to them; it never re-derives geometry.
- **No boundary move this stage.** `SourceShape` under `transform`; `ImagePipe.Resolver` is a new top-level boundary, `deps: [ImagePipe.Plan]`. The facade must **not** runtime-reference `SourceShape` (pass the shape opaquely; `SourceShape` appears in `Resolver` only in typespecs, which Boundary ignores). No `transform → parser` edge (no parser-owned strategies yet).
- **`Materializer` is NOT flipped in this stage.** Keep `materialize/1` orienting and `materialize_without_orientation/1` as-is. Correctness comes from the resolver emitting explicit `Flush` ops, not from changing materialize. (The optional flip is Task 9, and it is behavior-equivalent, not required.)
- **No new telemetry events.** If the `[:transform, :operation]` span now wraps a `Flush`, that's an existing event with a new `:operation` value (`:flush`) — allowed, no Logger/OTel subscription change. Adding a *new event name* requires updating the Logger + OTel `Capture` + `docs/telemetry.md`; avoid it.
- **Gate before finishing:** `mise run precommit` (`format --check-formatted`, `compile --warnings-as-errors`, `credo --strict`, `test`). Remove any dangling untracked `.credo.exs` symlink first.
- **Elixir idioms:** predicates end in `?`; no `String.to_atom/1` on request input; struct field access, not `struct[:field]`.

---

## File Structure

**Create:**
- `lib/image_pipe/transform/source_shape.ex` — pure `%SourceShape{}` + `seed/1` + `quarter_turn?/1`.
- `lib/image_pipe/resolver.ex` — `Resolver` behaviour (`init/0`, `resolve/3`) + facade (`resolve/3`) + `continuation` type. New top-level boundary.
- `lib/image_pipe/transform/operation/flush.ex` — neutral orientation-applying op (`requires_materialization?: false`, self-managing).
- `lib/image_pipe/transform/neutral_resolver.ex` — Stage-1 strategy: emits today's ops + explicit `Flush`, classifies advance/acquire, computes shape advance.
- `lib/image_pipe/transform/resolve_driver.ex` — op-by-op driver + injectable acquire seam + DprScale carry + pipeline-boundary flush.
- Tests: `test/image_pipe/transform/{source_shape,resolver,flush_op,resolve_driver,neutral_resolver,resolved_plan_golden}_test.exs`, `test/support/image_pipe/resolved_plan_cases.ex`, and a case in `test/image_pipe/transform/sequential_access_test.exs`.

**Modify:**
- `lib/image_pipe/transform/plan_executor.ex` — replace the per-pipeline `execute_operation` reduce with `ResolveDriver.run/…`; keep the preamble (detector/telemetry/EXIF seed/color management) and remove the now-dead `execute_operation`/`run_executable` once the driver subsumes them.
- `lib/image_pipe/transform.ex` — add `ImagePipe.Resolver` to `deps`; export `Operation.Flush`.

**Delete (Task 8, after green):** `lib/image_pipe/transform/orientation_scheduler.ex` once the neutral resolver fully subsumes it (keep `materialize_without_orientation` in `Materializer` — trim still uses it).

**Do NOT modify:** `ResizePlanning`, `Operation.Resize` internals, `Geometry`, `OrientationFlush` (the `Flush` op delegates to it), `Materializer` (this stage).

---

## Task 1: `SourceShape` value

**Files:** Create `lib/image_pipe/transform/source_shape.ex`; Test `test/image_pipe/transform/source_shape_test.exs`.

**Interfaces — Produces:**
- `%ImagePipe.Transform.SourceShape{width: pos_integer(), height: pos_integer(), frame: :storage | :display, pending_orientation: PendingOrientation.t() | nil, decode_shrink: %{w: float(), h: float()} | nil}`
- `seed(%{width, height, pending_orientation, decode_shrink}) :: t()` (frame `:storage`).
- `quarter_turn?(t()) :: boolean()` (false when `pending_orientation` nil).

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

## Task 2: `Resolver` behaviour + opaque facade

**Files:** Create `lib/image_pipe/resolver.ex`; Modify `lib/image_pipe/transform.ex` (deps); Test `test/image_pipe/transform/resolver_test.exs`.

**Interfaces — Produces:**
- `@type Resolver.spec :: {module(), strategy_state :: term()}`
- `@type continuation :: {:advance, SourceShape.t(), term()} | {:acquire, ({pos_integer(), pos_integer()} -> {SourceShape.t(), term()})}`
- `@callback init() :: term()`; `@callback resolve(SourceShape.t(), term(), struct()) :: {[struct()], continuation(), term()}`
- Facade `Resolver.resolve(spec, shape, op) :: {[struct()], continuation(), spec}` — dispatches to the carried module; **does not pattern-match `%SourceShape{}`** (passes `shape` opaquely) so `Resolver` needs no `transform` dep.

> **Note (deliberate divergence from spec §4.2):** the facade is arity-3 with `strategy_state` folded into `spec` (`{module, state}`), not the spec's arity-4 `resolve(spec, shape, strategy_state, op)`. Internally consistent; don't "correct" it back.

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
    def resolve(%SourceShape{} = shape, %{n: n}, op),
      do: {[{:emitted, op}], {:advance, shape, %{n: n + 1}}, %{n: n + 1}}
  end

  test "facade dispatches and threads strategy_state via the spec" do
    shape = SourceShape.seed(%{width: 10, height: 10, pending_orientation: nil, decode_shrink: nil})
    {ops, cont, {Dummy, st}} = Resolver.resolve({Dummy, Dummy.init()}, shape, :op)
    assert ops == [{:emitted, :op}]
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
  `resolve/3`; the dynamic call to the carried module is quarantined here (mirrors
  `ImagePipe.Renderer`). The facade passes the shape opaquely — no runtime reference
  to `SourceShape` — so this boundary stays `deps: [ImagePipe.Plan]`.
  """
  use Boundary, top_level?: true, deps: [ImagePipe.Plan], exports: []

  alias ImagePipe.Transform.SourceShape

  @type strategy_state :: term()
  @type spec :: {module(), strategy_state()}
  @type continuation ::
          {:advance, SourceShape.t(), strategy_state()}
          | {:acquire, ({pos_integer(), pos_integer()} -> {SourceShape.t(), strategy_state()})}

  @callback init() :: strategy_state()
  @callback resolve(SourceShape.t(), strategy_state(), struct()) :: {[struct()], continuation(), strategy_state()}

  @spec resolve(spec(), shape :: term(), struct()) :: {[struct()], continuation(), spec()}
  def resolve({module, strategy_state}, shape, op) do
    {ops, cont, next} = module.resolve(shape, strategy_state, op)
    {ops, cont, {module, next}}
  end
end
```

Add to `lib/image_pipe/transform.ex`: `deps: [ImagePipe.Plan, ImagePipe.Telemetry, ImagePipe.Resolver]` and `exports: [..., Operation.Flush]` (Flush added in Task 3).

- [ ] **Step 4: Run test + `mise exec -- mix compile --warnings-as-errors`** — pass, no Boundary violation (confirm no `resolver → transform` edge; if reported, the facade is still matching the struct somewhere — remove it).
- [ ] **Step 5: Commit** `feat(resolver): add neutral Resolver behaviour + opaque facade`

---

## Task 3: Neutral `Flush` op (self-managing, non-`requires_materialization?`)

**Files:** Create `lib/image_pipe/transform/operation/flush.ex`; Test `test/image_pipe/transform/operation/flush_test.exs` + a case in `sequential_access_test.exs`.

**Interfaces — Produces:** `%ImagePipe.Transform.Operation.Flush{}` implementing `ImagePipe.Transform`; `name/1 -> :flush`; `requires_materialization?/1 -> false` (it self-manages random access via `OrientationFlush`); `execute/2` delegates to `OrientationFlush.flush/1` (applies pending, copy_memory, clears pending, reflects focus).

> **Why `requires_materialization?: false`:** `OrientationFlush.flush/1` already does `prepare_random_access` + `copy_memory` internally ([orientation_flush.ex:18-24,58-64]). If `Flush` were `requires_materialization?: true`, `Chain` would pre-materialize via the *orienting* `Materializer.materialize` on the still-set pending — double-orient. Self-managing avoids that regardless of `Materializer`.

- [ ] **Step 1: Failing test**

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

  test "identity/nil pending is a no-op copy, dims unchanged" do
    {:ok, img} = Image.new(40, 30)
    {:ok, %State{image: out}} = Flush.execute(%Flush{}, %State{image: img, pending_orientation: nil})
    assert Image.width(out) == 40 and Image.height(out) == 30
  end

  test "requires_materialization? is false (self-managing)" do
    refute Flush.requires_materialization?(%Flush{})
  end
end
```

- [ ] **Step 2: Run — fails** → undefined.
- [ ] **Step 3: Implement**

```elixir
defmodule ImagePipe.Transform.Operation.Flush do
  @moduledoc false
  # Applies the deferred pending orientation (spec §4.6). The one op that orients.
  # Self-managing (requires_materialization?: false) — OrientationFlush handles the
  # random-access pre-copy + copy_memory + focus reflect internally.
  use ImagePipe.Transform
  alias ImagePipe.Transform.{OrientationFlush, State}

  defstruct []

  @impl ImagePipe.Transform
  def name(%__MODULE__{}), do: :flush

  @impl ImagePipe.Transform
  def requires_materialization?(%__MODULE__{}), do: false

  @impl ImagePipe.Transform
  def execute(%__MODULE__{}, %State{} = state), do: OrientationFlush.flush(state)
end
```

- [ ] **Step 4: Run tests + sequential-safety gate.** Add to `sequential_access_test.exs` a case proving `Flush` on a genuinely streamed-open source (`access: :sequential`, `fail_on: :error`) is pixel-equivalent to random access for a quarter turn, and that an identity pending stays streaming (no forced copy beyond the terminal one). Run `mise exec -- mix test test/image_pipe/transform/operation/flush_test.exs test/image_pipe/transform/sequential_access_test.exs` → pass.
- [ ] **Step 5: Commit** `feat(transform): add neutral Flush op (delegates to OrientationFlush)`

---

## Task 4: `NeutralResolver` — emit today's ops + explicit `Flush`, classify advance/acquire

**Files:** Create `lib/image_pipe/transform/neutral_resolver.ex`; Test `test/image_pipe/transform/neutral_resolver_test.exs`.

**Interfaces — Consumes:** `Lowering.executable_operations/3`, `ResizePlanning` (via Lowering), `SourceShape`, `PendingOrientation`, the live `State` + `ctx` (threaded by the driver — see below). **Produces:** `NeutralResolver` implementing `ImagePipe.Resolver`; `init/0 -> nil`.

**Contract this task must satisfy (the parity core):** `resolve(shape, strategy_state, op)` returns `{ops, continuation, strategy_state}` where `ops` is byte-identical to what today's `PlanExecutor`/`OrientationScheduler` run for the same op and state, **except** every `flush_if_pending` call becomes an explicit `%Flush{}` in `ops` at the same position. Classification:

- `:acquire` (then_fn reads realized dims): `%PlanTrim{}`, and `%PlanRotate{}` with `angle not in [0,90,180,270] or mirror`. (`resize` is `:acquire` too — see below.)
- `:advance` (pure): everything else, including `resize` in this stage — wait: `resize`'s realized dims are read today. Classify `resize` `:acquire` (read realized post-resize dims), consistent with spec §4.5. Right-angle rotate/flip fold into `pending_orientation` and emit **zero** ops: `{[], {:advance, %{shape | pending_orientation: folded}, state}, state}`.

**Flush-position map (from `orientation_scheduler.ex`, preserve exactly):**
| Op (pending non-identity) | Emitted ops | Continuation |
|---|---|---|
| region crop | `[%Flush{}, crop]` (flush before) | `:advance`, shape display-frame, `decode_shrink` oriented then cleared (#180/#185) |
| gravity crop (non-smart) | `[compensated_crop]` (crop pre-flush, storage frame) + a trailing `%Flush{}` is **not** here — the boundary/next-op flush handles it; preserve today's "crop then later flush" | `:advance` |
| smart/detect crop | `[%Flush{}, literal_crop]` (flush before; crop sees display pixels) | `:advance` |
| padding / pixelate / gradient | `[%Flush{}, op]` | `:advance` |
| resize (quarter-turn cover) | `[forcing_resize, compensated_crop, %Flush{}]` | `:acquire` → then_fn: display-frame, pending nil, `decode_shrink: nil` |
| resize (other) | `[compensated_resize, maybe_crop, %Flush{}]` | `:acquire` → then_fn display-frame |
| trim | `[trim]` (no Flush; storage frame) — trim keeps `materialize_without_orientation` via `requires_materialization?` + the driver routing trim materialization to the non-orienting path (Task 5) | `:acquire` → then_fn: **pending kept**, `frame: :storage`, `decode_shrink: nil` |
| identity pending / no pending | today's plain ops | `:advance`/`:acquire` per op, `pending_orientation` cleared if identity |

> **Parity-gated refactor task.** Reproduce each `orientation_scheduler.ex` clause verbatim, converting its `flush_if_pending`→`%Flush{}` and its state mutations (`clear_source_frame`, `orient_decode_shrink` — note the **transient-for-lowering vs persisted** distinction: gravity crop's `orient_decode_shrink` feeds only the lowering call and is NOT persisted; region crop's is) into the returned `SourceShape` advance. Delegate all geometry to `Lowering`/`ResizePlanning`; re-derive nothing. Acceptance = Task 5's differential/wire gate + Task 6 golden + this task's unit tests.

**Wiring decision (resolves the reviewer's under-spec):** `resolve/3`'s 2nd arg carries the strategy state; the live `State` and `ctx` (padding scales) are passed via a **4th driver-supplied argument channel** — concretely, the driver calls `NeutralResolver.resolve(shape, {state, ctx}, op)` in this stage (the neutral strategy's "state" is the `{State, ctx}` pair it needs to call `Lowering`). This is a Stage-1 shim; when imgproxy logic moves out (Stage 2) the strategy carry becomes the imgproxy DprScale accumulator and `State` stops flowing through. Document this in the moduledoc.

- [ ] **Step 1: Failing unit tests** — assert continuation *tags* for representative ops (extend as clauses are ported):

```elixir
defmodule ImagePipe.Transform.NeutralResolverTest do
  use ExUnit.Case, async: true
  alias ImagePipe.Transform.{NeutralResolver, SourceShape, State}
  alias ImagePipe.Plan.Operation.{Trim, Blur}

  setup do
    {:ok, img} = Image.new(100, 80)
    shape = SourceShape.seed(%{width: 100, height: 80, pending_orientation: nil, decode_shrink: nil})
    ctx = %{effective_padding_scale: nil, canvas_preserving_padding_scale: nil}
    %{carry: {%State{image: img}, ctx}, shape: shape}
  end

  test "trim → :acquire, pending kept, storage frame", %{shape: s, carry: c} do
    {ops, {:acquire, then_fn}, _} = NeutralResolver.resolve(s, c, %Trim{threshold: 10, background: :auto, equal_hor: false, equal_ver: false})
    assert [%ImagePipe.Transform.Operation.Trim{}] = ops
    {shape2, _} = then_fn.({90, 70})
    assert shape2.frame == :storage and shape2.width == 90
  end

  test "effect (blur) → :advance, dims unchanged, no ops emitted by resolver beyond the effect", %{shape: s, carry: c} do
    {ops, {:advance, %SourceShape{width: 100, height: 80}, _}, _} = NeutralResolver.resolve(s, c, %Blur{sigma: 1.0})
    assert [%ImagePipe.Transform.Operation.Blur{}] = ops
  end
end
```

- [ ] **Step 2: Run — fails** → undefined.
- [ ] **Step 3: Implement `NeutralResolver`**, porting clauses per the map. Structure: `resolve/3` → `classify(op)` → per-family `emit_*` building `{ops, continuation, carry}`. Delegate op-building to `Lowering.executable_operations(op, state_for_lowering, ctx)` and, for orientation-pending clauses, the same `compensate_*`/display-frame helpers used today (call the existing public helpers on `ResizePlanning`/`Orientation`; do not copy their bodies). Emit `%Flush{}` where the clause flushes.
- [ ] **Step 4: Run unit tests** → pass. (Full parity is proven in Task 5/6.)
- [ ] **Step 5: Commit** `feat(transform): add NeutralResolver emitting explicit Flush (parity)`

---

## Task 5: `ResolveDriver` + acquire seam + DprScale carry; wire `PlanExecutor`; prove results-identical

**Files:** Create `lib/image_pipe/transform/resolve_driver.ex`; Modify `lib/image_pipe/transform/plan_executor.ex`; Tests `resolve_driver_test.exs` + the parity gate.

**Interfaces — Produces:**
- `ResolveDriver.run(pipeline :: [struct()], SourceShape.t(), Resolver.spec(), State.t(), ctx :: map(), opts :: keyword()) :: {:ok, State.t()} | {:error, term()}`
- Seam: `opts[:acquire_dims]`, a fun `(Vix.Vips.Image.t() -> {pos_integer(), pos_integer()})`, default `&{Image.width(&1), Image.height(&1)}`.
- Per-op it recomputes `ctx` exactly as `PlanExecutor.update_execution_context/3` does today (DprScale carry, M4 fix), threads it into the neutral strategy carry, runs emitted ops via `Chain.execute`, and advances the shape via the continuation.
- **Trim non-orienting materialize:** when the emitted ops contain `%Trim{}` and pending is non-identity, run trim through `Materializer.materialize_without_orientation` before `Trim.execute` (preserve today's storage-frame trim) — either by the driver detecting `%Trim{}` in the op list, or (cleaner) by the neutral resolver keeping trim on today's `OrientationScheduler`-equivalent path. Choose the driver-detect form and document it; do not remove `materialize_without_orientation`.
- Pipeline-boundary backstop: after the last op, if `shape.pending_orientation` non-identity, run `Chain.execute(state, [%Flush{}], opts)`.

- [ ] **Step 1: Failing driver test (non-tautological — asserts the seam)**

```elixir
defmodule ImagePipe.Transform.ResolveDriverTest do
  use ExUnit.Case, async: true
  alias ImagePipe.Transform.{ResolveDriver, SourceShape, State}

  defmodule Probe do
    @behaviour ImagePipe.Resolver
    @impl true
    def init, do: nil
    @impl true
    def resolve(%SourceShape{} = shape, agent, :pure),
      do: {[], {:advance, %{shape | width: shape.width + 1}, agent}, agent}
    def resolve(%SourceShape{} = shape, agent, :opaque) do
      then_fn = fn {w, h} ->
        Agent.update(agent, &[{:acquired, w, h} | &1])
        {%{shape | width: w, height: h}, agent}
      end
      {[], {:acquire, then_fn}, agent}
    end
  end

  test "acquire uses injected dims; advance is pure" do
    {:ok, img} = Image.new(10, 10)
    agent = start_supervised!({Agent, fn -> [] end})
    shape = SourceShape.seed(%{width: 10, height: 10, pending_orientation: nil, decode_shrink: nil})
    {:ok, %State{}} =
      ResolveDriver.run([:pure, :opaque], shape, {Probe, agent}, %State{image: img}, %{}, acquire_dims: fn _ -> {77, 66} end)
    assert Agent.get(agent, & &1) == [{:acquired, 77, 66}]
  end
end
```

- [ ] **Step 2: Run — fails** → undefined.
- [ ] **Step 3: Implement `ResolveDriver`** (threads `{shape, spec, state}`, recomputes `ctx` per op, applies ops via `Chain.execute`, advances via continuation using `acquire_dims` for `:acquire`, trim non-orienting handling, boundary flush).
- [ ] **Step 4: Run driver unit test** → pass.
- [ ] **Step 5: Baseline the parity gate (green before wiring)** — `mise exec -- mix test test/image_pipe/imgproxy_wire_conformance_test.exs` and the differential lane (per `test/support/.../imgproxy_differential/README.md`). Record counts.
- [ ] **Step 6: Wire `PlanExecutor.execute_pipeline/3`** through the driver:

```elixir
defp execute_pipeline(%Pipeline{operations: operations}, %State{} = state, opts) do
  {w, h} = State.effective_source_dims(state)
  shape = SourceShape.seed(%{width: w, height: h, pending_orientation: state.pending_orientation, decode_shrink: state.decode_shrink})
  ResolveDriver.run(operations, shape, {NeutralResolver, nil}, state,
    %{effective_padding_scale: nil, canvas_preserving_padding_scale: nil}, opts)
end
```

Remove `PlanExecutor.execute_operation/*`, `run_executable/*`, `update_execution_context/*` (moved into the driver). Keep the `execute/3` preamble and the EXIF seed.

- [ ] **Step 7: Run the full parity gate** — wire + differential + `mise exec -- mix test test/image_pipe/transform`. Must equal Step 5 counts. Any diff → bisect to the offending clause in `NeutralResolver` (Task 4) and fix verbatim.
- [ ] **Step 8: Full suite + gate** — `mise exec -- mix test` and `mise run precommit`.
- [ ] **Step 9: Commit** `refactor(transform): drive execution via ResolveDriver + explicit Flush (results-identical)`

---

## Task 6: ResolvedPlan golden (injection-driven)

**Files:** Create `test/support/image_pipe/resolved_plan_cases.ex`, `test/image_pipe/transform/resolved_plan_golden_test.exs`. May add an `opts[:chain]` override to `ResolveDriver` (default `&Chain.execute/3`) so the golden captures emitted ops without running pixels.

**Case matrix (min):** plain fit; cover+result-crop; `auto` landscape→cover; `auto` portrait→fit; `min_width` coupling (#236); no-enlarge `dpr` cap, no geometry (#237); quarter-turn cover (#182) — assert the emitted list **includes the trailing `%Flush{}`** and the display-frame result box; shrink-on-load rescaled crop (#151); **trim under a pending quarter turn** (EXIF 6) — assert storage-frame trim, `%Flush{}` NOT before trim; **`fill_down`** (cover `down: true`, un-upscaled smaller than box) asymmetric crop; **±1 divergence** — a resize followed by a percent/`min_*` consumer, inject `target-1`, assert the downstream box computed from `target-1` (committed integer, not "sane").

- [ ] **Step 1:** Build the case module + a `run_capturing/1` that runs the driver with a capturing chain (append emitted ops to a `start_supervised!` Agent) and an injected `acquire_dims`, returning the recorded op list.
- [ ] **Step 2:** Golden test iterating cases, asserting recorded ops == committed `expected`. Run — fails (no expectations).
- [ ] **Step 3:** Populate `expected` by capturing from the wired pipeline (Task 5) against blank images of the seed dims; cross-check the #182 and #236 cases against imgproxy `prepare.go`/`scale.go` cited in the spec.
- [ ] **Step 4:** Run golden → pass.
- [ ] **Step 5: Commit** `test(transform): injection-driven ResolvedPlan golden (incl. trim+pending, fill_down, ±1)`

---

## Task 7: §4.7 narrowing gate (explicit enumerating test)

**Files:** Add to `neutral_resolver_test.exs`.

- [ ] **Step 1:** For a representative instance of **every** `Plan.Operation.*` variant, assert `NeutralResolver.resolve/3`'s continuation tag is `:acquire` iff the op is `%Trim{}` / arbitrary-angle `%Rotate{}` / `%Resize{}`, else `:advance`. (Defining `classify/1` is not proving it — this test is the gate, spec §8/§9.)
- [ ] **Step 2:** Run → pass. **Commit** `test(transform): gate the :acquire/:advance narrowing across all ops`

---

## Task 8: Retire `OrientationScheduler`

**Files:** Delete `lib/image_pipe/transform/orientation_scheduler.ex`; remove its references. Keep `Materializer.materialize_without_orientation` (trim uses it via the driver).

- [ ] **Step 1:** `mise exec -- grep -rn "OrientationScheduler" lib test` → confirm the only references are the module itself + the neutral resolver/driver that replaced it. If the neutral resolver still *calls* `OrientationScheduler` helpers, inline or keep those helpers in a small module; do not leave a half-dead scheduler.
- [ ] **Step 2:** Delete the module + dead refs. Run `mise exec -- mix test` + `mise run precommit` → green.
- [ ] **Step 3: Commit** `refactor(transform): remove OrientationScheduler (subsumed by resolver)`

---

## Task 9 (OPTIONAL, may defer): flip `Materializer` non-orienting

Only if desired for legibility. Behavior-equivalent (all flushes are now explicit, so `Materializer.materialize` only ever sees `nil` pending). Change `do_materialize` to copy-only, delete `materialize_without_orientation`, route trim through the plain `requires_materialization?` path. Gate on differential+wire. If any risk surfaces, **defer to Stage 2** — the plan is complete without it.

---

## Self-Review

- **Spec coverage (merged §9 Stage 1):** SourceShape (T1) ✓; Resolver behaviour+facade, opaque, `transform→resolver` dep (T2) ✓; two-variant continuation (T2/T4/T5) ✓; injectable acquire seam (T5) ✓; neutral `Flush`, self-managing, sequential-safety + identity fast path (T3) ✓; explicit `Flush` at every current flush site incl. smart/detect + arbitrary-rotate (T4 map) ✓; trim stays storage-frame via kept `materialize_without_orientation` (T4/T5) ✓; DprScale cross-op carry (T5 Step 3/6) ✓; injection golden incl. trim+pending / fill_down / concrete ±1 (T6) ✓; §4.7 narrowing enumerating gate (T7) ✓; results-identical via differential+wire (T5) ✓; `SourceShape` boundary home / no `resolver→transform` (T2) ✓; retire scheduler (T8) ✓. **Deferred correctly:** boundary move/#434 + version tags + focus→strategy_state (Stage 2); B-promotion (Stage 3); optional Materializer flip (T9/Stage 2).
- **Placeholder scan:** greenfield (T1–T3, T5 driver, T6/T7 tests) is complete code. T4 (`NeutralResolver` clause port) and T5-wire are parity-gated refactor tasks — exact files, the clause→op map, the transient-vs-persisted `orient_decode_shrink` distinction, and the differential gate are specified; the per-clause bodies are ported verbatim from `orientation_scheduler.ex`, not fabricated, with the gate as acceptance. Flagged as such.
- **Type consistency:** `Resolver.spec = {module, strategy_state}`; `continuation = {:advance, SourceShape.t(), term()} | {:acquire, ({w,h} -> {SourceShape.t(), term()})}`; facade `resolve/3` opaque; driver `run/6` with `acquire_dims`; neutral carry = `{State, ctx}` this stage; `%Operation.Flush{}` `requires_materialization?: false` everywhere. `Flush` self-manages (no Chain pre-materialize), resolving the double-flush finding.
