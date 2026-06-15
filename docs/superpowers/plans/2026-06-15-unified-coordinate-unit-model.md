# Unified coordinate/unit model — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Give ImagePipe one canonical coordinate/unit vocabulary (`{:px}` + exact `{:ratio}`) resolved by one shared module, remove the TwicPics parser gates, and ship relative-unit crop, zero-based crop coordinates, and relative-unit coordinate focus (issues #313 relative-coords, #314, #315).

**Architecture:** A new `ImagePipe.Plan.Measure` (plan boundary) owns the measure types + `percent`/`scale` → ratio conversion + role validators. `ImagePipe.Transform.Geometry` (transform boundary, unexported) gains exact-ratio resolution while **preserving each consumer's existing rounding** (dimensions half-away, positions/offsets ties-to-even). Parsers translate dialect syntax into canonical measures with no resolution and no premature gating. imgproxy and IIIF stay pixel-neutral by construction; the only pixel changes are the new TwicPics paths and a tie-only float-order change in native/TwicPics relative resize dims.

**Tech Stack:** Elixir, ExUnit, StreamData (property tests), Vix/`Image` (libvips), Svelte (fiddle), `mise` task runner.

**Spec:** [`docs/superpowers/specs/2026-06-15-unified-coordinate-unit-model-design.md`](../specs/2026-06-15-unified-coordinate-unit-model-design.md)

**Scope deltas from the spec (deliberate, after plan review):**
- **Role-named resolver functions deferred.** The spec §4.3 proposed `Geometry.resolve_dimension/resolve_position/resolve_focal`. This PR only adds the `{:ratio}` clause to `Geometry.to_pixels/2` (the minimum to make ratios resolvable); the existing `crop.ex`/`resize.ex` helpers keep their per-consumer rounding. Introducing the role functions without rewiring every consumer would be dead code; rewiring them is a behavior-preserving refactor deferred to a follow-up. The unification still lands: one canonical vocabulary + one ratio-aware `to_pixels`.
- **TwicPics `inside` stays px-only this PR.** Its resize+canvas composition entangles relative units with canvas aspect-ratio semantics (a px/relative mix hits `:mixed_canvas_units`; a both-relative `inside` would silently become an aspect-ratio canvas). `inside` is not named by #313/#314/#315; relative `inside` is a follow-up. Only `crop` (region + guided) loses its px-only gate.

**Conventions used throughout:**
- Run Elixir via `mise exec -- mix ...`.
- If this is a fresh worktree, first run: `mise trust && mise exec -- mix deps.get` (see project memory on fresh-worktree mise trust). If `mix format --check-formatted` fails repo-wide, check for a dangling untracked `.credo.exs` symlink and `rm` it.
- Commit after each task. Do **not** push.

---

## File Structure

**Create:**
- `lib/image_pipe/plan/measure.ex` — canonical measure types, `percent`/`scale` → exact ratio conversion, role validators (`dimension/1`, `position/1`).
- `test/image_pipe/plan/measure_test.exs` — `Measure` unit + property tests.

**Modify (plan boundary):**
- `lib/image_pipe/plan.ex` — add `Measure` to `exports:`.
- `lib/image_pipe/plan/operation/resize.ex` — `dimension` type → `:auto | {:px} | {:ratio}`.
- `lib/image_pipe/plan/operation.ex` — `tagged_resize_dimension/1` accepts `percent`/`scale` sugar, converts to ratio; delegates role rules to `Measure`.
- `lib/image_pipe/plan/key_data.ex` — drop dead `{:percent}`/`{:scale}` `data/1` clauses.

**Modify (transform boundary):**
- `lib/image_pipe/transform/geometry.ex` — add `{:ratio, n, d}` clause to `to_pixels/2`.
- `lib/image_pipe/transform/plan_executor.ex:826-834` — add `{:ratio}` clause to `tagged_executable_resize_dimension/1` (the Plan→transform bridge).
- `lib/image_pipe/transform/operation/resize.ex` — widen transform `@type dimension()` (line 28) to include `{:ratio}`; `resolve_relative_dimension/2` ratio clause; drop percent/scale clauses.
- (`lib/image_pipe/transform/operation/crop.ex` resolution helpers stay; only verified, not changed.)

**Modify (parser boundary):**
- `lib/image_pipe/parser/twic_pics/units.ex` — split `length/1` into `dimension_length/1` (>0) and `position_length/1` (≥0), both `p`/`s` → exact ratio.
- `lib/image_pipe/parser/twic_pics/plan_builder.ex` — delete `pixels_only/2` + the px-only crop gates; relative coordinate focus.

**Modify (docs / fiddle):**
- `docs/twicpics_support_matrix.md`, `docs/imgproxy_support_matrix.md`, `docs/iiif_3_support_matrix.md`.
- `fiddle/assets/TwicCropControls.svelte`, `TwicCropOriginPicker.svelte`, `TwicPicsControls.svelte`, `twicpics-path.ts`, `twicpics-path.test.ts`.

**Test files touched (verified paths):**
- `test/image_pipe/plan/measure_test.exs` (new), `test/image_pipe/transform/geometry_test.exs` (new or extend), `test/image_pipe/transform/resize_relative_resolution_property_test.exs` (rewrite — builds the transform struct directly), `test/image_pipe/plan/key_data_test.exs` + `test/image_pipe/plan/operation_key_data_test.exs` (update), `test/parser/twic_pics/units_test.exs` + `test/parser/twic_pics/plan_builder_test.exs` (extend), `test/image_pipe/twic_pics_wire_conformance_test.exs` (extend), `test/parser/iiif_wire_test.exs` (regression guard), `test/image_pipe/architecture_boundary_test.exs` (add export).

---

## Task 1: `Plan.Measure` — vocabulary, conversion, role validators

**Files:**
- Create: `lib/image_pipe/plan/measure.ex`
- Test: `test/image_pipe/plan/measure_test.exs`

`Measure` is the single source of truth for the canonical measure type and the `percent`/`scale` → exact `{:ratio, n, d}` conversion. Reductions are coprime (`Integer.gcd`). Float inputs convert via their 7-decimal string form (matching the existing `resize_dpr` precedent in `operation.ex`) so there is no float fuzz.

- [ ] **Step 1: Write the failing test**

```elixir
# test/image_pipe/plan/measure_test.exs
defmodule ImagePipe.Plan.MeasureTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias ImagePipe.Plan.Measure

  describe "from_percent/1" do
    test "integer percent reduces to a coprime ratio" do
      assert Measure.from_percent(50) == {:ok, {:ratio, 1, 2}}
      assert Measure.from_percent(100) == {:ok, {:ratio, 1, 1}}
      assert Measure.from_percent(0) == {:ok, {:ratio, 0, 1}}
    end

    test "float percent converts exactly via its decimal form" do
      assert Measure.from_percent(4.5) == {:ok, {:ratio, 9, 200}}
    end

    test "negative percent is rejected" do
      assert Measure.from_percent(-1) == {:error, :measure}
    end
  end

  describe "from_scale/1" do
    test "scale is a fraction of one" do
      assert Measure.from_scale(0.5) == {:ok, {:ratio, 1, 2}}
      assert Measure.from_scale(2) == {:ok, {:ratio, 2, 1}}
    end
  end

  describe "dimension/1 (extent: strictly positive)" do
    test "accepts positive px and ratio, rejects zero" do
      assert Measure.dimension({:px, 10}) == {:ok, {:px, 10}}
      assert Measure.dimension({:ratio, 1, 2}) == {:ok, {:ratio, 1, 2}}
      assert Measure.dimension({:px, 0}) == {:error, :dimension}
      assert Measure.dimension({:ratio, 0, 1}) == {:error, :dimension}
    end
  end

  describe "position/1 (coordinate: zero-based, non-negative)" do
    test "accepts zero and positive, rejects negative" do
      assert Measure.position({:px, 0}) == {:ok, {:px, 0}}
      assert Measure.position({:px, 10}) == {:ok, {:px, 10}}
      assert Measure.position({:ratio, 0, 1}) == {:ok, {:ratio, 0, 1}}
      assert Measure.position({:px, -1}) == {:error, :position}
    end
  end

  property "from_percent always yields a reduced, non-negative ratio" do
    check all n <- integer(0..10_000) do
      assert {:ok, {:ratio, num, den}} = Measure.from_percent(n)
      assert num >= 0 and den > 0
      assert Integer.gcd(num, den) == 1
    end
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mise exec -- mix test test/image_pipe/plan/measure_test.exs`
Expected: FAIL — `ImagePipe.Plan.Measure` is undefined.

- [ ] **Step 3: Write the module**

```elixir
# lib/image_pipe/plan/measure.ex
defmodule ImagePipe.Plan.Measure do
  @moduledoc """
  Canonical coordinate/unit vocabulary for the product-neutral Plan.

  A measure is either absolute pixels (`{:px, n}`) or an exact rational fraction
  of a reference dimension (`{:ratio, n, d}`). Dialect sugar (`percent`, `scale`)
  is converted here into the exact ratio form. Resolution of a measure against a
  running dimension happens in the transform boundary, not here.
  """

  @type t :: {:px, integer()} | {:ratio, integer(), pos_integer()}

  @doc "Convert a percentage (`50` → 1/2) to an exact ratio. Non-negative only."
  @spec from_percent(number()) :: {:ok, t()} | {:error, :measure}
  def from_percent(value) when is_integer(value) and value >= 0,
    do: reduce(value, 100)

  def from_percent(value) when is_float(value) and value >= 0.0 do
    with {:ok, {num, den}} <- decimal_fraction(value), do: reduce(num, den * 100)
  end

  def from_percent(_value), do: {:error, :measure}

  @doc "Convert a scale factor (`0.5` → 1/2, `2` → 2/1) to an exact ratio. Non-negative only."
  @spec from_scale(number()) :: {:ok, t()} | {:error, :measure}
  def from_scale(value) when is_integer(value) and value >= 0,
    do: reduce(value, 1)

  def from_scale(value) when is_float(value) and value >= 0.0 do
    with {:ok, {num, den}} <- decimal_fraction(value), do: reduce(num, den)
  end

  def from_scale(_value), do: {:error, :measure}

  @doc "Validate a measure in the *dimension* role (extent — strictly positive)."
  @spec dimension(term()) :: {:ok, t()} | {:error, :dimension}
  def dimension({:px, value}) when is_integer(value) and value > 0, do: {:ok, {:px, value}}

  def dimension({:ratio, num, den})
      when is_integer(num) and is_integer(den) and num > 0 and den > 0,
      do: {:ok, {:ratio, num, den}}

  def dimension(_measure), do: {:error, :dimension}

  @doc "Validate a measure in the *position* role (coordinate — zero-based, non-negative)."
  @spec position(term()) :: {:ok, t()} | {:error, :position}
  def position({:px, value}) when is_integer(value) and value >= 0, do: {:ok, {:px, value}}

  def position({:ratio, num, den})
      when is_integer(num) and is_integer(den) and num >= 0 and den > 0,
      do: {:ok, {:ratio, num, den}}

  def position(_measure), do: {:error, :position}

  # Exact decimal -> {numerator, denominator} via the 7-decimal string form,
  # mirroring operation.ex resize_dpr (no float rounding error).
  defp decimal_fraction(value) do
    value
    |> Float.round(7)
    |> :erlang.float_to_binary(decimals: 7)
    |> String.split(".", parts: 2)
    |> case do
      [whole, frac] ->
        digits = whole <> frac
        {:ok, {String.to_integer(digits), Integer.pow(10, byte_size(frac))}}

      [whole] ->
        {:ok, {String.to_integer(whole), 1}}
    end
  end

  defp reduce(_num, den) when den <= 0, do: {:error, :measure}

  defp reduce(num, den) when num >= 0 do
    gcd = max(1, Integer.gcd(num, den))
    {:ok, {:ratio, div(num, gcd), div(den, gcd)}}
  end

  defp reduce(_num, _den), do: {:error, :measure}
end
```

- [ ] **Step 4: Run test to verify it passes**

Run: `mise exec -- mix test test/image_pipe/plan/measure_test.exs`
Expected: PASS (all examples + property).

- [ ] **Step 5: Commit**

```bash
git add lib/image_pipe/plan/measure.ex test/image_pipe/plan/measure_test.exs
git commit -m "feat(plan): add Plan.Measure canonical vocabulary + percent/scale->ratio"
```

---

## Task 2: Export `Plan.Measure` from the plan boundary

**Files:**
- Modify: `lib/image_pipe/plan.ex:9-43` (the `exports:` list)
- Test: `test/image_pipe/architecture_boundary_test.exs` (the exact-match `assert_boundary_exports(plan, [...])` assertion)

The boundary export assertion is exact — adding the module to one without the other breaks the build either way, so do both.

- [ ] **Step 1: Add to the exports list**

In `lib/image_pipe/plan.ex`, add `Measure,` to the `exports:` list (alongside `KeyData`):

```elixir
      KeyData,
      Measure,
      Source,
```

- [ ] **Step 2: Add to the architecture test assertion**

In `test/image_pipe/architecture_boundary_test.exs`, find `assert_boundary_exports(plan, [` and add the **fully-qualified** `ImagePipe.Plan.Measure,` to that list (the test compares fully-qualified names, unlike the bare `Measure,` in `plan.ex` exports; keep it sorted alongside `ImagePipe.Plan.KeyData`).

- [ ] **Step 3: Verify build + boundary test**

Run: `mise exec -- mix compile --warnings-as-errors && mise exec -- mix test test/image_pipe/architecture_boundary_test.exs`
Expected: PASS (no boundary violations, exact-export assertion satisfied).

- [ ] **Step 4: Commit**

```bash
git add lib/image_pipe/plan.ex test/image_pipe/architecture_boundary_test.exs
git commit -m "chore(plan): export Plan.Measure from the plan boundary"
```

---

## Task 3: `Geometry.to_pixels/2` — exact-ratio resolution

**Files:**
- Modify: `lib/image_pipe/transform/geometry.ex`
- Test: `test/image_pipe/transform/geometry_test.exs` (create if absent)

Add a single `{:ratio, n, d}` clause to `to_pixels/2`. This is the minimum needed for ratio measures to resolve; it reuses the same arithmetic + rounding (`round/1`, half-away) as the existing `{:scale, num, den}` clause, so it is purely additive and behavior-preserving for every current caller.

> Role-named resolver functions (`resolve_dimension`/`resolve_position`/`resolve_focal`) are **deferred** — see "Scope deltas from the spec" at the top. They would be dead code unless `crop.ex`/`resize.ex` are rewired through them, which is a separate behavior-preserving refactor.

- [ ] **Step 1: Write the failing test**

```elixir
# test/image_pipe/transform/geometry_test.exs
defmodule ImagePipe.Transform.GeometryTest do
  use ExUnit.Case, async: true

  alias ImagePipe.Transform.Geometry

  describe "to_pixels/2 with {:ratio, n, d}" do
    test "resolves a ratio against a reference (half-away rounding, same as :scale)" do
      assert Geometry.to_pixels(200, {:ratio, 1, 2}) == 100
      assert Geometry.to_pixels(5, {:ratio, 1, 2}) == 3
      assert Geometry.to_pixels(300, {:ratio, 1, 3}) == 100
    end
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mise exec -- mix test test/image_pipe/transform/geometry_test.exs`
Expected: FAIL — `to_pixels/2` has no `{:ratio, …}` clause.

- [ ] **Step 3: Add the clause**

In `lib/image_pipe/transform/geometry.ex`, add the `{:ratio, n, d}` clause next to the `{:scale, num, den}` clause:

```elixir
  def to_pixels(length, {:scale, numerator, denominator}),
    do: round(length * numerator / denominator)

  def to_pixels(length, {:ratio, numerator, denominator}),
    do: round(length * numerator / denominator)

  def to_pixels(length, {:percent, percent}), do: round(percent / 100 * length)
```

- [ ] **Step 4: Run the new test + the existing transform tests**

Run: `mise exec -- mix test test/image_pipe/transform/geometry_test.exs test/image_pipe/transform/`
Expected: PASS. (Additive clause; existing call sites untouched.)

- [ ] **Step 5: Commit**

```bash
git add lib/image_pipe/transform/geometry.ex test/image_pipe/transform/geometry_test.exs
git commit -m "feat(transform): Geometry.to_pixels resolves exact {:ratio} measures"
```

---

## Task 4: Normalize `Resize` dimensions to px + ratio (both layers)

**Files:**
- Modify: `lib/image_pipe/plan/operation/resize.ex:21` (Plan-layer `dimension` type)
- Modify: `lib/image_pipe/plan/operation.ex:597-608` (`tagged_resize_dimension/1`)
- Modify: `lib/image_pipe/transform/plan_executor.ex:826-834` (`tagged_executable_resize_dimension/1` — the Plan→transform bridge)
- Modify: `lib/image_pipe/transform/operation/resize.ex:28` (transform-layer `@type dimension()`) and `:209-215` (`resolve_relative_dimension/2`)
- Test: `test/image_pipe/transform/resize_relative_resolution_property_test.exs` (rewrite — it builds the **transform** struct directly); native-API pixel test (see Step 7)

There are **two** `Resize` structs: `ImagePipe.Plan.Operation.Resize` (the parsed Plan) and `ImagePipe.Transform.Operation.Resize` (the executable). The `PlanExecutor` bridges them via `tagged_executable_resize_dimension/1`. **Both** layers and the bridge must learn `{:ratio}`, or every relative resize crashes (e.g. the existing wire test `resize=340/resize=50p`). The native constructor keeps accepting `percent`/`scale` *sugar* and converts to a stored `{:ratio}` via `Plan.Measure`; the bridge passes `{:ratio}` straight through; the executor's `resolve_relative_dimension` resolves it to `{:pixels, px}` (downstream unchanged).

- [ ] **Step 1: Update both struct types**

In `lib/image_pipe/plan/operation/resize.ex`, change the Plan-layer `dimension` type:

```elixir
  @type dimension :: :auto | {:px, pos_integer()} | {:ratio, pos_integer(), pos_integer()}
```

In `lib/image_pipe/transform/operation/resize.ex:28`, widen the transform-layer type to add `{:ratio}` (keep the rest as-is):

```elixir
  @type dimension() :: :auto | pixels() | {:ratio, pos_integer(), pos_integer()} | {:percent, number()} | {:scale, number()}
```

(Keeping `{:percent}`/`{:scale}` in the transform type is harmless — nothing produces them anymore after this task — but `{:ratio}` must be added.)

- [ ] **Step 2: Rewrite the property test (failing first)**

`test/image_pipe/transform/resize_relative_resolution_property_test.exs` builds the **transform** struct *directly* (`%ImagePipe.Transform.Operation.Resize{width: {:percent, percent}}`) — it does **not** go through the Plan constructor. So two edits: (a) build `width: {:ratio, num, den}` (the new transform tag), and (b) assert the RHS in ratio order. Example shape:

```elixir
# choose a ratio directly (or derive from a percent via Measure for parity with the parser):
{:ok, {:ratio, num, den}} = ImagePipe.Plan.Measure.from_percent(percent)
op = %ImagePipe.Transform.Operation.Resize{width: {:ratio, num, den}, height: :auto, ...}
result = ImagePipe.Transform.Operation.Resize.resolve_dimensions(op, source)
expected = max(1, round(source.width * num / den))
assert result.intermediate_width == expected
```

Mirror for the scale branch (`Measure.from_scale/1`) and for height. Keep the StreamData generators as-is.

- [ ] **Step 3: Run the property test to see it fail against current code**

Run: `mise exec -- mix test test/image_pipe/transform/resize_relative_resolution_property_test.exs`
Expected: FAIL — the transform `resolve_relative_dimension` has no `{:ratio}` clause yet, so `{:ratio}` falls through the `other` passthrough and isn't resolved.

- [ ] **Step 4: Update the Plan constructor to convert sugar → ratio**

In `lib/image_pipe/plan/operation.ex`, replace `tagged_resize_dimension/1` (lines 597-608) with:

```elixir
  defp tagged_resize_dimension(:auto), do: {:ok, :auto}

  defp tagged_resize_dimension({:px, value}) when is_integer(value) and value > 0,
    do: {:ok, {:px, value}}

  defp tagged_resize_dimension({:ratio, _num, _den} = ratio),
    do: ImagePipe.Plan.Measure.dimension(ratio) |> rewrap_dimension()

  defp tagged_resize_dimension({:percent, value}) when is_number(value) and value > 0,
    do: ImagePipe.Plan.Measure.from_percent(value) |> rewrap_dimension()

  defp tagged_resize_dimension({:scale, value}) when is_number(value) and value > 0,
    do: ImagePipe.Plan.Measure.from_scale(value) |> rewrap_dimension()

  defp tagged_resize_dimension(_dimension), do: {:error, :dimension}

  defp rewrap_dimension({:ok, {:ratio, _, _}} = ok), do: ok
  defp rewrap_dimension({:error, _}), do: {:error, :dimension}
```

(`from_percent`/`from_scale` already guarantee `> 0` for the values reaching here; `Measure.dimension/1` enforces `> 0` for a directly-supplied ratio.)

- [ ] **Step 5: Update the Plan→transform bridge**

In `lib/image_pipe/transform/plan_executor.ex`, add a `{:ratio}` clause to `tagged_executable_resize_dimension/1` (after line 829) so the stored ratio reaches the transform struct intact. Drop the now-unreachable `{:percent}`/`{:scale}` clauses (the Plan layer no longer stores them):

```elixir
  defp tagged_executable_resize_dimension(:auto), do: :auto
  defp tagged_executable_resize_dimension({:px, value}), do: {:pixels, value}
  defp tagged_executable_resize_dimension({:ratio, numerator, denominator}),
    do: {:ratio, numerator, denominator}
```

(`tagged_executable_resize_dimension/1` is also used for `min_width`/`min_height` via line 834's optional path — the same clauses cover those.)

- [ ] **Step 6: Update the transform executor to resolve ratio dimensions**

In `lib/image_pipe/transform/operation/resize.ex`, replace the `{:percent}`/`{:scale}` clauses of `resolve_relative_dimension/2` (lines 209-213) with a single ratio clause (output shape identical — `{:pixels, max(1, …)}`):

```elixir
  defp resolve_relative_dimension({:ratio, _, _} = unit, length),
    do: {:pixels, max(1, to_pixels(length, unit))}

  defp resolve_relative_dimension(other, _length), do: other
```

- [ ] **Step 7: Add a native-API pixel test incl. a tie case**

In the existing resize transform/wire test file (e.g. `test/image_pipe/transform/resize_test.exs` — pick the file that already decodes resize output; if none, add to `resize_relative_resolution_property_test.exs` as an example test), add a decode-and-compare test:

```elixir
test "native percent resize resolves via exact ratio (tie case)" do
  # 5px wide source, 50% -> 5 * 1/2 = 2.5 -> round/1 half-away -> 3px
  {:ok, op} = ImagePipe.Plan.Operation.resize(:fit, {:percent, 50}, :auto)
  assert %ImagePipe.Plan.Operation.Resize{width: {:ratio, 1, 2}} = op
  # decode a 5x10 source through this op and assert width == 3
  # (use the file's existing decode helper / fixture)
end
```

Use the test file's established decode helper to assert the output width. The key assertions: the stored dimension is `{:ratio, 1, 2}` (not `{:percent, 50}`), and the decoded width matches `round(5 * 1/2) = 3`.

- [ ] **Step 8: Run the resize tests + the TwicPics wire test (existing relative-resize regression)**

Run: `mise exec -- mix test test/image_pipe/transform/ test/image_pipe/twic_pics_wire_conformance_test.exs`
Expected: PASS — in particular the existing `resize=340/resize=50p` and `resize=4s` wire cases must still pass (they exercise the full Plan→bridge→executor path the bridge clause in Step 5 fixes).

- [ ] **Step 9: Commit**

```bash
# include the resize pixel-test file you added the native tie-case to in Step 7
git add lib/image_pipe/plan/operation/resize.ex lib/image_pipe/plan/operation.ex \
        lib/image_pipe/transform/plan_executor.ex \
        lib/image_pipe/transform/operation/resize.ex \
        test/image_pipe/transform/resize_relative_resolution_property_test.exs
git commit -m "feat(plan): normalize Resize relative dims to exact ratio, both layers (#315 groundwork)"
```

---

## Task 5: KeyData — drop dead percent/scale clauses, confirm key collapse

**Files:**
- Modify: `lib/image_pipe/plan/key_data.ex:173-177` (the `{:percent}`/`{:scale}` `data/1` clauses)
- Test: `test/image_pipe/plan/key_data_test.exs` and `test/image_pipe/plan/operation_key_data_test.exs`

Once `Resize` stores `{:ratio}`, the `{:percent}`/`{:scale}` `data/1` clauses have no in-repo producer. `data({:ratio, …})` (line 179) already encodes ratios, so `50p` and `0.5s` (both stored as `{:ratio, 1, 2}`) now produce the **same** key.

- [ ] **Step 1: Update the key_data tests (failing first)**

In `test/image_pipe/plan/key_data_test.exs` (and `test/image_pipe/plan/operation_key_data_test.exs` if it has the same assertions), find the cases that feed `{:percent, 50}` / `{:scale, 0.5}` into `Operation.resize` and assert *distinct* encodings (`unit: :percent` / `unit: :scale`). Rewrite them to assert the **stored ratio** encoding and the **collapse**:

```elixir
test "percent and scale resize dimensions collapse to the same ratio key" do
  {:ok, percent_op} = ImagePipe.Plan.Operation.resize(:fit, {:percent, 50}, :auto)
  {:ok, scale_op} = ImagePipe.Plan.Operation.resize(:fit, {:scale, 0.5}, :auto)
  assert ImagePipe.Plan.KeyData.data(percent_op) == ImagePipe.Plan.KeyData.data(scale_op)
end
```

Remove any assertion asserting `unit: :percent` / `unit: :scale` for resize dimensions.

- [ ] **Step 2: Run to confirm the old assertions fail**

Run: `mise exec -- mix test test/image_pipe/plan/key_data_test.exs test/image_pipe/plan/operation_key_data_test.exs`
Expected: the old `unit: :percent` / `unit: :scale` assertions FAIL (Task 4 now stores `{:ratio}`); the new collapse test PASSES. Confirm the files no longer assert distinct percent/scale encodings.

- [ ] **Step 3: Confirm no remaining producer, then delete dead clauses**

Search for producers of `{:percent, _}` / `{:scale, _}` *dimension* values reaching `KeyData.data/1`:

Run: `mise exec -- rg -n "\{:percent," lib/ ; mise exec -- rg -n "\{:scale," lib/`

If the only remaining producers are crop *offsets* (`crop_offset`/`{:scale, n}` on `CropGuided`/`Resize` offsets — these go through `x_offset`/`y_offset`, encoded as raw values at `key_data.ex:101-102`, **not** through `data/1`), then the `data({:percent})` / `data({:scale})` clauses are dead for KeyData. Delete lines 173-177:

```elixir
  def data({:px, value}) when is_integer(value) and value >= 0,
    do: [unit: :logical_px, value: value]

  def data({:ratio, numerator, denominator})
      when is_integer(numerator) and is_integer(denominator) and numerator >= 0 and
             denominator > 0 do
    ratio_data(numerator, denominator)
  end
```

If a producer remains (e.g. some other op still emits `{:percent}`/`{:scale}` through `data/1`), keep the clauses and note it — do not force-delete.

- [ ] **Step 4: Run key_data + cache tests**

Run: `mise exec -- mix test test/image_pipe/plan/key_data_test.exs test/image_pipe/plan/operation_key_data_test.exs test/image_pipe/cache_test.exs`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add lib/image_pipe/plan/key_data.ex test/image_pipe/plan/key_data_test.exs test/image_pipe/plan/operation_key_data_test.exs
git commit -m "refactor(cache): ratio key encoding for resize dims; 50p/0.5s collapse"
```

---

## Task 6: TwicPics units — split dimension/position lengths, p/s → ratio

**Files:**
- Modify: `lib/image_pipe/parser/twic_pics/units.ex`
- Test: `test/parser/twic_pics/units_test.exs`

Split `length/1` into `dimension_length/1` (px `> 0`) and `position_length/1` (px `≥ 0`). Both convert `p`/`s` to exact `{:ratio, n, d}` via the file's existing `decimal_term`/`scaled_integer` machinery (string-exact). The percent denominator is `× 100`; scale is as-is. `position_length` allows zero.

- [ ] **Step 1: Write the failing test**

```elixir
# in the TwicPics units test file
describe "dimension_length/1 (>0)" do
  test "pixels, percent, scale" do
    assert Units.dimension_length("100") == {:ok, {:px, 100}}
    assert Units.dimension_length("50p") == {:ok, {:ratio, 1, 2}}
    assert Units.dimension_length("0.5s") == {:ok, {:ratio, 1, 2}}
    assert Units.dimension_length("0") == {:error, {:invalid_length, "0"}}
    assert Units.dimension_length("0p") == {:error, {:invalid_length, "0p"}}
  end
end

describe "position_length/1 (>=0)" do
  test "allows zero pixels and zero percent" do
    assert Units.position_length("0") == {:ok, {:px, 0}}
    assert Units.position_length("0p") == {:ok, {:ratio, 0, 1}}
    assert Units.position_length("50p") == {:ok, {:ratio, 1, 2}}
    assert Units.position_length("-1") == {:error, {:invalid_length, "-1"}}
  end
end

describe "coordinates/1 uses position lengths" do
  test "zero-based origin" do
    assert Units.coordinates("0x0") == {:ok, {{:px, 0}, {:px, 0}}}
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mise exec -- mix test test/parser/twic_pics/units_test.exs`
Expected: FAIL — `dimension_length/1`, `position_length/1` undefined; `coordinates("0x0")` currently errors.

- [ ] **Step 3: Implement the split in `units.ex`**

Replace `length/1`, `pixels/1`, `percent/1`, `scale/1` with dimension/position variants that emit ratios. Keep `decimal_term`/`scaled_integer` as-is (they reject zero) and add a zero-allowing decimal parse for positions. Concretely:

```elixir
  @type measure :: {:px, non_neg_integer()} | {:ratio, non_neg_integer(), pos_integer()}

  # Dimension length: strictly positive.
  @spec dimension_length(String.t()) :: {:ok, measure()} | {:error, term()}
  def dimension_length(value), do: parse_length(value, :positive)

  # Position length: zero-based, non-negative.
  @spec position_length(String.t()) :: {:ok, measure()} | {:error, term()}
  def position_length(value), do: parse_length(value, :non_negative)

  defp parse_length("-" <> _ = value, _sign), do: {:error, {:invalid_length, value}}

  defp parse_length(value, sign) when is_binary(value) do
    cond do
      String.ends_with?(value, "p") -> to_ratio(String.trim_trailing(value, "p"), 100, sign, value)
      String.ends_with?(value, "s") -> to_ratio(String.trim_trailing(value, "s"), 1, sign, value)
      true -> to_pixels_measure(value, sign)
    end
  end

  defp to_pixels_measure(value, sign) do
    case Integer.parse(value) do
      {n, ""} when n > 0 -> {:ok, {:px, n}}
      {0, ""} when sign == :non_negative -> {:ok, {:px, 0}}
      _ -> {:error, {:invalid_length, value}}
    end
  end

  # `decimal_term` parses a strictly-positive decimal into {integer, exponent}.
  # For positions we also accept "0"/"0.0" as {0, 0}.
  defp to_ratio(decimal, unit_denominator, sign, raw) do
    case decimal_measure(decimal, sign) do
      {:ok, {n, exp}} ->
        denominator = unit_denominator * Integer.pow(10, exp)
        gcd = max(1, Integer.gcd(n, denominator))
        {:ok, {:ratio, div(n, gcd), div(denominator, gcd)}}

      :error ->
        {:error, {:invalid_length, raw}}
    end
  end

  defp decimal_measure(decimal, sign) do
    case decimal_term(decimal) do
      {:ok, term} -> {:ok, term}
      :error when sign == :non_negative -> zero_decimal(decimal)
      :error -> :error
    end
  end

  defp zero_decimal(decimal) do
    case Float.parse(decimal) do
      {0.0, ""} -> {:ok, {0, 0}}
      _ -> case Integer.parse(decimal) do
             {0, ""} -> {:ok, {0, 0}}
             _ -> :error
           end
    end
  end
```

Update `coordinates/1` to use `position_length/1`:

```elixir
  def coordinates(value) do
    with [x, y] <- String.split(value, "x", parts: 2),
         {:ok, x} <- position_length(x),
         {:ok, y} <- position_length(y) do
      {:ok, {x, y}}
    else
      _ -> {:error, {:invalid_coordinates, value}}
    end
  end
```

Update `size/1` / `crop_size/1`'s internal `dimension/2` helper to call `dimension_length/1` (was `length/1`). Remove the now-unused `length/1`, `pixels/1`, `percent/1`, `scale/1` clauses (keep `number/1`, `decimal_term/1`, `scaled_integer/1`, `ratio/1`, `anchor/1`). Also update the `@type length` definition and every `@spec` that referenced `length()` (on `size/1`, `crop_size/1`, `coordinates/1`) to use the new `measure()` type — the compiler will flag any you miss.

- [ ] **Step 4: Run the units tests**

Run: `mise exec -- mix test test/parser/twic_pics/units_test.exs`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add lib/image_pipe/parser/twic_pics/units.ex test/parser/twic_pics/units_test.exs
git commit -m "feat(twicpics): dimension/position length split; p/s -> exact ratio; zero-based coords"
```

---

## Task 7: TwicPics plan_builder — remove px-only crop gates (#314, #315)

**Files:**
- Modify: `lib/image_pipe/parser/twic_pics/plan_builder.ex`
- Test: `test/image_pipe/twic_pics_wire_conformance_test.exs`

Remove the px-only gates on **crop** only: the `region_size` px-gate, the `crop_coordinates` px-gate, and the `pixels_only/2` call inside `crop_guided`. `crop_region` and `crop_guided` now accept ratio + zero; a region crop still requires both axes explicit. **`inside` stays px-only** (keep its `pixels_only/2` call) — its resize+canvas composition entangles relative units with canvas aspect-ratio semantics (see "Scope deltas" at top). Keep `pixels_only/2` + `pixel_dimension?/1` (still used by `inside`).

- [ ] **Step 1: Write the failing wire tests**

```elixir
# test/image_pipe/twic_pics_wire_conformance_test.exs
test "crop=WxH@0x0 crops from the top-left" do
  # Build ?twic=v1/crop=100x100@0x0 against a known fixture, call ImagePipe.call/2,
  # decode the body, assert dims 100x100 and that the top-left pixel matches the
  # source top-left (use the file's existing decode + pixel helper).
end

test "relative crop dims and coordinates produce expected geometry" do
  # ?twic=v1/crop=50px50p  (W=50px, H=50%) and crop=200x200@(1/3)sx0.5s
  # assert 200 status + decoded dims; compare against a px-equivalent baseline.
end

test "crop dimensions still reject zero" do
  # ?twic=v1/crop=0x100 -> 400 (or the file's documented error contract)
end
```

- [ ] **Step 2: Run to verify failure**

Run: `mise exec -- mix test test/image_pipe/twic_pics_wire_conformance_test.exs`
Expected: FAIL — `@0x0` and relative crop currently return the parser's rejection.

- [ ] **Step 3: Remove the gates**

In `lib/image_pipe/parser/twic_pics/plan_builder.ex`:

Replace `region_size/1` (lines 125-131) so it accepts any explicit dimension measure on both axes (still rejecting an omitted axis):

```elixir
  defp region_size(size) do
    case Units.size(size) do
      {:ok, {w, h}} when w != :auto and h != :auto -> {:ok, {w, h}}
      {:ok, _partial} -> {:error, {:unsupported_crop_region_size, size}}
      {:error, _reason} = error -> error
    end
  end
```

Replace `crop_coordinates/1` (lines 133-139):

```elixir
  defp crop_coordinates(coords), do: Units.coordinates(coords)
```

Update `crop_guided/2` (lines 105-111) to drop only its `pixels_only/2` call (leave `inside/2` unchanged):

```elixir
  defp crop_guided(size, acc) do
    with {:ok, {w, h}} <- Units.crop_size(size),
         {:ok, op} <- Operation.crop_guided(w, h, acc.guide) do
      push(acc, op)
    end
  end
```

Keep `pixels_only/2` and `pixel_dimension?/1` (lines 161-173) — `inside/2` still calls them. Note: `Units.size`/`crop_size` now emit `{:ratio}` for `p`/`s` via `dimension_length`; `Operation.resize`/`canvas`/`crop_region`/`crop_guided` already accept `{:ratio}` dimensions, and `Operation.crop_region` accepts `{:ratio}`/zero coordinates (`tagged_crop_coordinate`, operation.ex:752).

- [ ] **Step 4: Run the wire tests + full TwicPics suite**

Run: `mise exec -- mix test test/image_pipe/twic_pics_wire_conformance_test.exs test/parser/twic_pics/`
Expected: PASS. (Confirm `inside` with a relative unit still returns the `:unsupported_unit` rejection — its gate is intentionally retained.)

- [ ] **Step 5: Commit**

```bash
git add lib/image_pipe/parser/twic_pics/plan_builder.ex test/image_pipe/twic_pics_wire_conformance_test.exs
git commit -m "feat(twicpics): relative + zero-based crop dims/coords (closes #314, #315)"
```

---

## Task 8: TwicPics relative coordinate focus (#313 partial)

**Files:**
- Modify: `lib/image_pipe/parser/twic_pics/plan_builder.ex` (`focus/2`)
- Test: `test/image_pipe/twic_pics_wire_conformance_test.exs`

`focus=<coords>` with `p`/`s` → a focal-ratio guide via the existing `{:focal, ratio, ratio}` path. Bare-px focus, `focus=center`, and `focus=auto` stay rejected.

- [ ] **Step 1: Write the failing tests**

```elixir
test "relative coordinate focus steers the next cover" do
  # ?twic=v1/focus=25px75p/cover=100x100  (x=25%, y=75%)
  # Build, call, decode; assert the cover crop is biased toward (0.25, 0.75).
  # Compare against focus=top-left vs bottom-right baselines for direction.
end

test "bare-pixel coordinate focus is rejected" do
  # ?twic=v1/focus=20x10 -> 400 (deferred; documented rejection)
end

test "focus=auto and focus=center are rejected" do
  # ?twic=v1/focus=auto -> 400 ; ?twic=v1/focus=center -> 400
end

test "out-of-range relative focus is rejected before source fetch" do
  # ?twic=v1/focus=150px50p -> 400 at the parser (ratio > 1), NOT a late
  # execution error. Assert no source fetch occurred (use the file's
  # no-source-fetch helper, as the other request-safety tests do).
end
```

Note `25p` etc. — `focus` coordinates use `position_length`, so a relative axis yields a `{:ratio}`. A pixel axis yields `{:px, n}` (rejected here, deferred). An out-of-range relative axis (`150p` → `{:ratio, 3, 2}`) must be rejected **at the parser** for request-safety (it would otherwise pass plan construction — `tagged_ratio` has no upper bound — and fail only late in `crop.ex` after source fetch + decode).

- [ ] **Step 2: Run to verify failure**

Run: `mise exec -- mix test test/image_pipe/twic_pics_wire_conformance_test.exs`
Expected: FAIL — `focus/2` currently only maps anchors.

- [ ] **Step 3: Implement relative coordinate focus**

In `plan_builder.ex`, extend `focus/2` (lines 141-149). Keep the `auto`/`center` rejections, try an anchor, then try relative coordinates; reject any axis that is bare pixels (deferred):

```elixir
  defp focus("auto", _acc), do: {:error, {:unsupported_focus, "auto"}}
  defp focus("center", _acc), do: {:error, {:unsupported_focus, "center"}}

  defp focus(args, acc) do
    case Units.anchor(args) do
      {:ok, guide} -> {:ok, %{acc | guide: guide}}
      {:error, _} -> focus_coordinates(args, acc)
    end
  end

  # Relative (p/s) coordinate focus -> focal ratio guide. Bare-pixel coordinates
  # need running-dim-at-focus-position resolution and are deferred (see issue).
  defp focus_coordinates(args, acc) do
    with {:ok, {x, y}} <- Units.coordinates(args),
         {:ok, fx} <- focal_ratio(x),
         {:ok, fy} <- focal_ratio(y) do
      {:ok, %{acc | guide: {:focal, fx, fy}}}
    else
      _ -> {:error, {:unsupported_focus, args}}
    end
  end

  # In-range relative focus only. A ratio > 1 (e.g. 150p) is an out-of-image
  # focus point and must be rejected HERE (the plan-construction gate
  # `tagged_ratio` has no upper bound, so it would otherwise pass parse/plan and
  # fail only late in crop.ex after source fetch). Bare-px is deferred.
  defp focal_ratio({:ratio, num, den}) when num <= den, do: {:ok, {:ratio, num, den}}
  defp focal_ratio(_measure), do: {:error, :out_of_range_or_deferred_focus}
```

This keeps focus rejections at the parser boundary (before source fetch / cache access), consistent with the request-safety guideline. (`Operation.crop_guided`/`resize` validate the focal ratio's *shape* via `tagged_ratio`, operation.ex:879, but **not** its `0..1` bound — the executor `crop.ex crop_gravity` enforces `<= 1.0` only at execution time, which is too late.)

- [ ] **Step 4: Run the wire tests**

Run: `mise exec -- mix test test/image_pipe/twic_pics_wire_conformance_test.exs`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add lib/image_pipe/parser/twic_pics/plan_builder.ex test/image_pipe/twic_pics_wire_conformance_test.exs
git commit -m "feat(twicpics): relative-unit coordinate focus (#313, p/s; bare-px deferred)"
```

---

## Task 9: Conformance docs

**Files:**
- Modify: `docs/twicpics_support_matrix.md`, `docs/imgproxy_support_matrix.md`, `docs/iiif_3_support_matrix.md`

- [ ] **Step 1: TwicPics matrix**

Flip the rows: Coordinates → zero-based (`0x0` = top-left, `639x479` = bottom-right of 640×480); Crop size / Crop coordinates → relative units (`p`/`s`) supported; `focus=<coords>` → supported for `p`/`s` (✅), bare-px and `auto` remain 🚫 with a follow-up reference. Notes: a relative **focus** coordinate out of range (`> 100%`) is **rejected at the parser** (must be within the image); a crop **region origin** out of range is clamped by the executor (`max(0, …)`, existing behavior) — that clamp is the documented, upstream-unverified host choice (TwicPics docs are silent). Reference this spec.

- [ ] **Step 2: imgproxy matrix**

Add a pipeline-section note that relative-unit resolution flows through the shared `Plan.Measure` + `Geometry` resolver. No behavioral/pixel row changes (imgproxy stays pixel-neutral).

- [ ] **Step 3: IIIF matrix**

Add a stage/order note that region/size resolution flows through the shared resolver. No behavioral/pixel change (IIIF stays pixel-neutral; `pct:n` zoom normalization deferred).

- [ ] **Step 4: Commit**

```bash
git add docs/twicpics_support_matrix.md docs/imgproxy_support_matrix.md docs/iiif_3_support_matrix.md
git commit -m "docs: conformance matrices for unified coordinate/unit model"
```

---

## Task 10: Fiddle TwicPics provider — relative crop + zero origin + relative focus

**Files:**
- Modify: `fiddle/assets/TwicCropControls.svelte`, `fiddle/assets/TwicCropOriginPicker.svelte`, `fiddle/assets/TwicPicsControls.svelte`
- Modify: `fiddle/assets/twicpics-path.ts`, `fiddle/assets/twicpics-path.test.ts`

Per project memory, **do not self-preview the fiddle UI** — gate and commit; the user verifies the look.

- [ ] **Step 1: Build assets so mix test can run (fresh worktree)**

Run: `pnpm -C fiddle/assets install --frozen-lockfile && pnpm -C fiddle/assets run build`

- [ ] **Step 2: Update `twicpics-path.ts` parsing/serialization (test-first)**

In `twicpics-path.test.ts`, add cases: crop origin `0` is valid (`@0x0`), crop dims/coords accept `p`/`s` units, crop **size** stays `> 0`, focus accepts a relative coordinate mode. Run the JS tests to see them fail, then update `twicpics-path.ts`:
- origin coordinate parsing/serialization accepts `>= 0`;
- crop W/H + origin support the unit suffixes (`p`/`s`) the resize control already uses;
- focus serializes a relative coordinate (`<x>x<y>` with `p`/`s`).

Run: `pnpm -C fiddle/assets test`
Expected: PASS.

- [ ] **Step 3: Update the Svelte controls**

- `TwicCropControls.svelte` — crop W/H + origin use the unit-capable dimension control (the resize control's px/%/scale picker).
- `TwicCropOriginPicker.svelte` — origin min `0`; minimap maps clicks to the chosen unit; clamp `[0, running − size]`.
- `TwicPicsControls.svelte` (focus card) — add a **relative** coordinate mode; do not offer bare-px or `auto` (the parser rejects them).

- [ ] **Step 4: Run the fiddle JS checks**

Run: `pnpm -C fiddle/assets run check && pnpm -C fiddle/assets run lint && pnpm -C fiddle/assets test && pnpm -C fiddle/assets run build`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add fiddle/assets/TwicCropControls.svelte fiddle/assets/TwicCropOriginPicker.svelte \
        fiddle/assets/TwicPicsControls.svelte fiddle/assets/twicpics-path.ts fiddle/assets/twicpics-path.test.ts
git commit -m "feat(fiddle): TwicPics relative crop, zero origin, relative coordinate focus"
```

---

## Task 11: Full gates — precommit, differential bake, regression guards

**Files:** none (verification only)

- [ ] **Step 1: Elixir gate**

Run: `mise run precommit`
Expected: `mix format --check-formatted`, `mix compile --warnings-as-errors`, `mix credo --strict`, `mix test` all PASS.

- [ ] **Step 2: imgproxy differential bake (pixel-neutrality regression guard)**

Run the differential suite per `test/support/image_pipe/test/imgproxy_differential/README.md` (note the local Ryuk workaround from project memory: `TESTCONTAINERS_RYUK_DISABLED=true`, and `MIX_ENV=test mix deps.get` first if needed).
Expected: GREEN. The consolidation preserves imgproxy rounding/arithmetic/encoding, so no fixture should move. If a fixture diverges, STOP — diagnose per the README's bake → diagnose → tolerance → quarantine workflow before proceeding; an unexpected move means a consumer's rounding was not preserved.

- [ ] **Step 3: IIIF wire conformance (pixel-neutrality regression guard)**

Run: `mise exec -- mix test test/parser/iiif_wire_test.exs`
Expected: PASS (IIIF is pixel-neutral this PR).

- [ ] **Step 4: Fiddle verify suite**

Run: `mise run precommit:fiddle`
Expected: PASS (Elixir gate + fiddle JS test/check/lint/format/build).

- [ ] **Step 5: Final commit (if any formatting/fixups)**

```bash
git add -A
git commit -m "chore: format + gate fixups for unified coordinate/unit model"
```

---

## Follow-ups to file (not in this PR)

- **Bare-pixel coordinate focus** (#313 px) — needs a `State`-carried focal point capturing the running dimension at the focus's chain position, plus the orientation-frame interaction.
- **`focus=auto` / smart guide** — a `:smart` focal guide (also satisfies imgproxy `g:sm`).
- **crop-size half-away alignment** — `crop.ex` crop-size uses ties-to-even vs imgproxy `CalcCropSize` half-away; bake-gated fix, needs a fractional `c:0.x` fixture.
- **`zoom_x`/`zoom_y` → exact-ratio** (IIIF `pct:n`) — separate `apply_zoom` path + constructor validation; needs a tie-hitting `pct:n` fixture.
- **Relative-unit `inside`** (TwicPics) — requires resolving the resize+canvas composition without triggering aspect-ratio canvas semantics / mixed-unit errors.
- **Role-named resolver consolidation** — rewire `crop.ex`/`resize.ex` through shared `Geometry.resolve_dimension/resolve_position/resolve_focal` (behavior-preserving refactor; spec §4.3).
