# IIIF Arbitrary Rotation + Mirroring Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Support IIIF `rotationArbitrary` (any 0–360° angle) and `mirroring` (`!n`) by adding a reusable native `Transform.Operation.Rotate` chain op, while right-angle non-mirrored rotation stays on the existing lossless `pending_orientation`/`vips_rot` path.

**Architecture:** Arbitrary-angle rotation is an affine resample that grows the canvas to a bounding box and exposes corners — it cannot join the deferred `pending_orientation` mechanism (which only models 90° quarter-turn W↔H swaps). So it becomes a genuine materializing chain op. Because `Chain.maybe_materialize` runs `Materializer.materialize` → `OrientationFlush.flush` before any `requires_materialization?: true` op, the new op automatically sees the EXIF-corrected display frame (correct "EXIF auto-orient → then user rotation" ordering) with no special executor clause. IIIF mirror (`!`) is captured as a `mirror:` field on the op (atomic mirror-then-rotate), isolating the dialect's composition order. Corners are filled transparent; non-alpha output formats flatten onto the existing `flatten_background` (IIIF forbids a per-request fill knob).

**Tech Stack:** Elixir, libvips via Vix (`Vix.Vips.Operation`) and the `image` library facade, NimbleOptions, ExUnit + StreamData, Boundary; the demo is Svelte 5 + TypeScript (`fiddle/`).

**Reference spec:** `docs/superpowers/specs/2026-06-14-iiif-arbitrary-rotation-mirroring-design.md` (review-cycle findings already folded in).

**Run commands** (always via mise): focused test `mise exec -- mix test path/to/test.exs:LINE`; gate `mise run precommit`; fiddle gate `mise run precommit:fiddle`.

---

## File Structure

**Backend — modify:**
- `lib/image_pipe/plan/operation/rotate.ex` — widen struct (`angle: number()`, add `mirror: false`).
- `lib/image_pipe/plan/operation.ex` — `rotate/2` constructor; widen `semantic?(%Rotate{})` validation gate.
- `lib/image_pipe/plan/key_data.ex` — add `mirror` to the cache key data.
- `lib/image_pipe/transform.ex` — add `Operation.Rotate` to boundary `exports:`.
- `lib/image_pipe/transform/plan_executor.ex` — split the `%PlanRotate{}` clause; add `executable_operations/3` clause + transform alias.
- `lib/image_pipe/parser/iiif/grammar.ex` — `rotation/1` accepts `!` + arbitrary float.
- `lib/image_pipe/parser/iiif/plan_builder.ex` — `rotation_operations/1` maps `{mirror, angle}`.
- `lib/image_pipe/parser/iiif/info.ex` — advertise `rotationArbitrary` + `mirroring`.
- `docs/iiif_3_support_matrix.md` — surface + stage/order + behavioral notes.

**Backend — create:**
- `lib/image_pipe/transform/operation/rotate.ex` — the new transform op (pixel engine).
- `test/image_pipe/transform/operation/rotate_test.exs` — op unit tests.

**Backend — modify tests:**
- `test/parser/iiif/grammar_test.exs`, `test/parser/iiif/plan_builder_test.exs`, `test/parser/iiif_wire_test.exs`, `test/parser/iiif_test.exs`, `test/image_pipe/transform/sequential_access_test.exs`.

**Demo — modify:**
- `fiddle/assets/iiif-path.ts`, `fiddle/assets/IiifControls.svelte`, `fiddle/assets/iiif-path.test.ts`.

**Do NOT touch** (verified out of scope): `pending_orientation.ex` `fold_rotate/2` typespec; `imgproxy/plan_builder.ex:326` (default `mirror` arg keeps it compiling); `fiddle/assets/fiddle-url-state.ts` `parseRotate` (that's the imgproxy `rotate` option, right-angle only, unrelated to IIIF).

---

## Task 1: Widen `Plan.Operation.Rotate` (struct, constructor, validation gate, cache key)

Foundation: make the canonical plan model carry arbitrary angle + mirror, and make the validation gate and cache key accept it. No behavior change yet (no executor/op wiring).

**Files:**
- Modify: `lib/image_pipe/plan/operation/rotate.ex`
- Modify: `lib/image_pipe/plan/operation.ex:28` (delete `@right_angles`), `:104-105` (constructor), `:397` (semantic?)
- Modify: `lib/image_pipe/plan/key_data.ex:137`
- Test: `test/image_pipe/plan/operation_test.exs` (exists), `test/image_pipe/plan/operation_key_data_test.exs` (exists)

- [ ] **Step 1: Fix the EXISTING conflicting assertions (they describe the old reject-everything-but-right-angles behavior)**

`test/image_pipe/plan/operation_test.exs` already exists. Update these assertions (they break once arbitrary angles are valid):
- line ~409 `assert Operation.rotate(0) == {:error, {:invalid_operation, :rotate, [0]}}` → **delete** (0 is now valid: `{:ok, %Rotate{angle: 0}}`).
- line ~410 `assert Operation.rotate(45) == {:error, {:invalid_operation, :rotate, [45]}}` → **delete** (45 is now valid).
- line ~413 `refute Operation.semantic?(%Rotate{angle: 0})` → **delete** (now true).
- line ~414 `refute Operation.semantic?(%Rotate{angle: 45})` → **delete** (now true).
- Leave lines ~399 (`semantic?(%Rotate{angle: 90})`) and ~404 (`rotate(90) == {:ok, %Rotate{angle: 90}}`) — the `%Rotate{angle: 90}` literal picks up `mirror: false` on both sides, so they still pass.

In `test/image_pipe/plan/operation_key_data_test.exs`, line ~208:
```elixir
      assert KeyData.data(%Rotate{angle: 270}) == [op: :rotate, angle: 270]
```
→
```elixir
      assert KeyData.data(%Rotate{angle: 270}) == [op: :rotate, angle: 270, mirror: false]
```

- [ ] **Step 2: Write failing tests for the widened constructor + gate**

Add to `test/image_pipe/plan/operation_test.exs` (it already aliases `Operation` and `Rotate`):

```elixir
describe "rotate/2 (arbitrary angle + mirror)" do
  test "accepts a right angle, mirror defaults false" do
    assert {:ok, %Rotate{angle: 90, mirror: false}} = Operation.rotate(90)
  end

  test "accepts an arbitrary float angle" do
    assert {:ok, %Rotate{angle: 45.5, mirror: false}} = Operation.rotate(45.5)
  end

  test "normalizes a whole-number float to an integer (lossless routing)" do
    assert {:ok, %Rotate{angle: 90, mirror: false}} = Operation.rotate(90.0)
  end

  test "normalizes 360 to 0" do
    assert {:ok, %Rotate{angle: 0}} = Operation.rotate(360)
  end

  test "accepts mirror" do
    assert {:ok, %Rotate{angle: 90, mirror: true}} = Operation.rotate(90, true)
  end

  test "rejects out-of-range and non-numeric angles" do
    assert {:error, _} = Operation.rotate(-1)
    assert {:error, _} = Operation.rotate(361)
    assert {:error, _} = Operation.rotate("90")
  end

  test "semantic? accepts arbitrary + mirror, rejects out of range" do
    assert Operation.semantic?(%Rotate{angle: 45.5, mirror: true})
    assert Operation.semantic?(%Rotate{angle: 0, mirror: false})
    refute Operation.semantic?(%Rotate{angle: 360, mirror: false})
    refute Operation.semantic?(%Rotate{angle: -1, mirror: false})
  end
end
```

- [ ] **Step 3: Run tests to verify they fail**

Run: `mise exec -- mix test test/image_pipe/plan/operation_test.exs`
Expected: FAIL — `Rotate` struct has no `mirror` key / `rotate/1` rejects non-right-angles.

- [ ] **Step 4: Widen the `Rotate` struct**

Replace the body of `lib/image_pipe/plan/operation/rotate.ex`:

```elixir
defmodule ImagePipe.Plan.Operation.Rotate do
  @moduledoc """
  Semantic request to rotate the image clockwise by `angle` degrees, optionally
  mirrored (horizontal flip) first.

  `angle` is any number in `[0, 360)` (degrees, clockwise); whole-number angles
  are stored as integers so that right-angle multiples route to the lossless
  rotate path. `mirror` applies a horizontal flip *before* the rotation (IIIF `!`
  semantics).
  """

  @enforce_keys [:angle]
  defstruct [:angle, mirror: false]

  @type t :: %__MODULE__{angle: number(), mirror: boolean()}
end
```

- [ ] **Step 5: Widen the constructor + validation gate in `plan/operation.ex`**

Replace `rotate/1` (lines 103-105):

```elixir
  @spec rotate(term()) :: {:ok, Rotate.t()} | {:error, error()}
  @spec rotate(term(), term()) :: {:ok, Rotate.t()} | {:error, error()}
  def rotate(angle, mirror \\ false)

  def rotate(angle, mirror) when is_number(angle) and is_boolean(mirror) do
    case normalize_rotation_angle(angle) do
      {:ok, normalized} -> {:ok, %Rotate{angle: normalized, mirror: mirror}}
      :error -> invalid(:rotate, [angle, mirror])
    end
  end

  def rotate(angle, mirror), do: invalid(:rotate, [angle, mirror])

  # Accept the closed interval [0, 360]; fold 360 -> 0 and whole floats -> ints so
  # right angles route to the lossless rotate path.
  defp normalize_rotation_angle(angle) when angle >= 0 and angle <= 360 do
    reduced = if angle == 360, do: 0, else: angle
    {:ok, whole_to_integer(reduced)}
  end

  defp normalize_rotation_angle(_angle), do: :error

  defp whole_to_integer(value) when is_float(value) do
    truncated = trunc(value)
    if value == truncated, do: truncated, else: value
  end

  defp whole_to_integer(value), do: value
```

Replace `semantic?(%Rotate{...})` (line 397):

```elixir
  def semantic?(%Rotate{angle: angle, mirror: mirror}),
    do: is_number(angle) and angle >= 0 and angle < 360 and is_boolean(mirror)
```

**Delete `@right_angles` (line 28).** It was referenced ONLY by the two clauses just rewritten (`rotate/1` line 104 and `semantic?` line 397); after this task it is unused, which fails `mix compile --warnings-as-errors`. (It is a private module attribute — imgproxy references the `Operation.rotate` *function*, not this attribute.) Verify with `grep -n "@right_angles" lib/image_pipe/plan/operation.ex` → no remaining references after the edit.

- [ ] **Step 6: Add `mirror` to the cache key data**

In `lib/image_pipe/plan/key_data.ex:137`, replace:

```elixir
  def data(%Rotate{angle: angle}), do: [op: :rotate, angle: angle]
```

with:

```elixir
  def data(%Rotate{angle: angle, mirror: mirror}), do: [op: :rotate, angle: angle, mirror: mirror]
```

- [ ] **Step 7: Run tests to verify they pass**

Run: `mise exec -- mix test test/image_pipe/plan/operation_test.exs`
Expected: PASS.

- [ ] **Step 8: Verify imgproxy call site still compiles (default arg)**

Run: `mise exec -- mix compile --warnings-as-errors`
Expected: clean compile. `imgproxy/plan_builder.ex:326` calls `Operation.rotate(angle)` (arity-1) — the default `mirror \\ false` keeps it valid.

- [ ] **Step 9: Commit**

```bash
git add lib/image_pipe/plan/operation/rotate.ex lib/image_pipe/plan/operation.ex lib/image_pipe/plan/key_data.ex test/image_pipe/plan/operation_test.exs
git commit -m "feat(plan): widen Rotate op to arbitrary angle + mirror (#257)"
```

---

## Task 2: New `Transform.Operation.Rotate` chain op (pixel engine)

The materializing transform op: optional horizontal mirror, then lossless `vips_rot` for right angles or transparent-corner affine `vips_rotate` for arbitrary angles.

**Files:**
- Create: `lib/image_pipe/transform/operation/rotate.ex`
- Modify: `lib/image_pipe/transform.ex` (exports)
- Test: `test/image_pipe/transform/operation/rotate_test.exs`

- [ ] **Step 1: Write the failing op unit test**

Create `test/image_pipe/transform/operation/rotate_test.exs`:

```elixir
defmodule ImagePipe.Transform.Operation.RotateTest do
  use ExUnit.Case, async: true

  alias ImagePipe.Transform
  alias ImagePipe.Transform.Operation.Rotate
  alias ImagePipe.Transform.State
  alias Vix.Vips.Image, as: VipsImage

  defp state_for(image), do: %State{image: image, materialized?: true}

  defp run(op, image) do
    {:ok, %State{image: result}} = Transform.execute(op, state_for(image))
    result
  end

  test "requires materialization" do
    assert Transform.requires_materialization?(%Rotate{angle: 45})
    assert Transform.requires_materialization?(%Rotate{angle: 90})
  end

  test "name is :rotate" do
    assert Transform.transform_name(%Rotate{angle: 90}) == :rotate
  end

  test "right angle uses lossless rot: a 90° turn of a WxH image is HxW, no new bands" do
    {:ok, image} = Image.new(40, 20, color: [10, 20, 30])
    result = run(%Rotate{angle: 90}, image)
    assert Image.width(result) == 20
    assert Image.height(result) == 40
    refute Image.has_alpha?(result)
  end

  test "arbitrary angle grows the bounding box and adds transparent corners" do
    {:ok, image} = Image.new(40, 20, color: [10, 20, 30])
    result = run(%Rotate{angle: 45}, image)
    # 45° bounding box of 40x20 is larger on both axes.
    assert Image.width(result) > 40
    assert Image.height(result) > 20
    assert Image.has_alpha?(result)
    # A corner pixel (0,0) is exposed background -> fully transparent (alpha band 0).
    pixel = Image.get_pixel!(result, 0, 0)
    assert List.last(pixel) == 0, "corner not transparent: #{inspect(pixel)}"
  end

  test "arbitrary angle does not dark-fringe opaque content (premultiply works)" do
    # A bright opaque image; after a small rotation the interior stays bright,
    # i.e. interior colour is not pulled toward the [0,0,0] background.
    {:ok, image} = Image.new(60, 60, color: [240, 240, 240])
    result = run(%Rotate{angle: 10}, image)
    [r, g, b | _] = Image.get_pixel!(result, div(Image.width(result), 2), div(Image.height(result), 2))
    assert r > 200 and g > 200 and b > 200, "interior darkened: #{inspect([r, g, b])}"
  end

  test "mirror flips horizontally before rotating" do
    # Distinct left/right halves; mirror+0° swaps them.
    {:ok, left} = Image.new(20, 20, color: [255, 0, 0])
    {:ok, right} = Image.new(20, 20, color: [0, 0, 255])
    {:ok, joined} = Operation.join(left, right, :VIPS_DIRECTION_HORIZONTAL)
    result = run(%Rotate{angle: 0, mirror: true}, joined)
    [r | _] = Image.get_pixel!(result, 1, 10)
    assert r == 0, "left edge should now be the (blue) mirrored right half"
  end
end
```

Add `alias Vix.Vips.Operation` to the test's aliases (used by `Operation.join`):

```elixir
  alias Vix.Vips.Operation
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mise exec -- mix test test/image_pipe/transform/operation/rotate_test.exs`
Expected: FAIL — `Transform.Operation.Rotate` is undefined.

- [ ] **Step 3: Create the transform op**

Create `lib/image_pipe/transform/operation/rotate.ex`:

```elixir
defmodule ImagePipe.Transform.Operation.Rotate do
  @moduledoc """
  Executable rotation. Applies an optional horizontal mirror (IIIF `!`) *before*
  rotating clockwise by `angle` degrees.

  Exact right-angle multiples use the lossless `vips_rot` primitive (no resample,
  no #211 background seam — even when mirrored). Any other angle uses the affine
  `vips_rotate` resampler with a transparent background, so the exposed corners
  are transparent; a non-alpha output format flattens that transparency onto the
  configured `Plan.Output.flatten_background` at encode time (IIIF defines no
  per-request fill knob).

  Materializing op: rotation reads pixels out of row order, so it cannot run over
  a sequential decode. As a `requires_materialization?: true` op it is preceded by
  `Chain`/`Materializer`'s orientation-applying flush, so it always sees the
  EXIF-corrected display frame.
  """

  use ImagePipe.Transform

  import ImagePipe.Transform.State, only: [set_image: 2]

  alias ImagePipe.Transform.State
  alias Vix.Vips.Image, as: VipsImage
  alias Vix.Vips.Operation

  @enforce_keys [:angle]
  defstruct [:angle, mirror: false]

  @type t :: %__MODULE__{angle: number(), mirror: boolean()}

  # Float RGBA: vips_rotate's `background` is an array of doubles; a 4-element
  # value fills the exposed corners fully transparent on an alpha image.
  @transparent [0.0, 0.0, 0.0, 0.0]

  @impl ImagePipe.Transform
  def name(%__MODULE__{}), do: :rotate

  @impl ImagePipe.Transform
  def requires_materialization?(%__MODULE__{}), do: true

  @impl ImagePipe.Transform
  def execute(%__MODULE__{angle: angle, mirror: mirror}, %State{} = state) do
    with {:ok, image} <- maybe_mirror(state.image, mirror),
         {:ok, image} <- rotate(image, angle) do
      {:ok, set_image(state, image)}
    else
      {:error, error} -> {:error, {__MODULE__, error}}
    end
  end

  defp maybe_mirror(image, false), do: {:ok, image}
  defp maybe_mirror(image, true), do: Image.flip(image, :horizontal)

  # Exact right angles: the lossless vips_rot primitive (same one OrientationFlush
  # and imgproxy use). Direct Vix call — the `image` facade has no exact-rotate.
  defp rotate(image, 0), do: {:ok, image}
  defp rotate(image, 90), do: Operation.rot(image, :VIPS_ANGLE_D90)
  defp rotate(image, 180), do: Operation.rot(image, :VIPS_ANGLE_D180)
  defp rotate(image, 270), do: Operation.rot(image, :VIPS_ANGLE_D270)

  # Arbitrary angle: affine resample with transparent corners. Ensure an alpha
  # band, then premultiply -> rotate -> unpremultiply (vips_rotate does NOT
  # premultiply; rotating un-premultiplied RGBA dark-fringes the resampled edges,
  # the same reason blur/sharpen premultiply). Call Vix directly: the `image`
  # facade's Image.rotate/3 rejects a 4-element RGBA background.
  defp rotate(image, angle) do
    with {:ok, rgba} <- ensure_alpha(image),
         band_format = VipsImage.format(rgba),
         {:ok, premultiplied} <- Operation.premultiply(rgba),
         {:ok, cast} <- Operation.cast(premultiplied, band_format),
         {:ok, rotated} <- Operation.rotate(cast, angle * 1.0, background: @transparent),
         {:ok, unpremultiplied} <- Operation.unpremultiply(rotated) do
      Operation.cast(unpremultiplied, band_format)
    end
  end

  defp ensure_alpha(image) do
    if Image.has_alpha?(image), do: {:ok, image}, else: Image.add_alpha(image, :opaque)
  end
end
```

- [ ] **Step 4: Add the op to the Transform boundary exports**

In `lib/image_pipe/transform.ex`, add `Operation.Rotate,` to the `exports:` list (alphabetically near the other `Operation.*` entries, e.g. after `Operation.Resize,`).

- [ ] **Step 5: Run the op test to verify it passes**

Run: `mise exec -- mix test test/image_pipe/transform/operation/rotate_test.exs`
Expected: PASS. If `Operation.rotate/3`'s option key differs, run `mise exec -- iex -S mix` and check `Vix.Vips.Operation.rotate(img, 45.0, background: [0.0,0.0,0.0,0.0])` returns `{:ok, _}`; adjust the option name if libvips names it differently (it is `background`).

- [ ] **Step 6: Run compile gate**

Run: `mise exec -- mix compile --warnings-as-errors && mise exec -- mix credo --strict lib/image_pipe/transform/operation/rotate.ex`
Expected: clean.

- [ ] **Step 7: Commit**

```bash
git add lib/image_pipe/transform/operation/rotate.ex lib/image_pipe/transform.ex test/image_pipe/transform/operation/rotate_test.exs
git commit -m "feat(transform): add Rotate op (mirror + lossless/affine angles) (#257)"
```

---

## Task 3: Executor routing + materialization integration

Route right-angle-no-mirror rotation to the pending path (unchanged) and everything else to the new chain op. Prove the EXIF-flush-before-rotate ordering and the sequential-safety classification.

**Files:**
- Modify: `lib/image_pipe/transform/plan_executor.ex` (alias, `execute_operation/4` split, `executable_operations/3` clause)
- Test: `test/image_pipe/transform/sequential_access_test.exs` (anchor), plus a new integration test in `test/image_pipe/transform/rotate_routing_test.exs`

- [ ] **Step 1: Write the failing routing/integration test**

Create `test/image_pipe/transform/rotate_routing_test.exs`:

```elixir
defmodule ImagePipe.Transform.RotateRoutingTest do
  use ExUnit.Case, async: true

  alias ImagePipe.Plan
  alias ImagePipe.Plan.Operation.Rotate, as: PlanRotate
  alias ImagePipe.Plan.Pipeline
  alias ImagePipe.Plan.Response
  alias ImagePipe.Transform
  alias ImagePipe.Transform.State
  alias Vix.Vips.Image, as: VipsImage

  defp run(ops) do
    {:ok, image} = Image.new(40, 20, color: [10, 20, 30])
    plan = %Plan{
      source: nil,
      auto_rotate: false,
      pipelines: [%Pipeline{operations: ops}],
      output: nil,
      response: %Response{}
    }

    {:ok, %State{image: result}} =
      Transform.execute_plan(plan, %State{image: image})

    result
  end

  test "arbitrary angle routes to the chain op (bounding box grows, alpha added)" do
    result = run([%PlanRotate{angle: 45, mirror: false}])
    assert Image.width(result) > 40 and Image.height(result) > 20
    assert Image.has_alpha?(result)
  end

  test "right-angle non-mirrored rotation produces a lossless quarter turn" do
    result = run([%PlanRotate{angle: 90, mirror: false}])
    assert Image.width(result) == 20 and Image.height(result) == 40
    refute Image.has_alpha?(result)
  end

  test "right-angle mirrored rotation routes to the chain op" do
    result = run([%PlanRotate{angle: 90, mirror: true}])
    assert Image.width(result) == 20 and Image.height(result) == 40
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mise exec -- mix test test/image_pipe/transform/rotate_routing_test.exs`
Expected: FAIL — arbitrary `%PlanRotate{angle: 45}` currently folds into pending and `OrientationFlush` cannot apply a non-right angle (error or wrong dimensions).

- [ ] **Step 3: Add the transform-op alias in `plan_executor.ex`**

In the alias block (near line 39-54, the `ImagePipe.Transform.Operation.*` aliases), add:

```elixir
  alias ImagePipe.Transform.Operation.Rotate
```

(The plan op is already aliased as `Rotate, as: PlanRotate` at line 30, so the bare `Rotate` name is free for the transform op — same pattern as `Bitonal`/`PlanBitonal`.)

- [ ] **Step 4: Split the `%PlanRotate{}` execute_operation clause**

Replace the single fold clause (lines 177-180):

```elixir
  defp execute_operation(%PlanRotate{angle: angle}, %State{} = state, _ctx, _opts) do
    po = state.pending_orientation || %PendingOrientation{}
    {:ok, %State{state | pending_orientation: PendingOrientation.fold_rotate(po, angle)}}
  end
```

with:

```elixir
  # Right-angle, non-mirrored rotation defers into pending_orientation (lossless
  # vips_rot at the flush, imgproxy parity, #211 seam avoidance). Unchanged path.
  defp execute_operation(%PlanRotate{angle: angle, mirror: false}, %State{} = state, _ctx, _opts)
       when angle in [0, 90, 180, 270] do
    po = state.pending_orientation || %PendingOrientation{}
    {:ok, %State{state | pending_orientation: PendingOrientation.fold_rotate(po, angle)}}
  end

  # Arbitrary angle or mirror: run as a materializing chain op. Chain's pre-op
  # materialize flushes any pending EXIF orientation first, so the rotation lands
  # in the display frame (EXIF auto-orient -> then user rotation).
  defp execute_operation(%PlanRotate{} = operation, %State{} = state, ctx, opts) do
    run_executable(operation, state, ctx, opts)
  end
```

- [ ] **Step 5: Add the `executable_operations/3` clause**

Next to the other `executable_operations/3` clauses (e.g. after the `%PlanBitonal{}`/`%PlanGray{}` clauses around line 635-637), add:

```elixir
  defp executable_operations(%PlanRotate{angle: angle, mirror: mirror}, %State{}, _context),
    do: [%Rotate{angle: angle, mirror: mirror}]
```

- [ ] **Step 6: Run the routing test to verify it passes**

Run: `mise exec -- mix test test/image_pipe/transform/rotate_routing_test.exs`
Expected: PASS.

- [ ] **Step 7: Add the sequential-safety anchor note**

In `test/image_pipe/transform/sequential_access_test.exs`, add an alias `alias ImagePipe.Transform.Operation.Rotate` and a test confirming the new op is materializing (a `true`-classified op has no streaming claim — this documents it alongside the harness self-check):

```elixir
  test "Rotate op is materializing (known-random; cannot stream)" do
    alias ImagePipe.Transform.Operation.Rotate
    assert ImagePipe.Transform.requires_materialization?(%Rotate{angle: 45})
    assert ImagePipe.Transform.requires_materialization?(%Rotate{angle: 90, mirror: true})
  end
```

(Place the `alias` at the top with the others rather than inline if the file style prefers; match the surrounding convention.)

- [ ] **Step 8: Run the full transform suite + the EXIF-ordering check**

Run: `mise exec -- mix test test/image_pipe/transform/`
Expected: PASS — existing deferred-orientation tests still green (right-angle path untouched).

- [ ] **Step 9: Commit**

```bash
git add lib/image_pipe/transform/plan_executor.ex test/image_pipe/transform/rotate_routing_test.exs test/image_pipe/transform/sequential_access_test.exs
git commit -m "feat(transform): route arbitrary/mirrored rotation to the chain op (#257)"
```

---

## Task 4: IIIF parsing — grammar + plan_builder + info.json

Wire the IIIF dialect: accept `!` + arbitrary float in the rotation token, map it to plan ops, and advertise the features. The grammar return type changes from `{:ok, angle}` to `{:ok, {mirror, angle}}`, so the plan_builder and existing tests update in the same task to stay green.

**Files:**
- Modify: `lib/image_pipe/parser/iiif/grammar.ex` (`rotation/1`)
- Modify: `lib/image_pipe/parser/iiif/plan_builder.ex` (`rotation_operations/1`, alias `Flip`)
- Modify: `lib/image_pipe/parser/iiif/info.ex` (`@extra_features`)
- Modify tests: `test/parser/iiif/grammar_test.exs`, `test/parser/iiif/plan_builder_test.exs`

- [ ] **Step 1: Update grammar tests (red)**

In `test/parser/iiif/grammar_test.exs`, replace the rotation lines (30-33) in the `"rotation / quality / format"` test:

```elixir
    assert Grammar.rotation("0") == {:ok, {false, 0}}
    assert Grammar.rotation("90") == {:ok, {false, 90}}
    assert Grammar.rotation("90.0") == {:ok, {false, 90}}
    assert Grammar.rotation("360") == {:ok, {false, 0}}
    assert Grammar.rotation("45") == {:ok, {false, 45}}
    assert Grammar.rotation("22.5") == {:ok, {false, 22.5}}
    assert Grammar.rotation("!90") == {:ok, {true, 90}}
    assert Grammar.rotation("!0") == {:ok, {true, 0}}
    assert Grammar.rotation("045") == {:ok, {false, 45}}
    assert {:error, {:invalid_rotation, "-5"}} = Grammar.rotation("-5")
    assert {:error, {:invalid_rotation, "361"}} = Grammar.rotation("361")
    assert {:error, {:invalid_rotation, "45."}} = Grammar.rotation("45.")
    assert {:error, {:invalid_rotation, ".5"}} = Grammar.rotation(".5")
    assert {:error, {:invalid_rotation, "45deg"}} = Grammar.rotation("45deg")
    assert {:error, {:invalid_rotation, "+45"}} = Grammar.rotation("+45")
    assert {:error, {:invalid_rotation, " 45"}} = Grammar.rotation(" 45")
    assert {:error, {:invalid_rotation, "!"}} = Grammar.rotation("!")
    assert {:error, {:invalid_rotation, "abc"}} = Grammar.rotation("abc")
```

- [ ] **Step 2: Run grammar test to verify it fails**

Run: `mise exec -- mix test test/parser/iiif/grammar_test.exs`
Expected: FAIL — current `rotation/1` returns a bare integer and rejects `45`/`!90`.

- [ ] **Step 3: Rewrite `Grammar.rotation/1`**

In `lib/image_pipe/parser/iiif/grammar.ex`, replace the `rotation/1` doc + clause (lines 81-95):

```elixir
  @doc """
  Parses a IIIF rotation token: an optional leading `!` (mirror = reflection on
  the vertical axis, applied before rotation) followed by a clockwise angle in
  the closed interval `[0, 360]` (any floating point number). `360` folds to `0`
  and whole-number floats fold to integers (so right angles take the lossless
  rotate path).

  Returns `{:ok, {mirror :: boolean, angle :: number}}` or
  `{:error, {:invalid_rotation, raw}}`.
  """
  @spec rotation(String.t()) ::
          {:ok, {boolean(), number()}}
          | {:error, {:invalid_rotation, String.t()}}
  def rotation(raw) do
    {mirror, rest} =
      case raw do
        "!" <> rest -> {true, rest}
        rest -> {false, rest}
      end

    case parse_rotation_angle(rest) do
      {:ok, angle} -> {:ok, {mirror, angle}}
      :error -> {:error, {:invalid_rotation, raw}}
    end
  end

  # Strict remainder ("" only) like every other numeric token in this grammar:
  # rejects "45.", ".5", "45deg", "+45", leading/trailing whitespace, "" ("!"
  # alone). Float.parse handles ints too, so "90" -> 90.0 -> normalized to 90.
  defp parse_rotation_angle(string) do
    case Float.parse(string) do
      {value, ""} when value >= 0.0 and value <= 360.0 -> {:ok, normalize_rotation(value)}
      _ -> :error
    end
  end

  defp normalize_rotation(360.0), do: 0

  defp normalize_rotation(value) do
    truncated = trunc(value)
    if value == truncated, do: truncated, else: value
  end
```

- [ ] **Step 4: Run grammar test to verify it passes**

Run: `mise exec -- mix test test/parser/iiif/grammar_test.exs`
Expected: PASS.

- [ ] **Step 5: Update plan_builder tests (red)**

In `test/parser/iiif/plan_builder_test.exs`:
- update the `import`/alias line 6 to also alias `Flip`: `alias ImagePipe.Plan.Operation.{Bitonal, CropGuided, CropRegion, Flip, Gray, Resize, Rotate}`.
- change **every** `rotation:` value in a token map to the tuple form: `rotation: 90 → {false, 90}`, `rotation: 0 → {false, 0}`, `rotation: 180 → {false, 180}`. Run `grep -n "rotation:" test/parser/iiif/plan_builder_test.exs` first — there are ~17 occurrences (incl. the "rotation 180 emits rotate op" test); update all of them, or the file won't compile against the new tuple-only `rotation_operations/1`.
- existing assertions like `%Rotate{angle: 90}` / `%Rotate{angle: 180}` stay (mirror defaults false).
- add a new test:

```elixir
  test "arbitrary angle emits a Rotate op with the angle" do
    {:ok, %Plan{pipelines: [%{operations: ops}]}} =
      build(%{region: :full, size: {:max, false}, rotation: {false, 45}, quality: :default, format: :png})

    assert [%Resize{}, %Rotate{angle: 45, mirror: false}] = ops
  end

  test "mirror + angle emits a mirrored Rotate op" do
    {:ok, %Plan{pipelines: [%{operations: ops}]}} =
      build(%{region: :full, size: {:max, false}, rotation: {true, 90}, quality: :default, format: :png})

    assert [%Resize{}, %Rotate{angle: 90, mirror: true}] = ops
  end

  test "mirror with zero angle emits a horizontal Flip (no Rotate)" do
    {:ok, %Plan{pipelines: [%{operations: ops}]}} =
      build(%{region: :full, size: {:max, false}, rotation: {true, 0}, quality: :default, format: :png})

    assert [%Resize{}, %Flip{axis: :horizontal}] = ops
  end
```

- [ ] **Step 6: Run plan_builder test to verify it fails**

Run: `mise exec -- mix test test/parser/iiif/plan_builder_test.exs`
Expected: FAIL — `rotation_operations/1` doesn't accept the tuple.

- [ ] **Step 7: Rewrite `rotation_operations/1` + add the `Flip` alias**

In `lib/image_pipe/parser/iiif/plan_builder.ex`, add to the alias block (near line 7):

```elixir
  alias ImagePipe.Plan.Operation.Flip
```

Replace `rotation_operations/1` (lines 150-156):

```elixir
  defp rotation_operations({false, 0}), do: {:ok, []}
  defp rotation_operations({true, 0}), do: {:ok, [%Flip{axis: :horizontal}]}

  defp rotation_operations({mirror, angle}) do
    with {:ok, op} <- Operation.rotate(angle, mirror) do
      {:ok, [op]}
    end
  end
```

- [ ] **Step 8: Run plan_builder test to verify it passes**

Run: `mise exec -- mix test test/parser/iiif/plan_builder_test.exs`
Expected: PASS.

- [ ] **Step 9: Advertise the new extraFeatures**

In `lib/image_pipe/parser/iiif/info.ex`, add to `@extra_features` (after `"rotationBy90s",`):

```elixir
    "rotationArbitrary",
    "mirroring",
```

- [ ] **Step 10: Fix the now-obsolete "rotation rejected" assertions (they break behaviorally here, not in Task 5)**

`45`/`!90` are now valid, so two existing assertions that expected rejection break the moment Task 4 lands. Fix them in THIS task so the boundary stays green:

- `test/parser/iiif/grammar_test.exs` — already handled in Step 1 (the whole rotation block was rewritten).
- `test/parser/iiif_test.exs` — find the "rotation 45 rejected" case (`grep -n "45" test/parser/iiif_test.exs`). Update it to assert `45` now parses (200 / `{:ok, ...}`), or switch the rejected token to an out-of-range one like `370` — match the file's existing assertion style.
- `test/parser/iiif_wire_test.exs` — the "contract 9c: bad rotation (45) → 400" test (`grep -n "9c\|/45/" test/parser/iiif_wire_test.exs`). Replace the invalid token with an out-of-range one:

```elixir
  test "contract 9c: out-of-range rotation (370) → 400" do
    conn = call_iiif("/img/full/max/370/default.png", iiif_opts(OriginImage))
    assert conn.status == 400
  end
```

- [ ] **Step 11: Run the IIIF parser + wire + compile gate**

Run: `mise exec -- mix test test/parser/iiif/ test/parser/iiif_test.exs test/parser/iiif_wire_test.exs && mise exec -- mix compile --warnings-as-errors`
Expected: PASS / clean (the obsolete assertions are fixed; the NEW arbitrary/mirror wire tests come in Task 5).

- [ ] **Step 12: Commit**

```bash
git add lib/image_pipe/parser/iiif/grammar.ex lib/image_pipe/parser/iiif/plan_builder.ex lib/image_pipe/parser/iiif/info.ex test/parser/iiif/grammar_test.exs test/parser/iiif/plan_builder_test.exs test/parser/iiif_test.exs test/parser/iiif_wire_test.exs
git commit -m "feat(iiif): parse arbitrary rotation + mirroring; advertise features (#257)"
```

---

## Task 5: IIIF wire conformance (end-to-end, new behavior)

Make real `ImagePipe.call/2` requests asserting status, dimensions, and transparency for the new arbitrary/mirror behavior. (The obsolete `45 → 400` assertions were already fixed in Task 4.)

**Files:**
- Modify: `test/parser/iiif_wire_test.exs`

**Note on materialization failure → 415:** the new `Transform.Operation.Rotate` is `requires_materialization?: true`, so a `copy_memory` failure flows through the *generic, op-agnostic* `Chain` → `{:materialize_error, _}` → `Request.Processor` → `{:decode, _}` → 415 path (same as `Trim`). No op-specific wiring exists, and forcing a `copy_memory` failure on a valid request is contrived — so no dedicated rotate-415 test is added; the inherited mapping is covered by the existing materialization tests. (Confirm during execution that the op's own `{:error, {__MODULE__, _}}` execute-time errors — which only fire on a libvips failure for a valid materialized image, effectively never — are not mistaken for the materialization path.)

- [ ] **Step 1: Write the failing arbitrary-rotation + mirror wire tests**

Add to `test/parser/iiif_wire_test.exs` (near the other contracts):

```elixir
  # ---------------------------------------------------------------------------
  # rot_non90: arbitrary rotation → grown bounding box + transparent corners (png)
  # ---------------------------------------------------------------------------
  test "rot_non90: 45° on png → larger image with a transparent corner" do
    conn = call_iiif("/img/full/max/45/default.png", iiif_opts(OriginImage))
    assert conn.status == 200

    img = decoded_image(conn)
    assert Image.width(img) > 200 and Image.height(img) > 300
    assert Image.has_alpha?(img)
    assert List.last(Image.get_pixel!(img, 0, 0)) == 0
  end

  test "rot_non90: 45° on jpg → opaque (corners flattened onto background)" do
    conn = call_iiif("/img/full/max/45/default.jpg", iiif_opts(OriginImage))
    assert conn.status == 200

    img = decoded_image(conn)
    refute Image.has_alpha?(img)
  end

  # ---------------------------------------------------------------------------
  # rot_mirror: !n mirrors before rotating
  # ---------------------------------------------------------------------------
  test "rot_mirror: !90 → 200 quarter-turn (lossless dims swapped)" do
    conn = call_iiif("/img/full/max/!90/default.png", iiif_opts(OriginImage))
    assert conn.status == 200

    img = decoded_image(conn)
    # source 200x300 -> 90° turn -> 300x200
    assert Image.width(img) == 300 and Image.height(img) == 200
  end

  test "rot_mirror: percent-encoded ! (%2190) ≡ !90" do
    conn = call_iiif("/img/full/max/%2190/default.png", iiif_opts(OriginImage))
    assert conn.status == 200
  end
```

(If `call_iiif`/`decoded_image`/`iiif_opts` helper names differ, copy the exact pattern used by the existing contract-2b bitonal test in this file.)

- [ ] **Step 2: Run the wire tests to verify they pass**

Run: `mise exec -- mix test test/parser/iiif_wire_test.exs`
Expected: the new tests reference already-implemented behavior (Tasks 1-4), so they should PASS once the URL-decode of `%2190` and routing are correct. If `rot_mirror !90` fails on dimensions, confirm the chain op path runs (Task 3). If any helper name is wrong, fix per the existing tests.

- [ ] **Step 3: Run the whole IIIF test tree**

Run: `mise exec -- mix test test/parser/iiif_wire_test.exs test/parser/iiif_test.exs`
Expected: PASS.

- [ ] **Step 4: Commit**

```bash
git add test/parser/iiif_wire_test.exs
git commit -m "test(iiif): wire conformance for arbitrary rotation + mirroring (#257)"
```

---

## Task 6: Demo (fiddle) controls + URL state

Add an arbitrary-angle input + mirror toggle to the IIIF demo and its URL-path state. The `IiifState.rotation` shape changes from `number` to `{ degrees, mirror }`, so every `.rotation` use site updates. (The imgproxy `rotate` option in `fiddle-url-state.ts` `parseRotate` is unrelated and must NOT change.)

**Files:**
- Modify: `fiddle/assets/iiif-path.ts`, `fiddle/assets/IiifControls.svelte`, `fiddle/assets/iiif-path.test.ts`, `fiddle/assets/fiddle-url-state.test.ts`

**All `.rotation` use sites** (verified — update every one): `iiif-path.ts` (type/state/tail/parse), `IiifControls.svelte` (summary + control), `iiif-path.test.ts` (encode/round-trip/parse tests), and `fiddle/assets/fiddle-url-state.test.ts:38` (`expect(parsed.iiif.rotation).toBe(90)`). `App.svelte` binds the whole `iiifState` object and never reads `.rotation`, so it needs no change.

- [ ] **Step 1: Update the failing TS path tests (red)**

In `fiddle/assets/fiddle-url-state.test.ts`, line ~38 (the parse round-trip through the signed URL):
```ts
    expect(parsed.iiif.rotation).toEqual({ degrees: 90, mirror: false });
```

In `fiddle/assets/iiif-path.test.ts`:
- the `encodes rotation, quality, format` test (line ~73-76): change `rotation: 90` to `rotation: { degrees: 90, mirror: false }`; the expected tail keeps `.../90/...`.
- the round-trip test (line ~97): change `rotation: 270` to `rotation: { degrees: 270, mirror: false }`.
- the "bad rotation" parse test (line ~108): `parseIiifTail("dog/full/max/45/default.jpg")` is now **valid** — change the expectation to assert it parses, and add a genuinely bad token:

```ts
  it("parses arbitrary + mirror rotation", () => {
    expect(parseIiifTail("dog/full/max/45/default.jpg")?.iiif?.rotation ?? null).toEqual({
      degrees: 45,
      mirror: false,
    });
    expect(parseIiifTail("dog/full/max/!90/default.jpg")?.iiif?.rotation ?? null).toEqual({
      degrees: 90,
      mirror: true,
    });
    expect(parseIiifTail("dog/full/max/370/default.jpg")).toBeNull(); // out of range
  });
```

(Adjust the `?.iiif?.rotation` accessor to match `parseIiifTail`'s actual return shape — check the existing line-38 usage `parsed.iiif.rotation`.)

- [ ] **Step 2: Run the TS tests to verify they fail**

Run: `pnpm -C fiddle test iiif-path`
Expected: FAIL — type/shape mismatch.

- [ ] **Step 3: Widen the `IiifRotation` type + state in `iiif-path.ts`**

- Replace line 17:

```ts
export type IiifRotation = { degrees: number; mirror: boolean };
```

- Remove the now-unused `iiifRotations` const (line 33) and any reference to it.
- `defaultIiifState.rotation` (line 55):

```ts
  rotation: { degrees: 0, mirror: false },
```

- The tail builder (line 104) — change `${state.rotation}` to:

```ts
  const rotation = `${state.rotation.mirror ? "!" : ""}${state.rotation.degrees}`;
```

and use `rotation` in the template (it already has a `rotation` segment variable for the region/size; introduce a local or inline the expression consistently with how `region`/`size` segments are built).

- Replace `parseRotation` (lines 197-201):

```ts
function parseRotation(token: string): IiifRotation | null {
  const mirror = token.startsWith("!");
  const body = mirror ? token.slice(1) : token;
  if (!/^\d+(\.\d+)?$/.test(body)) return null;
  const degrees = Number(body);
  if (!Number.isFinite(degrees) || degrees < 0 || degrees > 360) return null;
  return { degrees: degrees === 360 ? 0 : degrees, mirror };
}
```

- [ ] **Step 4: Run the TS tests to verify they pass**

Run: `pnpm -C fiddle test iiif-path`
Expected: PASS.

- [ ] **Step 5: Update the Svelte control**

In `fiddle/assets/IiifControls.svelte`:
- `rotationSummary` (line 27):

```svelte
  const rotationSummary = $derived(`${iiifState.rotation.mirror ? "!" : ""}${iiifState.rotation.degrees}°`);
```

- replace the Rotation `<select>` block (lines 223-231) with a number input + mirror toggle (reuse the `RangeNumber` and `Switch` components already imported for size/upscale):

```svelte
  <RangeNumber
    label="Degrees"
    bind:value={iiifState.rotation.degrees}
    min={0}
    max={360}
    step={1}
  />

  <label class="switch-field">
    <Switch.Root class="switch-root" bind:checked={iiifState.rotation.mirror}>
      <Switch.Thumb class="switch-thumb" />
    </Switch.Root>
    <span>Mirror (!)</span>
  </label>
```

This mirror toggle uses the **exact** markup of the existing upscale toggle (`<label class="switch-field">` with the `<span>` *after* the `Switch.Root` — verify against lines ~205-212). The `RangeNumber` props (`label`/`bind:value`/`min`/`max`/`step`) match its existing size-input usage.

- [ ] **Step 6: Run the fiddle check/lint/build**

Run: `pnpm -C fiddle check && pnpm -C fiddle test`
Expected: PASS — no type errors (every `iiifState.rotation` use now matches the object shape).

- [ ] **Step 7: Commit**

```bash
git add fiddle/assets/iiif-path.ts fiddle/assets/IiifControls.svelte fiddle/assets/iiif-path.test.ts fiddle/assets/fiddle-url-state.test.ts
git commit -m "feat(fiddle): IIIF arbitrary rotation + mirror controls (#257)"
```

---

## Task 7: Docs (support matrix) + final gates

Update the IIIF conformance doc on all three axes and run the full gate.

**Files:**
- Modify: `docs/iiif_3_support_matrix.md`

- [ ] **Step 1: Update the Rotation table row (surface axis)**

In `docs/iiif_3_support_matrix.md`, change the row (line ~52):

```markdown
| `!n` (mirroring), arbitrary angle | `mirroring`, `rotationArbitrary` (extra) | ✅ | `!` mirrors (horizontal flip) before rotating; any `[0,360)` angle. Right-angle non-mirrored rotation uses the lossless deferred `vips_rot` path; arbitrary or mirrored rotation runs as a materializing `Transform.Operation.Rotate` chain op. |
```

Update the Level-2 summary line (line ~21) and the "Deferred extraFeatures" line (line ~133) to drop `rotationArbitrary`/`mirroring` from the deferred list.

Also fix the now-partial claim at **line ~127**: it states "the IIIF rotation param folds into `pending_orientation` and is applied after the region crop." Scope it to right angles, e.g. "the IIIF rotation param folds into `pending_orientation` (right-angle, non-mirrored) and is applied after the region crop; an arbitrary or mirrored rotation instead runs as a materializing chain op (see below)." (`grep -n "folds into" docs/iiif_3_support_matrix.md` to locate.)

- [ ] **Step 2: Add the stage/order + behavioral note**

Under the Rotation section, add a paragraph:

```markdown
**Arbitrary/mirrored rotation (stage/order + behavioral, [#257](https://github.com/hlindset/image_pipe/issues/257)):** runs as a materializing `Transform.Operation.Rotate` chain op *after* resize, *before* quality. Because it is `requires_materialization?: true`, `Chain`/`Materializer` flushes the pending EXIF orientation first, so rotation lands in the display frame. Right-angle multiples (incl. when mirrored) use the lossless `vips_rot` primitive (no #211 seam); other angles use the affine `vips_rotate` with premultiplied alpha and a transparent background. Exposed corners are transparent; for a non-alpha output format the encoder flattens onto `Plan.Output.flatten_background` (IIIF defines no per-request fill knob). No imgproxy parity reference — imgproxy `rot` is right-angle only, so arbitrary rotation is IIIF-driven (IIIF spec is ground truth).
```

- [ ] **Step 3: Run the IIIF source-inventory / docs drift checks if any**

Run: `grep -rn "rotationArbitrary\|mirroring" docs/iiif_3_support_matrix.md lib/image_pipe/parser/iiif/info.ex`
Expected: the doc and `info.ex` agree (both advertise both features).

- [ ] **Step 4: Run the full Elixir gate**

Run: `mise run precommit`
Expected: `mix format --check-formatted`, `mix compile --warnings-as-errors`, `mix credo --strict`, `mix test` all PASS.

- [ ] **Step 5: Run the fiddle gate**

Run: `mise run precommit:fiddle`
Expected: Elixir gate + fiddle JS test/check/lint/format/build PASS.

- [ ] **Step 6: Commit**

```bash
git add docs/iiif_3_support_matrix.md
git commit -m "docs(iiif): rotationArbitrary + mirroring now supported (#257)"
```

---

## Self-review checklist (run before handing off to execution)

- **Spec coverage:** arbitrary rotation op (Task 2), mirror (Tasks 2/4), materialization gate + tests (Tasks 2/3), executor routing (Task 3), grammar/plan_builder/info (Task 4), wire tests (Task 5), fiddle (Task 6), docs (Task 7), cache key + validation gate (Task 1). ✓
- **No imgproxy disturbance:** `imgproxy/plan_builder.ex` unchanged (default `mirror` arg); `pending_orientation` untouched. ✓
- **Type consistency:** grammar returns `{:ok, {mirror, angle}}`; tokens map `rotation: {mirror, angle}`; `Operation.rotate(angle, mirror)`; both `Plan.Operation.Rotate` and `Transform.Operation.Rotate` carry `{angle, mirror}`; key_data emits `mirror`. ✓
- **TDD + green between tasks:** Task 4 changes the grammar return shape and updates plan_builder + both tests in the same task to stay green. ✓
```
