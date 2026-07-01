# Resolve Stage — Substrate (Spec §9 Stage 1) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Introduce the `SourceShape` virtual buffer, the `Resolver` behaviour + neutral dispatch facade, an injectable dim-acquisition seam, and a driver that resolves each plan op through the resolver — reproducing today's exact executable-op integers (results-identical), with imgproxy resolution logic still physically in `ResizePlanning`/orientation code. No boundary move, no behavior change.

**Architecture:** A driver threads a pure `%SourceShape{}` op-by-op through `Resolver.resolve(spec, shape, strategy_state, op)`, which returns `{executable_ops, continuation, strategy_state}`. The continuation is `{:advance, shape, state}` (pure) or `{:acquire, then_fn}` (driver reads realized dims via an injectable seam, then `then_fn` interprets them). For this stage the single carried strategy is a **neutral resolver that delegates to the existing resolution code** (extracted so it emits ops instead of running them), so the emitted op sequence is byte-for-byte what today's pipeline produces. The differential bake + wire tests are the parity gate; a new injection-driven "ResolvedPlan golden" pins the resolved integers as data.

**Tech Stack:** Elixir, `Vix.Vips` (libvips), ExUnit, StreamData, `Boundary`. Existing resolution lives in `ImagePipe.Transform.{PlanExecutor, ResizePlanning, OrientationScheduler, Lowering, Geometry}` and `ImagePipe.Transform.Operation.Resize`.

## Global Constraints

- **Run everything through mise:** `mise exec -- mix …`. If a `rustler_precompiled` `validate_quote` crash appears, the Homebrew Elixir is shadowing mise — prefix with the mise toolchain: `env PATH="$(mise where elixir)/bin:$PATH" mix …`.
- **Results-identical is the contract.** The imgproxy differential bake and the imgproxy wire conformance suite MUST stay green after every task. No task may change decoded output pixels or dimensions.
- **No cache key/ETag change.** Do not touch `ImagePipe.Plan.Key` / `Plan.KeyData` / `Request.HttpCache` in this stage. No key data version bump.
- **No boundary move this stage.** imgproxy resolution stays where it is. `ImagePipe.Transform.SourceShape` lives under the `transform` boundary. `ImagePipe.Resolver` is a new top-level boundary, `deps: [ImagePipe.Plan]`. Do NOT add a `transform → parser` edge (there are no parser-owned strategies yet).
- **No new telemetry events** in this stage (so the Logger and OTel `Capture` lists need no change). If that turns out to be unavoidable, stop and update both surfaces + `docs/telemetry.md` per the telemetry guidelines.
- **Gate before finishing:** `mise run precommit` (`mix format --check-formatted`, `mix compile --warnings-as-errors`, `mix credo --strict`, `mix test`) must pass. A dangling untracked `.credo.exs` symlink in a worktree breaks `mix format` repo-wide — `rm` it if present.
- **Elixir idioms:** predicate functions end in `?`; no `String.to_atom/1` on request input; structs use direct field access, not `struct[:field]`.

---

## File Structure

**Create:**
- `lib/image_pipe/transform/source_shape.ex` — the pure `%SourceShape{}` value + `seed/1` + `quarter_turn?/1`.
- `lib/image_pipe/resolver.ex` — the neutral `Resolver` behaviour (`init/0`, `resolve/3`) + dispatch facade (`resolve/4`) + the `continuation` typespec. New top-level boundary.
- `lib/image_pipe/transform/neutral_resolver.ex` — the Stage-1 strategy: implements `ImagePipe.Resolver` by delegating to the extracted resolution helpers, emitting ops + continuation instead of running them.
- `lib/image_pipe/transform/resolve_driver.ex` — the op-by-op driver: seeds the shape, threads `{shape, strategy_state}`, applies ops via `Chain`, and owns the injectable acquire seam + end-of-pipeline flush backstop.
- `test/image_pipe/transform/source_shape_test.exs`
- `test/image_pipe/transform/resolver_test.exs`
- `test/image_pipe/transform/resolve_driver_test.exs`
- `test/image_pipe/transform/resolved_plan_golden_test.exs` — the injection-driven golden.
- `test/support/image_pipe/resolved_plan_cases.ex` — the shared (plan × source dims × injected realized dims) matrix used by the golden.

**Modify:**
- `lib/image_pipe/transform/plan_executor.ex` — swap the per-pipeline `Enum.reduce_while` body to call `ResolveDriver` (keeping the preamble: detector/telemetry/EXIF seed/color management). This is the single wiring point.
- `lib/image_pipe/transform.ex` — add `ImagePipe.Resolver` and (if needed) `SourceShape` to the `transform` boundary `deps`/`exports` as required to compile; add the `transform → resolver` dep.
- `mix.exs` — no change expected (Boundary deps are declared in-module via `use Boundary`); only touch if the compile reports a missing top-level boundary.

**Do NOT modify in this stage:** `ResizePlanning`, `OrientationScheduler`, `Lowering`, `Geometry`, `Operation.Resize` internals beyond making their op-emitting helpers callable without running `Chain` (Task 6). Their *math* is preserved verbatim.

---

## Task 1: `SourceShape` value

**Files:**
- Create: `lib/image_pipe/transform/source_shape.ex`
- Test: `test/image_pipe/transform/source_shape_test.exs`

**Interfaces:**
- Produces:
  - `%ImagePipe.Transform.SourceShape{width: pos_integer(), height: pos_integer(), frame: :storage | :display, pending_orientation: ImagePipe.Transform.PendingOrientation.t() | nil, decode_shrink: %{w: float(), h: float()} | nil}`
  - `SourceShape.seed(%{width: pos_integer(), height: pos_integer(), pending_orientation: PendingOrientation.t() | nil, decode_shrink: %{w: float(), h: float()} | nil}) :: t()` — builds the initial storage-frame shape.
  - `SourceShape.quarter_turn?(t()) :: boolean()` — true iff a pending orientation is a quarter turn (delegates to `PendingOrientation.quarter_turn?/1`; false when `pending_orientation` is nil).

- [ ] **Step 1: Write the failing test**

```elixir
# test/image_pipe/transform/source_shape_test.exs
defmodule ImagePipe.Transform.SourceShapeTest do
  use ExUnit.Case, async: true

  alias ImagePipe.Transform.PendingOrientation
  alias ImagePipe.Transform.SourceShape

  test "seed builds a storage-frame shape from header facts" do
    po = PendingOrientation.from_exif(6, true)

    shape =
      SourceShape.seed(%{
        width: 4000,
        height: 3000,
        pending_orientation: po,
        decode_shrink: %{w: 2.0, h: 2.0}
      })

    assert %SourceShape{
             width: 4000,
             height: 3000,
             frame: :storage,
             pending_orientation: ^po,
             decode_shrink: %{w: 2.0, h: 2.0}
           } = shape
  end

  test "quarter_turn? reflects the pending orientation, false when nil" do
    assert SourceShape.quarter_turn?(SourceShape.seed(%{width: 10, height: 10, pending_orientation: PendingOrientation.from_exif(6, true), decode_shrink: nil}))
    refute SourceShape.quarter_turn?(SourceShape.seed(%{width: 10, height: 10, pending_orientation: PendingOrientation.from_exif(3, true), decode_shrink: nil}))
    refute SourceShape.quarter_turn?(SourceShape.seed(%{width: 10, height: 10, pending_orientation: nil, decode_shrink: nil}))
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mise exec -- mix test test/image_pipe/transform/source_shape_test.exs`
Expected: FAIL — `ImagePipe.Transform.SourceShape` is undefined.

- [ ] **Step 3: Write minimal implementation**

```elixir
# lib/image_pipe/transform/source_shape.ex
defmodule ImagePipe.Transform.SourceShape do
  @moduledoc false
  # The pure geometry value threaded by the resolve driver (spec §4.3). Subsumes
  # State.source_dimensions / decode_shrink / pending_orientation. `frame` makes the
  # storage-vs-display distinction first-class. Never emitted in telemetry.

  alias ImagePipe.Transform.PendingOrientation

  @enforce_keys [:width, :height, :frame]
  defstruct [:width, :height, :frame, pending_orientation: nil, decode_shrink: nil]

  @type t :: %__MODULE__{
          width: pos_integer(),
          height: pos_integer(),
          frame: :storage | :display,
          pending_orientation: PendingOrientation.t() | nil,
          decode_shrink: %{w: float(), h: float()} | nil
        }

  @spec seed(%{
          required(:width) => pos_integer(),
          required(:height) => pos_integer(),
          required(:pending_orientation) => PendingOrientation.t() | nil,
          required(:decode_shrink) => %{w: float(), h: float()} | nil
        }) :: t()
  def seed(%{width: w, height: h, pending_orientation: po, decode_shrink: shrink})
      when is_integer(w) and w > 0 and is_integer(h) and h > 0 do
    %__MODULE__{
      width: w,
      height: h,
      frame: :storage,
      pending_orientation: po,
      decode_shrink: shrink
    }
  end

  @spec quarter_turn?(t()) :: boolean()
  def quarter_turn?(%__MODULE__{pending_orientation: nil}), do: false
  def quarter_turn?(%__MODULE__{pending_orientation: po}), do: PendingOrientation.quarter_turn?(po)
end
```

- [ ] **Step 4: Run test to verify it passes**

Run: `mise exec -- mix test test/image_pipe/transform/source_shape_test.exs`
Expected: PASS (2 tests).

- [ ] **Step 5: Commit**

```bash
git add lib/image_pipe/transform/source_shape.ex test/image_pipe/transform/source_shape_test.exs
git commit -m "feat(transform): add SourceShape virtual-buffer value"
```

---

## Task 2: `Resolver` behaviour + dispatch facade

**Files:**
- Create: `lib/image_pipe/resolver.ex`
- Modify: `lib/image_pipe/transform.ex` (add `deps: [..., ImagePipe.Resolver]`)
- Test: `test/image_pipe/transform/resolver_test.exs`

**Interfaces:**
- Consumes: `ImagePipe.Transform.SourceShape` (Task 1).
- Produces:
  - `@type ImagePipe.Resolver.spec :: {module(), strategy_state :: term()}` — the carried strategy (module + its opaque accumulator).
  - `@type continuation :: {:advance, SourceShape.t(), term()} | {:acquire, ({pos_integer(), pos_integer()} -> {SourceShape.t(), term()})}`
  - `@callback init() :: term()`
  - `@callback resolve(SourceShape.t(), term(), struct()) :: {[struct()], continuation(), term()}`
  - Facade `Resolver.resolve(spec, SourceShape.t(), op :: struct()) :: {[struct()], continuation(), spec}` — dispatches to the carried module and re-wraps the returned strategy_state into the spec (the dynamic dispatch is quarantined here; spec §5.1).

- [ ] **Step 1: Write the failing test**

```elixir
# test/image_pipe/transform/resolver_test.exs
defmodule ImagePipe.ResolverTest do
  use ExUnit.Case, async: true

  alias ImagePipe.Resolver
  alias ImagePipe.Transform.SourceShape

  defmodule DummyStrategy do
    @behaviour ImagePipe.Resolver
    @impl true
    def init, do: %{calls: 0}
    @impl true
    def resolve(%SourceShape{} = shape, %{calls: n}, op) do
      {[{:emitted, op}], {:advance, shape, %{calls: n + 1}}, %{calls: n + 1}}
    end
  end

  test "facade dispatches to the carried module and threads strategy_state via the spec" do
    shape = SourceShape.seed(%{width: 10, height: 10, pending_orientation: nil, decode_shrink: nil})
    spec = {DummyStrategy, DummyStrategy.init()}

    {ops, cont, {DummyStrategy, new_state}} = Resolver.resolve(spec, shape, :op_a)

    assert ops == [{:emitted, :op_a}]
    assert {:advance, ^shape, %{calls: 1}} = cont
    assert new_state == %{calls: 1}
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mise exec -- mix test test/image_pipe/transform/resolver_test.exs`
Expected: FAIL — `ImagePipe.Resolver` is undefined.

- [ ] **Step 3: Write minimal implementation**

```elixir
# lib/image_pipe/resolver.ex
defmodule ImagePipe.Resolver do
  @moduledoc """
  Neutral behaviour + dispatch facade for geometry resolution (spec §4.2/§5.1).

  A plan carries a resolution strategy as a `spec` value (`{module, strategy_state}`).
  The driver calls `resolve/3`; the dynamic call to the carried module is quarantined
  here, mirroring `ImagePipe.Renderer`. The core never enumerates strategies.
  """

  use Boundary, top_level?: true, deps: [ImagePipe.Plan], exports: []

  alias ImagePipe.Transform.SourceShape

  @type strategy_state :: term()
  @type spec :: {module(), strategy_state()}
  @type continuation ::
          {:advance, SourceShape.t(), strategy_state()}
          | {:acquire, ({pos_integer(), pos_integer()} -> {SourceShape.t(), strategy_state()})}

  @callback init() :: strategy_state()
  @callback resolve(SourceShape.t(), strategy_state(), op :: struct()) ::
              {[struct()], continuation(), strategy_state()}

  @spec resolve(spec(), SourceShape.t(), struct()) :: {[struct()], continuation(), spec()}
  def resolve({module, strategy_state}, %SourceShape{} = shape, op) do
    {ops, cont, next_state} = module.resolve(shape, strategy_state, op)
    {ops, cont, {module, next_state}}
  end
end
```

Note: `use Boundary, deps: [ImagePipe.Plan]` — `SourceShape` is referenced only in typespecs (`@type`/`@callback`), which Boundary does not treat as a runtime dependency, so no `transform` dep is required here. If compile reports otherwise, add `ImagePipe.Transform` to `deps` and re-run.

Then add the dep on the `transform` side so `ImagePipe.Transform.*` may call the facade in later tasks:

```elixir
# lib/image_pipe/transform.ex — extend the use Boundary deps list
  use Boundary,
    top_level?: true,
    deps: [ImagePipe.Plan, ImagePipe.Telemetry, ImagePipe.Resolver],
    exports: [ ... unchanged ... ]
```

- [ ] **Step 4: Run test + full compile to verify boundaries**

Run: `mise exec -- mix test test/image_pipe/transform/resolver_test.exs`
Expected: PASS (1 test).
Run: `mise exec -- mix compile --warnings-as-errors`
Expected: clean compile, no Boundary violation.

- [ ] **Step 5: Commit**

```bash
git add lib/image_pipe/resolver.ex lib/image_pipe/transform.ex test/image_pipe/transform/resolver_test.exs
git commit -m "feat(resolver): add neutral Resolver behaviour + dispatch facade"
```

---

## Task 3: Extract op-emission from execution (make resolution callable without running Chain)

This is the enabling refactor: today `OrientationScheduler.execute_operation/4` and `PlanExecutor.run_executable/4` both **lower to ops and immediately run them via `Chain.execute`**. To thread a `SourceShape`, resolution must return the ops instead of running them. This task extracts pure "emit ops" functions with **no** behavior change — the existing `execute_operation` paths are rewritten to call the new emit function and then `Chain.execute`, so the current pipeline still runs identically.

**Files:**
- Modify: `lib/image_pipe/transform/orientation_scheduler.ex` — add `emit_operations(op, state, ctx) :: {[struct()], State.t()}` capturing every clause's op list + the state mutations it performs *around* execution (`clear_source_frame`, `orient_decode_shrink`, the pre/post flush ordering expressed as emitted `Flush`/materialize markers). Keep the existing `execute_operation/4` as a thin wrapper: `emit_operations` then `Chain.execute`.
- Modify: `lib/image_pipe/transform/plan_executor.ex` — `run_executable/4` similarly splits into emit + run.
- Test: reuse the existing differential + wire suites as the parity gate; add no new unit test here (the deliverable is a pure extraction proven by unchanged behavior).

**Interfaces:**
- Produces: `OrientationScheduler.emit_operations(struct(), State.t(), map()) :: {[struct()], State.t()}` and `Lowering.executable_operations/3` (already pure — unchanged). The returned `State.t()` carries the same field mutations (`source_dimensions`/`decode_shrink`/`pending_orientation`) the clause performs today, so the driver (Task 5) can derive the next `SourceShape` from it during this stage.

> **Parity-gated refactor task.** The body is a mechanical extraction of the existing clauses in `orientation_scheduler.ex` (lines ~56–433) and `plan_executor.ex` (`run_executable`/`execute_operation`). Preserve every clause verbatim; only move the `Chain.execute` call to the caller. Do not re-derive any imgproxy math. The test is behavioral parity, below.

- [ ] **Step 1: Establish the parity baseline (must be green before touching code)**

Run: `mise exec -- mix test test/image_pipe/imgproxy_wire_conformance_test.exs`
Run: `mise exec -- mix test --only imgproxy_differential` *(or the project's differential lane per `test/support/image_pipe/test/imgproxy_differential/README.md`)*
Expected: PASS. Record the pass counts.

- [ ] **Step 2: Extract `emit_operations` in `OrientationScheduler`, wrapper runs Chain**

For each existing `execute_operation/4` clause, split into `emit_operations/3` (returns `{ops, state}`) and keep `execute_operation/4` as:

```elixir
def execute_operation(op, %State{} = state, ctx, opts) do
  {ops, state} = emit_operations(op, state, ctx)
  Chain.execute(state, ops, opts)
end
```

Where a clause today calls `flush_if_pending` mid-sequence, represent the flush as an emitted materializing `Flush` op **in `ops`** at the same position (Task 4 defines `Flush`); where it self-materializes trim without orienting, rely on `Trim`'s `requires_materialization?` (Chain will materialize) — do not emit a separate op. Keep `clear_source_frame`/`orient_decode_shrink` as mutations on the returned `state`.

- [ ] **Step 3: Run the parity gate**

Run: `mise exec -- mix test test/image_pipe/imgproxy_wire_conformance_test.exs` and the differential lane.
Expected: identical pass counts to Step 1. If any differ, the extraction changed behavior — revert and redo the offending clause verbatim.

- [ ] **Step 4: Run the broad transform suite**

Run: `mise exec -- mix test test/image_pipe/transform`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add lib/image_pipe/transform/orientation_scheduler.ex lib/image_pipe/transform/plan_executor.ex
git commit -m "refactor(transform): split op-emission from execution (no behavior change)"
```

---

## Task 4: Neutral `Flush` executable op

**Files:**
- Create: `lib/image_pipe/transform/operation/flush.ex`
- Modify: `lib/image_pipe/transform.ex` (export `Operation.Flush`)
- Test: `test/image_pipe/transform/operation/flush_test.exs`, plus the sequential-access gate in `test/image_pipe/transform/sequential_access_test.exs`

**Interfaces:**
- Consumes: `ImagePipe.Transform.OrientationFlush` (the existing flush logic), `ImagePipe.Transform.State`.
- Produces: `%ImagePipe.Transform.Operation.Flush{}` implementing `ImagePipe.Transform` with `requires_materialization?/1 -> true`; `execute/2` applies the pending orientation (delegating to `OrientationFlush`) and returns state with `pending_orientation: nil`. Identity pending is handled by the resolver emitting **no** `Flush` (so `execute/2` may assume non-identity), but `execute/2` must still no-op safely on a nil/identity pending for robustness.

> **Parity-gated refactor task.** `Flush.execute/2` must reproduce exactly what `OrientationScheduler.flush_if_pending/1` → `Materializer`/`OrientationFlush` does for a non-identity pending. Delegate to the existing `OrientationFlush` rather than re-implementing rotation math.

- [ ] **Step 1: Write the failing test** (frame swap + pending cleared)

```elixir
# test/image_pipe/transform/operation/flush_test.exs
defmodule ImagePipe.Transform.Operation.FlushTest do
  use ExUnit.Case, async: true

  alias ImagePipe.Transform.Operation.Flush
  alias ImagePipe.Transform.PendingOrientation
  alias ImagePipe.Transform.State

  test "a quarter-turn flush swaps dims and clears pending" do
    {:ok, img} = Image.new(40, 30)
    state = %State{image: img, pending_orientation: PendingOrientation.from_exif(6, true)}

    {:ok, %State{image: out, pending_orientation: nil}} = Flush.execute(%Flush{}, state)

    assert Image.width(out) == 30
    assert Image.height(out) == 40
  end

  test "requires_materialization? is true" do
    assert Flush.requires_materialization?(%Flush{})
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mise exec -- mix test test/image_pipe/transform/operation/flush_test.exs`
Expected: FAIL — `Flush` undefined.

- [ ] **Step 3: Implement `Flush` delegating to `OrientationFlush`**

```elixir
# lib/image_pipe/transform/operation/flush.ex
defmodule ImagePipe.Transform.Operation.Flush do
  @moduledoc false
  # Applies the deferred pending orientation (spec §4.6). The one op that orients;
  # Chain's Materializer never orients. Delegates the rotation math to OrientationFlush.

  use ImagePipe.Transform

  alias ImagePipe.Transform.OrientationFlush
  alias ImagePipe.Transform.PendingOrientation
  alias ImagePipe.Transform.State

  defstruct []

  @impl ImagePipe.Transform
  def name(%__MODULE__{}), do: :flush

  @impl ImagePipe.Transform
  def requires_materialization?(%__MODULE__{}), do: true

  @impl ImagePipe.Transform
  def execute(%__MODULE__{}, %State{pending_orientation: nil} = state), do: {:ok, state}

  def execute(%__MODULE__{}, %State{pending_orientation: po} = state) do
    if PendingOrientation.identity?(po) do
      {:ok, %State{state | pending_orientation: nil}}
    else
      OrientationFlush.flush(state)
    end
  end
end
```

> If `OrientationFlush.flush/1` returns `{:ok, state}` with pending already cleared, keep as-is; if it returns a bare state or leaves pending set, wrap to `{:ok, %State{... pending_orientation: nil}}`. Confirm its real signature before finalizing.

- [ ] **Step 4: Run unit test + add the sequential-safety gate**

Add a case to `test/image_pipe/transform/sequential_access_test.exs` proving `Flush` on a streamed-open source is pixel-equivalent to random access (per the transform guidelines), and that `requires_materialization?` is honored.

Run: `mise exec -- mix test test/image_pipe/transform/operation/flush_test.exs test/image_pipe/transform/sequential_access_test.exs`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add lib/image_pipe/transform/operation/flush.ex lib/image_pipe/transform.ex test/image_pipe/transform/operation/flush_test.exs test/image_pipe/transform/sequential_access_test.exs
git commit -m "feat(transform): add neutral Flush op (delegates to OrientationFlush)"
```

---

## Task 5: `ResolveDriver` + injectable acquire seam (wire behind the old path, off by default)

**Files:**
- Create: `lib/image_pipe/transform/resolve_driver.ex`
- Test: `test/image_pipe/transform/resolve_driver_test.exs`

**Interfaces:**
- Consumes: `Resolver.resolve/3` (Task 2), `SourceShape.seed/1` (Task 1), `Chain.execute/3`.
- Produces:
  - `ResolveDriver.run(pipeline :: [struct()], SourceShape.t(), Resolver.spec(), State.t(), opts :: keyword()) :: {:ok, State.t()} | {:error, term()}`
  - Seam: `opts[:acquire_dims]` is a 1-arg fun `(Vix.Vips.Image.t() -> {pos_integer(), pos_integer()})`, defaulting to `&{Image.width(&1), Image.height(&1)}`. Tests inject a fun that returns fixed dims (no decode).
  - End-of-pipeline flush backstop: if the final `shape.pending_orientation` is non-identity, append a `Flush` op run.

- [ ] **Step 1: Write the failing test** (driver threads shape, uses injected acquire, applies ops)

```elixir
# test/image_pipe/transform/resolve_driver_test.exs
defmodule ImagePipe.Transform.ResolveDriverTest do
  use ExUnit.Case, async: true

  alias ImagePipe.Transform.ResolveDriver
  alias ImagePipe.Transform.SourceShape
  alias ImagePipe.Transform.State

  defmodule RecordingStrategy do
    @behaviour ImagePipe.Resolver
    @impl true
    def init, do: []
    # `:pure` op -> advance; `:opaque` op -> acquire (driver injects dims)
    @impl true
    def resolve(%SourceShape{} = shape, log, :pure) do
      {[], {:advance, %SourceShape{shape | width: shape.width + 1}, [:pure | log]}, [:pure | log]}
    end

    def resolve(%SourceShape{} = shape, log, :opaque) do
      then_fn = fn {w, h} -> {%SourceShape{shape | width: w, height: h}, [:opaque | log]} end
      {[], {:acquire, then_fn}, [:opaque | log]}
    end
  end

  test "advance threads the shape purely; acquire uses the injected dims" do
    {:ok, img} = Image.new(10, 10)
    shape = SourceShape.seed(%{width: 10, height: 10, pending_orientation: nil, decode_shrink: nil})
    spec = {RecordingStrategy, RecordingStrategy.init()}

    injected = fn _img -> {77, 66} end

    {:ok, %State{} = out} =
      ResolveDriver.run([:pure, :opaque], shape, spec, %State{image: img},
        acquire_dims: injected
      )

    # No ops emitted, so the image is unchanged; the test asserts the run succeeds
    # and the injected acquire path was taken (shape reached 77x66 internally).
    assert %State{} = out
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mise exec -- mix test test/image_pipe/transform/resolve_driver_test.exs`
Expected: FAIL — `ResolveDriver` undefined.

- [ ] **Step 3: Implement the driver**

```elixir
# lib/image_pipe/transform/resolve_driver.ex
defmodule ImagePipe.Transform.ResolveDriver do
  @moduledoc false
  # Op-by-op resolve driver (spec §4.1/§4.5). Threads {SourceShape, strategy_state},
  # applies emitted ops via Chain, and advances the shape either purely (:advance) or
  # from realized dims read via the injectable acquire seam (:acquire).

  alias ImagePipe.Resolver
  alias ImagePipe.Transform.Chain
  alias ImagePipe.Transform.Operation.Flush
  alias ImagePipe.Transform.PendingOrientation
  alias ImagePipe.Transform.SourceShape
  alias ImagePipe.Transform.State

  @spec run([struct()], SourceShape.t(), Resolver.spec(), State.t(), keyword()) ::
          {:ok, State.t()} | {:error, term()}
  def run(pipeline, %SourceShape{} = shape, spec, %State{} = state, opts) do
    acquire = Keyword.get(opts, :acquire_dims, &default_acquire/1)

    pipeline
    |> Enum.reduce_while({:ok, shape, spec, state}, fn op, {:ok, shape, spec, state} ->
      {ops, cont, spec} = Resolver.resolve(spec, shape, op)

      case Chain.execute(state, ops, opts) do
        {:ok, %State{} = state} ->
          {shape, spec} = advance(cont, spec, state, acquire)
          {:cont, {:ok, shape, spec, state}}

        {:error, _reason} = error ->
          {:halt, error}
      end
    end)
    |> case do
      {:ok, shape, _spec, state} -> flush_backstop(shape, state, opts)
      {:error, _reason} = error -> error
    end
  end

  defp advance({:advance, shape, strategy_state}, {module, _}, _state, _acquire),
    do: {shape, {module, strategy_state}}

  defp advance({:acquire, then_fn}, {module, _}, %State{image: image}, acquire) do
    {shape, strategy_state} = then_fn.(acquire.(image))
    {shape, {module, strategy_state}}
  end

  defp default_acquire(image), do: {Image.width(image), Image.height(image)}

  defp flush_backstop(%SourceShape{pending_orientation: nil}, state, _opts), do: {:ok, state}

  defp flush_backstop(%SourceShape{pending_orientation: po}, state, opts) do
    if PendingOrientation.identity?(po) do
      {:ok, state}
    else
      Chain.execute(state, [%Flush{}], opts)
    end
  end
end
```

- [ ] **Step 4: Run test to verify it passes**

Run: `mise exec -- mix test test/image_pipe/transform/resolve_driver_test.exs`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add lib/image_pipe/transform/resolve_driver.ex test/image_pipe/transform/resolve_driver_test.exs
git commit -m "feat(transform): add ResolveDriver with injectable acquire seam"
```

---

## Task 6: `NeutralResolver` — emit ops via the extracted resolution, with shape advance

**Files:**
- Create: `lib/image_pipe/transform/neutral_resolver.ex`
- Test: covered by the golden (Task 7) and the differential/wire gate once wired (Task 8); add targeted `resolve/3` unit tests for the two continuation shapes.

**Interfaces:**
- Consumes: `OrientationScheduler.emit_operations/3` + `Lowering.executable_operations/3` (Task 3), `SourceShape`, `PendingOrientation`.
- Produces: `NeutralResolver` implementing `ImagePipe.Resolver`. `init/0 -> nil` (Stage-1 neutral carry is unused). `resolve/3` classifies each op into `:advance` vs `:acquire`:
  - **`:acquire`** for `%Plan.Operation.Trim{}` and arbitrary-angle `%Plan.Operation.Rotate{}` (materialize+read): emit the op(s); `then_fn` sets dims from the read, `frame: :storage` for trim (pending kept), `decode_shrink: nil` for trim.
  - **`:advance`** for every other op: emit the op(s) via the extracted helpers, and compute the next `SourceShape` from the returned `State` mutations (Task 3 makes `emit_operations` return the mutated state) — this keeps the shape in lockstep with today's `State` fields, guaranteeing results-identical during this stage.

> **Parity-gated refactor task.** This resolver is a *delegating adapter* — it must not re-derive geometry. It calls the extracted `emit_operations/3`/`executable_operations/3` and reads back the resulting dims/frame/shrink from the mutated `State` to build the next `SourceShape`. The `:advance`-vs-`:acquire` classification is the only new decision; everything else is delegation. Correctness is proven by Task 7 (golden) + Task 8 (differential/wire).

- [ ] **Step 1: Write targeted continuation-shape tests**

```elixir
# in test/image_pipe/transform/resolver_test.exs (extend)
test "neutral resolver returns :acquire for trim and :advance for an effect" do
  alias ImagePipe.Transform.NeutralResolver
  alias ImagePipe.Transform.SourceShape
  alias ImagePipe.Plan.Operation.{Trim, Blur}

  shape = SourceShape.seed(%{width: 100, height: 80, pending_orientation: nil, decode_shrink: nil})

  {_ops, {:acquire, _fn}, _st} = NeutralResolver.resolve(shape, nil, %Trim{threshold: 10, background: :auto, equal_hor: false, equal_ver: false})
  {_ops, {:advance, %SourceShape{width: 100, height: 80}, _}, _st} = NeutralResolver.resolve(shape, nil, %Blur{sigma: 1.0})
end
```

- [ ] **Step 2: Run to verify it fails**

Run: `mise exec -- mix test test/image_pipe/transform/resolver_test.exs`
Expected: FAIL — `NeutralResolver` undefined.

- [ ] **Step 3: Implement `NeutralResolver` (delegating)**

Skeleton (bodies delegate to Task-3 helpers; the `State` view is built from the driver-provided state, threaded via opts — see the wiring note):

```elixir
# lib/image_pipe/transform/neutral_resolver.ex
defmodule ImagePipe.Transform.NeutralResolver do
  @moduledoc false
  # Stage-1 strategy (spec §9 stage 1): delegates to the extracted resolution helpers
  # so emitted ops are byte-identical to today's pipeline, while classifying each op's
  # shape advance (:advance) vs realized read (:acquire). No geometry is re-derived.

  @behaviour ImagePipe.Resolver

  alias ImagePipe.Plan.Operation.Rotate, as: PlanRotate
  alias ImagePipe.Plan.Operation.Trim, as: PlanTrim
  alias ImagePipe.Transform.SourceShape

  @impl true
  def init, do: nil

  @impl true
  def resolve(%SourceShape{} = shape, state, op) do
    if acquire_op?(op) do
      resolve_acquire(shape, state, op)
    else
      resolve_advance(shape, state, op)
    end
  end

  defp acquire_op?(%PlanTrim{}), do: true
  defp acquire_op?(%PlanRotate{angle: a, mirror: m}) when a not in [0, 90, 180, 270] or m == true, do: true
  defp acquire_op?(_op), do: false

  # resolve_advance/resolve_acquire delegate to the extracted OrientationScheduler
  # emit_operations/3 + Lowering.executable_operations/3, then derive the next
  # SourceShape from the mutated State (dims/frame/pending/decode_shrink). See Task 3.
  # ... (bodies completed against the extracted helpers; parity-gated by Tasks 7-8) ...
end
```

> **Wiring note for the implementer:** `emit_operations/3` needs the execution `State` and `ctx`. During Stage 1 the driver already holds `State`; thread the current `State` + `ctx` to `resolve/3` via the strategy_state or an opts channel so the neutral resolver can call the extracted helpers. Keep `SourceShape` as the *derived* view of `State` here — the point of this stage is parity, not yet the clean separation (that comes when imgproxy logic moves in a later plan). Complete the two private functions so that: emitted ops equal today's, and the next `SourceShape` mirrors the post-op `State` dims/frame/shrink.

- [ ] **Step 4: Run the targeted tests**

Run: `mise exec -- mix test test/image_pipe/transform/resolver_test.exs`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add lib/image_pipe/transform/neutral_resolver.ex test/image_pipe/transform/resolver_test.exs
git commit -m "feat(transform): add NeutralResolver delegating to extracted resolution"
```

---

## Task 7: ResolvedPlan golden (injection-driven, pure)

**Files:**
- Create: `test/support/image_pipe/resolved_plan_cases.ex`
- Create: `test/image_pipe/transform/resolved_plan_golden_test.exs`

**Interfaces:**
- Consumes: `ResolveDriver.run/5` (via a thin capture wrapper), `NeutralResolver`, `SourceShape`, injected `acquire_dims`.
- Produces: a golden that, for each case `{plan_pipeline, seed_shape, injected_realized_dims_per_acquire}`, runs the driver with a **capturing** Chain (records emitted op structs instead of running pixels) and an **injected** acquire, then asserts the recorded executable-op list (the resolved integer boxes) equals a committed expectation. No decode.

**Case matrix (minimum):** plain fit; cover+result-crop; `auto` landscape→cover; `auto` portrait→fit; `min_width` coupling (crop-back-to-box, #236); no-enlarge `dpr` cap with no geometry (#237); quarter-turn cover (display-frame resolve, #182); a shrink-on-load rescaled crop (#151); trim-first then `auto` resize (inject the post-trim dims).

- [ ] **Step 1: Write the case module + a capturing driver entry**

```elixir
# test/support/image_pipe/resolved_plan_cases.ex
defmodule ImagePipe.ResolvedPlanCases do
  @moduledoc false
  # Shared (pipeline, seed, injected realized dims, expected resolved ops) matrix
  # for the ResolvedPlan golden. Injected dims stand in for libvips-realized reads,
  # so resolution runs with no decode.
  def cases, do: [ ... the matrix above, each a map ... ]
end
```

Add a capture path: the golden calls `ResolveDriver.run/5` with `opts[:chain]` overridable (default `Chain.execute/3`) and passes a capturing chain that appends emitted ops to a process-dictionary-free accumulator (use an Agent started via `start_supervised!`). If `ResolveDriver` does not yet accept a `:chain` override, add it in this task (small, backward-compatible: `Keyword.get(opts, :chain, &Chain.execute/3)`), with a matching `resolve_driver_test.exs` assertion.

- [ ] **Step 2: Write the golden test that fails (no expectations committed yet)**

```elixir
# test/image_pipe/transform/resolved_plan_golden_test.exs
defmodule ImagePipe.Transform.ResolvedPlanGoldenTest do
  use ExUnit.Case, async: true

  alias ImagePipe.ResolvedPlanCases

  for case_def <- ResolvedPlanCases.cases() do
    @case case_def
    test "resolved plan golden: #{@case.name}" do
      captured = ImagePipe.ResolvedPlanCases.run_capturing(@case)
      assert captured == @case.expected
    end
  end
end
```

- [ ] **Step 3: Populate expectations from the CURRENT pipeline (characterize)**

For each case, temporarily run the *current* `PlanExecutor` path against a real blank image of `seed` dims to derive today's resolved ops (or read them from the existing wire tests' decoded dims), and record them as `expected`. Cross-check at least one case against the imgproxy source cited in the spec (`prepare.go`) so the expectation is anchored to ground truth, not just self-consistent.

- [ ] **Step 4: Run the golden**

Run: `mise exec -- mix test test/image_pipe/transform/resolved_plan_golden_test.exs`
Expected: PASS for all cases.

- [ ] **Step 5: Add a divergence-robustness case**

Add one case that injects a resize realized dim **1px short** of the naive target and asserts the downstream ratio/percent consumer still resolves sanely (spec §8). Commit.

```bash
git add test/support/image_pipe/resolved_plan_cases.ex test/image_pipe/transform/resolved_plan_golden_test.exs lib/image_pipe/transform/resolve_driver.ex
git commit -m "test(transform): add injection-driven ResolvedPlan golden"
```

---

## Task 8: Wire `PlanExecutor` to the driver; prove results-identical

**Files:**
- Modify: `lib/image_pipe/transform/plan_executor.ex` — replace the per-pipeline `Enum.reduce_while` over `execute_operation` with `ResolveDriver.run(operations, seed_shape, {NeutralResolver, NeutralResolver.init()}, state, opts)`. Keep the preamble (detector/telemetry/EXIF seed via `PendingOrientation.from_exif`, color management) and the pipeline-boundary flush (now owned by the driver backstop). Build `seed_shape` from `State.effective_source_dims/1` + `state.decode_shrink` + `state.pending_orientation`.

**Interfaces:**
- Consumes: everything above.
- Produces: no API change to `Transform.execute_plan/3`.

> **Parity-gated task — the integration point.** The differential bake + wire suite are the acceptance gate. The `emit_operations` split (Task 3) and the delegating `NeutralResolver` (Task 6) mean the emitted ops are unchanged; this task only redirects the loop through the driver.

- [ ] **Step 1: Baseline the gate (green before change)**

Run: `mise exec -- mix test test/image_pipe/imgproxy_wire_conformance_test.exs` and the differential lane. Record counts.

- [ ] **Step 2: Redirect the pipeline loop through `ResolveDriver`**

```elixir
# plan_executor.ex — replace execute_pipeline/3 body
defp execute_pipeline(%Pipeline{operations: operations}, %State{} = state, opts) do
  shape =
    SourceShape.seed(%{
      width: elem(State.effective_source_dims(state), 0),
      height: elem(State.effective_source_dims(state), 1),
      pending_orientation: state.pending_orientation,
      decode_shrink: state.decode_shrink
    })

  ResolveDriver.run(operations, shape, {NeutralResolver, NeutralResolver.init()}, state, opts)
end
```

Remove the now-dead `execute_operation/*`, `run_executable/*`, `update_execution_context/*` from `PlanExecutor` *only if* fully subsumed; otherwise keep the context computation and thread it into the driver/resolver. Do not delete `OrientationScheduler.emit_operations` (the resolver calls it).

- [ ] **Step 3: Run the full parity gate**

Run: `mise exec -- mix test test/image_pipe/imgproxy_wire_conformance_test.exs`
Run: the differential lane.
Run: `mise exec -- mix test test/image_pipe/transform`
Expected: identical pass counts to Step 1. Any diff = a parity regression; bisect to the offending clause.

- [ ] **Step 4: Full suite + gate**

Run: `mise exec -- mix test`
Run: `mise run precommit`
Expected: all green.

- [ ] **Step 5: Commit**

```bash
git add lib/image_pipe/transform/plan_executor.ex
git commit -m "refactor(transform): drive plan execution through ResolveDriver (results-identical)"
```

---

## Task 9: Consolidate `State` geometry fields behind `SourceShape` (optional within this stage)

Only if Tasks 1–8 leave `State.source_dimensions`/`decode_shrink`/`pending_orientation` fully derivable from the threaded `SourceShape`. If any consumer outside the driver still reads them, **defer to the next plan** and note it — do not force the consolidation here.

- [ ] **Step 1:** Grep for readers: `mise exec -- grep -rn "\.source_dimensions\|\.decode_shrink\|\.pending_orientation" lib/image_pipe`
- [ ] **Step 2:** If the only readers are the driver/resolver/OrientationFlush, replace the `State` reads with `SourceShape` and drop the fields; otherwise stop and record the remaining consumers for the next plan.
- [ ] **Step 3:** Run `mise exec -- mix test` + `mise run precommit`.
- [ ] **Step 4:** Commit `refactor(transform): fold source geometry State fields into SourceShape` (or a note-only commit deferring it).

---

## Self-Review

- **Spec coverage (spec §9 stage 1):** `SourceShape` (Task 1) ✓; Resolver behaviour + facade + `transform → resolver` dep (Task 2) ✓; two-variant continuation (Tasks 2, 5) ✓; injectable acquire seam (Task 5) ✓; `Flush` op + sequential-safety gate (Task 4) ✓; resolution/execution separation (Task 3) ✓; neutral delegating resolver (Task 6) ✓; injection ResolvedPlan golden incl. ±1 divergence case (Task 7) ✓; results-identical via differential+wire (Tasks 3, 8) ✓; §4.7 continuation-variant narrowing (`:acquire` = trim + arbitrary-rotate only) proven by the golden as the stage-1 exit gate (Tasks 6, 7) ✓. **Deferred to later plans (correctly out of scope):** boundary move to `parser/imgproxy/` (stage 3), orientation-scheduler *dissolution* into the resolver proper vs the Stage-1 delegating shim (stage 2), TwicPics focus → strategy_state (stage 3), retiring the focus read-back / B-promotion (stage 4), strategy behavioral version tags in `plan_material` (stage 3), delivery-boundary materialize re-home to the `:transformed_pixels` tap (stage 2/3, tracked with #262/#377).
- **Placeholder scan:** the `NeutralResolver` bodies (Task 6) and `emit_operations` extraction (Task 3) are explicitly parity-gated refactor tasks whose acceptance is the differential/golden, not fabricated diffs — flagged as such, with exact files, the existing clauses to preserve, and the gate. All greenfield code (Tasks 1, 2, 4, 5, 7) is complete.
- **Type consistency:** `Resolver.spec` = `{module, strategy_state}`; `continuation` = `{:advance, SourceShape.t(), term()} | {:acquire, ({w,h} -> {SourceShape.t(), term()})}`; facade `resolve/3` re-wraps into `spec`; driver `advance/4` matches both continuation shapes; `SourceShape.seed/1` takes a map with the four keys used consistently in Tasks 1/8. `Flush` is `%Operation.Flush{}` throughout.

---

## Notes for subsequent plans (not this stage)

- **Stage 2 plan:** dissolve `OrientationScheduler` proper (the Stage-1 `emit_operations` shim becomes resolver-native), formalize flush position by op-list order, smart/detect explicit-`Flush`, re-home the delivery-boundary materialize to the `:transformed_pixels` tap. Re-prove sequential-safety + identity fast path.
- **Stage 3 plan:** extract the imgproxy-only column into an `ImagePipe.Resolver` strategy under `parser/imgproxy/` (carried in the Plan); neutral default resolver keeps the shared column; add strategy behavioral version tags to `plan_material`; move TwicPics focus into its strategy accumulator; update `docs/imgproxy_support_matrix.md`; closes #434.
- **Stage 4 plan (optional):** the `resize` rounding property spike; if green, flip `resize` from `:acquire`-read to `:advance` at the seam (selectively) and retire the focus read-back.
