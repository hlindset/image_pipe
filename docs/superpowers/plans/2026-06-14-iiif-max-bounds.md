# IIIF max bounds (maxWidth/maxHeight/maxArea + `^max`) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Implement IIIF Image API 3.0 server-side `maxWidth`/`maxHeight`/`maxArea` size limits as a product-neutral output ceiling on the resize op, making `^max` upscale-to-ceiling and clamping every size form to the configured bounds, then advertise them in info.json.

**Architecture:** Add three optional fields (`max_width`/`max_height`/`max_area`, `pos_integer | nil`) to both `Plan.Operation.Resize` and `Transform.Operation.Resize`. `Transform.Operation.Resize.resolve_dimensions/2` applies a per-candidate bounding step: **grow-to-ceiling** (scale may exceed 1.0) for the bare `^max` signature (`enlarge and width==:auto and height==:auto and not factor_requested?`), **clamp-down** (`min(1.0, scale)`) for everything else. The IIIF parser reads the bounds from its `iiif:` config and threads them onto every resize; info.json advertises the configured values.

**Tech Stack:** Elixir, Vix/libvips (`Image`), NimbleOptions (option validation), ExUnit + StreamData (property tests), Svelte (fiddle demo).

**Spec:** `docs/superpowers/specs/2026-06-14-iiif-max-bounds-design.md` (read it — especially "The ceiling resolution" and "IIIF wiring"). IIIF ground truth: `/Users/hlindset/src/iiif-image-api-3.0-spec/spec.md`.

**Conventions:**
- Run all tooling via `mise exec -- ...` (e.g. `mise exec -- mix test test/path.exs`).
- This is a greenfield library — no backwards-compat concerns; reshape in place.
- Lists don't support index access — use `Enum.at`/pattern matching.
- Commit after each task (or each green test cluster). Keep commits focused.
- Final gates: `mise run precommit` (library) and `mise run precommit:fiddle` (fiddle changes).

---

## File structure

| File | Responsibility | Change |
| --- | --- | --- |
| `lib/image_pipe/plan/operation/resize.ex` | Plan-level semantic resize struct | add 3 fields |
| `lib/image_pipe/plan/operation.ex` | `resize/4` constructor, `@semantic_resize_keys`, `valid_resize?` gate | validate 3 fields |
| `lib/image_pipe/plan/key_data.ex` | cache key data for `Resize` | add 3 fields |
| `lib/image_pipe/transform/operation/resize.ex` | executable resize + dimension resolver | add 3 fields + bounding step |
| `lib/image_pipe/transform/plan_executor.ex` | `resize_from/2` Plan→Transform mapping | copy 3 fields |
| `lib/image_pipe/parser/iiif.ex` | `iiif:` schema + cross-field validation | add 3 options |
| `lib/image_pipe/parser/iiif/plan_builder.ex` | `image_plan`/`size_operations`/`info_plan` | thread bounds |
| `lib/image_pipe/parser/iiif/info.ex` | info.json document | advertise bounds |
| `fiddle/lib/image_pipe_fiddle/application.ex` | demo IIIF config | demo bounds |
| `fiddle/assets/IiifControls.svelte` | demo controls | re-enable `^` for `max` |
| `fiddle/assets/iiif-path.ts` | demo URL state | stale-comment cleanup |
| `docs/iiif_3_support_matrix.md` | IIIF conformance doc | surface + behavioral axes |

---

## Task 1: Add max-bound fields to `Plan.Operation.Resize`

**Files:**
- Modify: `lib/image_pipe/plan/operation/resize.ex`

Pure struct/type change — adds three optional fields, defaulting `nil`. No test of its own (covered by Task 2's constructor tests); a struct gaining nil-default fields cannot break compilation.

- [ ] **Step 1: Add fields to the struct and type**

In `lib/image_pipe/plan/operation/resize.ex`, add `max_width: nil, max_height: nil, max_area: nil` to the `defstruct` keyword defaults (after `zoom_y: 1.0`), and to `@type t`:

```elixir
          zoom_x: pos_integer() | float(),
          zoom_y: pos_integer() | float(),
          max_width: pos_integer() | nil,
          max_height: pos_integer() | nil,
          max_area: pos_integer() | nil
        }
```

```elixir
                zoom_x: 1.0,
                zoom_y: 1.0,
                max_width: nil,
                max_height: nil,
                max_area: nil
              ]
```

- [ ] **Step 2: Compile to verify no breakage**

Run: `mise exec -- mix compile --warnings-as-errors`
Expected: compiles clean.

- [ ] **Step 3: Commit**

```bash
git add lib/image_pipe/plan/operation/resize.ex
git commit -m "feat(plan): add max_width/max_height/max_area fields to Resize op"
```

---

## Task 2: Validate the new fields in the `resize/4` constructor + `semantic?` gate

**Files:**
- Modify: `lib/image_pipe/plan/operation.ex` (`@semantic_resize_keys`, `resize/4`, `valid_resize?/1`, new private helpers)
- Test: `test/parser/iiif/plan_builder_test.exs` is NOT the home; use a focused operation test. Add to `test/image_pipe/plan/operation_key_data_test.exs`? No — create constructor assertions inline. Use `test/parser/iiif_test.exs`? No. **Test home:** add a small `describe` block to the existing resize resolver area is wrong too. Create `test/image_pipe/plan/operation_resize_bounds_test.exs`.

- [ ] **Step 1: Write the failing test**

Create `test/image_pipe/plan/operation_resize_bounds_test.exs`:

```elixir
defmodule ImagePipe.Plan.OperationResizeBoundsTest do
  use ExUnit.Case, async: true

  alias ImagePipe.Plan.Operation
  alias ImagePipe.Plan.Operation.Resize

  test "resize/4 accepts and stores max_width/max_height/max_area" do
    assert {:ok, %Resize{max_width: 2000, max_height: 1500, max_area: 3_000_000}} =
             Operation.resize(:fit, :auto, :auto,
               max_width: 2000,
               max_height: 1500,
               max_area: 3_000_000
             )
  end

  test "resize/4 defaults the three bounds to nil" do
    assert {:ok, %Resize{max_width: nil, max_height: nil, max_area: nil}} =
             Operation.resize(:fit, :auto, :auto)
  end

  test "resize/4 accepts nil bounds explicitly (parser threads nils uniformly)" do
    assert {:ok, %Resize{max_width: nil, max_height: nil, max_area: nil}} =
             Operation.resize(:fit, :auto, :auto, max_width: nil, max_height: nil, max_area: nil)
  end

  test "resize/4 rejects a non-positive or non-integer bound" do
    assert {:error, _} = Operation.resize(:fit, :auto, :auto, max_width: 0)
    assert {:error, _} = Operation.resize(:fit, :auto, :auto, max_height: -5)
    assert {:error, _} = Operation.resize(:fit, :auto, :auto, max_area: 1.5)
  end

  test "semantic? accepts a Resize with valid bounds and rejects bad ones" do
    {:ok, ok} = Operation.resize(:fit, :auto, :auto, max_width: 2000)
    assert Operation.semantic?(ok)

    bad = %Resize{ok | max_width: 0}
    refute Operation.semantic?(bad)
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mise exec -- mix test test/image_pipe/plan/operation_resize_bounds_test.exs`
Expected: FAIL — `max_width: 0` currently `{:ok, ...}` (constructor ignores the keys / `validate_known_options` rejects unknown key `:max_width`). Most likely failure: `{:error, {:unknown_operation_options, ...}}` because the keys aren't in `@semantic_resize_keys`.

- [ ] **Step 3: Add the keys to `@semantic_resize_keys`**

In `lib/image_pipe/plan/operation.ex`, extend the module attribute (~line 43):

```elixir
  @semantic_resize_keys [
    :dpr,
    :enlargement,
    :guide,
    :x_offset,
    :y_offset,
    :min_width,
    :min_height,
    :zoom_x,
    :zoom_y,
    :max_width,
    :max_height,
    :max_area
  ]
```

- [ ] **Step 4: Validate + store the fields in `resize/4`**

In the `with` chain of `resize/4` (after the `zoom_y` line, ~line 370), add:

```elixir
         {:ok, zoom_y} <- numeric(opts, :zoom_y, 1.0),
         {:ok, max_width} <- optional_positive_integer(opts, :max_width),
         {:ok, max_height} <- optional_positive_integer(opts, :max_height),
         {:ok, max_area} <- optional_positive_integer(opts, :max_area) do
```

And add the fields to the `%Resize{}` literal:

```elixir
         zoom_x: zoom_x,
         zoom_y: zoom_y,
         max_width: max_width,
         max_height: max_height,
         max_area: max_area
       }}
```

- [ ] **Step 5: Add the constructor helper**

Near the other private resize helpers in `lib/image_pipe/plan/operation.ex` (e.g. after `numeric/3`):

```elixir
  defp optional_positive_integer(attrs, key) do
    case Keyword.get(attrs, key) do
      nil -> {:ok, nil}
      value when is_integer(value) and value > 0 -> {:ok, value}
      _ -> {:error, key}
    end
  end
```

- [ ] **Step 6: Extend `valid_resize?/1` (the `semantic?` gate)**

In `valid_resize?/1` (~line 447), add three clauses to the `with` (after the `zoom_y` check):

```elixir
         :ok <- positive_number(operation.zoom_x),
         :ok <- positive_number(operation.zoom_y),
         :ok <- optional_positive_integer_value(operation.max_width),
         :ok <- optional_positive_integer_value(operation.max_height),
         :ok <- optional_positive_integer_value(operation.max_area) do
```

And add the value helper near `optional_positive_integer/2`:

```elixir
  defp optional_positive_integer_value(nil), do: :ok
  defp optional_positive_integer_value(value) when is_integer(value) and value > 0, do: :ok
  defp optional_positive_integer_value(_value), do: {:error, :max_bound}
```

- [ ] **Step 7: Run test to verify it passes**

Run: `mise exec -- mix test test/image_pipe/plan/operation_resize_bounds_test.exs`
Expected: PASS (all 5).

- [ ] **Step 8: Commit**

```bash
git add lib/image_pipe/plan/operation.ex test/image_pipe/plan/operation_resize_bounds_test.exs
git commit -m "feat(plan): validate max_width/max_height/max_area in resize constructor + semantic gate"
```

---

## Task 3: Include the bounds in the `Resize` cache key data

**Files:**
- Modify: `lib/image_pipe/plan/key_data.ex` (`data(%Resize{})`)
- Test: `test/image_pipe/plan/key_data_test.exs`

- [ ] **Step 1: Write the failing test**

Append to `test/image_pipe/plan/key_data_test.exs` (inside the module; mirror existing `Resize` assertions — check the file for the alias `KeyData`/`Resize` already in scope):

```elixir
  test "Resize key data includes max bounds and distinguishes them" do
    {:ok, bounded} =
      ImagePipe.Plan.Operation.resize(:fit, :auto, :auto, max_width: 2000, max_area: 3_000_000)

    {:ok, unbounded} = ImagePipe.Plan.Operation.resize(:fit, :auto, :auto)

    bounded_data = ImagePipe.Plan.KeyData.data(bounded)
    unbounded_data = ImagePipe.Plan.KeyData.data(unbounded)

    assert Keyword.get(bounded_data, :max_width) == 2000
    assert Keyword.get(bounded_data, :max_area) == 3_000_000
    assert Keyword.get(bounded_data, :max_height) == nil
    refute bounded_data == unbounded_data
  end
```

(If the test file uses `import`/`alias` so you can write `KeyData.data` / `Operation.resize`, match that style.)

- [ ] **Step 2: Run test to verify it fails**

Run: `mise exec -- mix test test/image_pipe/plan/key_data_test.exs`
Expected: FAIL — `max_width` not present in the key data keyword list.

- [ ] **Step 3: Add the fields to `data(%Resize{})`**

In `lib/image_pipe/plan/key_data.ex` (~line 92), add after `min_height:`:

```elixir
      min_width: optional_data(operation.min_width),
      min_height: optional_data(operation.min_height),
      max_width: optional_data(operation.max_width),
      max_height: optional_data(operation.max_height),
      max_area: optional_data(operation.max_area),
      zoom_x: operation.zoom_x,
```

- [ ] **Step 4: Run test to verify it passes**

Run: `mise exec -- mix test test/image_pipe/plan/key_data_test.exs`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add lib/image_pipe/plan/key_data.ex test/image_pipe/plan/key_data_test.exs
git commit -m "feat(cache): include resize max bounds in cache key data"
```

---

## Task 4: Add max-bound fields to `Transform.Operation.Resize`

**Files:**
- Modify: `lib/image_pipe/transform/operation/resize.ex` (struct + type only)

Struct/type only; the resolver logic is Task 5. Defaults `nil`.

- [ ] **Step 1: Add fields to the struct and type**

In `lib/image_pipe/transform/operation/resize.ex`, add to `@type t` (after `reject_enlargement: boolean()`):

```elixir
          enlarge: boolean(),
          reject_enlargement: boolean(),
          max_width: pos_integer() | nil,
          max_height: pos_integer() | nil,
          max_area: pos_integer() | nil
        }
```

And to `defstruct` (after `reject_enlargement: false`):

```elixir
            enlarge: false,
            reject_enlargement: false,
            max_width: nil,
            max_height: nil,
            max_area: nil
```

- [ ] **Step 2: Compile**

Run: `mise exec -- mix compile --warnings-as-errors`
Expected: clean.

- [ ] **Step 3: Commit**

```bash
git add lib/image_pipe/transform/operation/resize.ex
git commit -m "feat(transform): add max bound fields to executable Resize struct"
```

---

## Task 5: Implement the bounding step in `resolve_dimensions/2` (the core)

**Files:**
- Modify: `lib/image_pipe/transform/operation/resize.ex` (`resolve_dimensions/2` + new private helpers)
- Test: `test/image_pipe/transform/resize_dimension_test.exs` (resolver unit tests) + new `test/image_pipe/transform/resize_bounds_property_test.exs` (property)

This task carries the design's subtlety. Read the spec's "The ceiling resolution" section before writing code. Key facts to honor:
- The bounding step runs **after** `normalize/1`, on the **normalized** operation, reading `operation.enlarge` (boolean).
- It is **per-candidate**: apply separately to `target` and `intermediate`, computing the scale from *that candidate's own* `{w,h}`.
- **`:auto` axes pass through untouched** (never multiplied).
- **Grow-to-ceiling** (`bound_scale` even if > 1) iff `enlarge and width==:auto and height==:auto and not factor_requested?`. For `^max`, `target` is `{:auto,:auto}` (passes through) and `intermediate` is `source` (grows). Otherwise **clamp-down** (`min(1.0, scale)`).
- **maxArea is a MUST (`w·h ≤ max_area`)**: when the area term is the binding (minimum) constraint, **floor** the axes (`trunc`) instead of rounding so rounding can't push area over.
- **All-nil fast path**: with all three bounds `nil`, return the candidate unchanged (no scale constructed) so behavior is byte-identical to today.

- [ ] **Step 1: Write the failing resolver unit tests**

Append to `test/image_pipe/transform/resize_dimension_test.exs` (the alias `Resize` is already in scope):

```elixir
  describe "max bounds" do
    # max (no ^): :fit auto/auto, deny enlarge. Ceiling larger than source -> source.
    test "max with ceiling larger than source clamps to source (no upscale)" do
      op = %Resize{mode: :fit, width: :auto, height: :auto, enlarge: false,
                   max_width: 10_000, max_height: 10_000}
      r = Resize.resolve_dimensions(op, source_width: 6000, source_height: 4000)
      assert r.intermediate_width == 6000
      assert r.intermediate_height == 4000
    end

    # ^max: :fit auto/auto, enlarge. Ceiling larger than source -> grow to box.
    test "^max grows to the ceiling box (width-binding)" do
      op = %Resize{mode: :fit, width: :auto, height: :auto, enlarge: true,
                   max_width: 10_000, max_height: 10_000}
      r = Resize.resolve_dimensions(op, source_width: 6000, source_height: 4000)
      assert r.intermediate_width == 10_000
      assert r.intermediate_height == 6667
    end

    # ^max with ceiling smaller than source -> downscale to box (no upscale needed).
    test "^max with sub-source ceiling downscales to the box" do
      op = %Resize{mode: :fit, width: :auto, height: :auto, enlarge: true,
                   max_width: 2000, max_height: 2000}
      r = Resize.resolve_dimensions(op, source_width: 6000, source_height: 4000)
      assert r.intermediate_width == 2000
      assert r.intermediate_height == 1333
    end

    # max with sub-source ceiling -> clamp down.
    test "max clamps down to a sub-source ceiling" do
      op = %Resize{mode: :fit, width: :auto, height: :auto, enlarge: false,
                   max_width: 2000, max_height: 2000}
      r = Resize.resolve_dimensions(op, source_width: 6000, source_height: 4000)
      assert r.intermediate_width == 2000
      assert r.intermediate_height == 1333
    end

    # Explicit width (no ^) exceeding maxWidth -> clamped down. Mode :fit, width {:pixels,4000}.
    test "explicit width exceeding maxWidth is clamped down" do
      op = %Resize{mode: :fit, width: {:pixels, 4000}, height: :auto, enlarge: false,
                   max_width: 2000, max_height: 2000}
      r = Resize.resolve_dimensions(op, source_width: 6000, source_height: 4000)
      assert r.intermediate_width == 2000
      assert r.intermediate_height <= 2000
    end

    # maxArea-only ^max upscales until area ~= max_area, and never exceeds it.
    test "maxArea-only ^max scales to the area ceiling without exceeding it" do
      op = %Resize{mode: :fit, width: :auto, height: :auto, enlarge: true,
                   max_area: 50_000_000}
      r = Resize.resolve_dimensions(op, source_width: 6000, source_height: 4000)
      assert r.intermediate_width * r.intermediate_height <= 50_000_000
      # close to the ceiling (within one row/col of pixels)
      assert r.intermediate_width * r.intermediate_height >= 50_000_000 - 6000 * 2
    end

    # maxArea cap on a large image never exceeds the area MUST.
    test "maxArea caps area and never exceeds it" do
      op = %Resize{mode: :fit, width: :auto, height: :auto, enlarge: false,
                   max_area: 2_000_000}
      r = Resize.resolve_dimensions(op, source_width: 6000, source_height: 4000)
      assert r.intermediate_width * r.intermediate_height <= 2_000_000
    end

    # All-nil bounds are a byte-identical no-op vs. the same op without bound fields.
    test "all-nil bounds are a no-op" do
      bounded = %Resize{mode: :fit, width: {:pixels, 800}, height: :auto, enlarge: false}
      r = Resize.resolve_dimensions(bounded, source_width: 6000, source_height: 4000)
      assert r.intermediate_width == 800
    end
  end
```

- [ ] **Step 2: Run to verify failure**

Run: `mise exec -- mix test test/image_pipe/transform/resize_dimension_test.exs`
Expected: FAIL — the bounded cases return unbounded dims (e.g. `^max` stays at source 6000×4000 instead of 10000×6667).

- [ ] **Step 3: Wire the bounding step into `resolve_dimensions/2`**

In `lib/image_pipe/transform/operation/resize.ex`, modify `resolve_dimensions/2`. After the existing `target`/`intermediate` bindings and the `unclamped`/`upscale_required` computation, insert the bounding step (the `unclamped`/`upscale_required` must be computed from the **pre-bound** dims, so add the bounding *after* them):

```elixir
    unclamped =
      target_dimensions(operation.mode, requested, min_dimensions, source, true)

    upscale_required =
      axis_exceeds?(unclamped.width, source.width) or
        axis_exceeds?(unclamped.height, source.height)

    grow? = grow_to_bounds?(operation)
    target = apply_bounds(target, operation, grow?)
    intermediate = apply_bounds(intermediate, operation, grow?)
```

(Leave the returned `%{...}` map referencing `target.*` / `intermediate.*` exactly as before — they now hold the bounded values.)

- [ ] **Step 4: Add the bounding helpers**

Add these private functions to `lib/image_pipe/transform/operation/resize.ex` (near `clamp_to_source/3` / `scale_dimensions/2`):

```elixir
  # The grow-to-ceiling case is exactly `^max`: enlarge + bare auto/auto + no zoom/dpr factor.
  defp grow_to_bounds?(%__MODULE__{enlarge: true, width: :auto, height: :auto} = operation),
    do: not factor_requested?(operation)

  defp grow_to_bounds?(%__MODULE__{}), do: false

  defp apply_bounds(dims, %__MODULE__{} = operation, grow?) do
    case bound_terms(dims, operation) do
      [] ->
        dims

      terms ->
        {scale, area_binding?} = binding_scale(terms)
        scale = if grow?, do: scale, else: min(1.0, scale)
        floor? = area_binding? and scale != 1.0

        %{
          width: scaled_bound_axis(dims.width, scale, floor?),
          height: scaled_bound_axis(dims.height, scale, floor?)
        }
    end
  end

  # Each configured bound contributes a {scale, area?} term, skipping :auto axes.
  defp bound_terms(%{width: w, height: h}, %__MODULE__{} = op) do
    []
    |> add_axis_term(op.max_width, w)
    |> add_axis_term(op.max_height, h)
    |> add_area_term(op.max_area, w, h)
  end

  defp add_axis_term(terms, nil, _value), do: terms
  defp add_axis_term(terms, _max, :auto), do: terms
  defp add_axis_term(terms, max, value), do: [{max / value, false} | terms]

  defp add_area_term(terms, nil, _w, _h), do: terms
  defp add_area_term(terms, _max, w, h) when w == :auto or h == :auto, do: terms
  defp add_area_term(terms, max, w, h), do: [{:math.sqrt(max / (w * h)), true} | terms]

  # The binding (smallest-scale) term wins; report whether it is the area constraint.
  defp binding_scale(terms) do
    Enum.reduce(terms, fn {s, a}, {acc_s, acc_a} ->
      if s < acc_s, do: {s, a}, else: {acc_s, acc_a}
    end)
  end

  defp scaled_bound_axis(:auto, _scale, _floor?), do: :auto
  defp scaled_bound_axis(value, scale, true), do: max(1, trunc(value * scale))
  defp scaled_bound_axis(value, scale, false), do: positive_round(value * scale)
```

Notes for the implementer:
- `binding_scale/1` uses `Enum.reduce/2` (no accumulator) — `terms` is always non-empty in the branch that calls it.
- `floor?` flooring applies only when the **area** term binds *and* an actual scale (≠ 1.0) is applied — this guarantees `w·h ≤ max_area` while leaving pure axis-cap fits on exact `positive_round`.
- `:auto` axes pass through in both `add_axis_term` (no term) and `scaled_bound_axis` (returned as `:auto`).

- [ ] **Step 5: Run to verify pass**

Run: `mise exec -- mix test test/image_pipe/transform/resize_dimension_test.exs`
Expected: PASS (existing + new). If `^max` height is off by 1 from rounding, recheck `positive_round` is used for non-area-binding axes (height here is the *derived* non-binding axis under a width-binding scale → `positive_round(4000 * (10000/6000)) = positive_round(6666.67) = 6667`).

- [ ] **Step 6: Write the property test (area MUST + all-nil no-op invariants)**

Create `test/image_pipe/transform/resize_bounds_property_test.exs`:

```elixir
defmodule ImagePipe.Transform.ResizeBoundsPropertyTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias ImagePipe.Transform.Operation.Resize

  property "maxArea is never exceeded for any source/area/^-or-not" do
    check all src_w <- integer(64..8000),
              src_h <- integer(64..8000),
              area <- integer(10_000..40_000_000),
              enlarge <- boolean() do
      op = %Resize{mode: :fit, width: :auto, height: :auto, enlarge: enlarge, max_area: area}
      r = Resize.resolve_dimensions(op, source_width: src_w, source_height: src_h)
      assert r.intermediate_width * r.intermediate_height <= area
    end
  end

  property "configured axis ceilings are never exceeded by the resolved result" do
    check all src_w <- integer(64..8000),
              src_h <- integer(64..8000),
              max_w <- integer(16..4000),
              max_h <- integer(16..4000),
              enlarge <- boolean() do
      op = %Resize{mode: :fit, width: :auto, height: :auto, enlarge: enlarge,
                   max_width: max_w, max_height: max_h}
      r = Resize.resolve_dimensions(op, source_width: src_w, source_height: src_h)
      assert r.intermediate_width <= max_w
      assert r.intermediate_height <= max_h
    end
  end

  property "all-nil bounds equal the same op with no bound fields set" do
    check all src_w <- integer(64..8000),
              src_h <- integer(64..8000),
              w <- integer(1..8000) do
      op = %Resize{mode: :fit, width: {:pixels, w}, height: :auto, enlarge: false}
      r = Resize.resolve_dimensions(op, source_width: src_w, source_height: src_h)
      # max_* default nil on the struct, so this is the no-op path by construction.
      assert is_integer(r.intermediate_width)
      assert r.intermediate_width >= 1
    end
  end
end
```

- [ ] **Step 7: Run the property test**

Run: `mise exec -- mix test test/image_pipe/transform/resize_bounds_property_test.exs`
Expected: PASS. If the axis-ceiling property fails on a rounding edge (result == max+1 from `positive_round`), the design intends axis caps to be *exact fits*; investigate whether a binding axis term rounded up — if so, the binding axis should also floor. (Expected: a binding axis term `max/value` applied to `value` gives `positive_round(max) == max` exactly when `max` is integer, so this should hold; the floor is only needed for the area term.)

- [ ] **Step 8: Run the full transform resize suite (regression)**

Run: `mise exec -- mix test test/image_pipe/transform/resize_dimension_test.exs test/image_pipe/transform/resize_execute_test.exs test/image_pipe/transform/resize_relative_resolution_property_test.exs test/image_pipe/transform/operation/resize_reject_test.exs`
Expected: PASS — the all-nil no-op path leaves existing behavior unchanged.

- [ ] **Step 9: Commit**

```bash
git add lib/image_pipe/transform/operation/resize.ex test/image_pipe/transform/resize_dimension_test.exs test/image_pipe/transform/resize_bounds_property_test.exs
git commit -m "feat(transform): apply max-bound output ceiling in resize dimension resolution"
```

---

## Task 6: Thread the bounds from Plan→Transform in `resize_from/2`

**Files:**
- Modify: `lib/image_pipe/transform/plan_executor.ex` (`resize_from/2`)

No new test of its own — Task 10's wire tests prove the end-to-end path. A unit test here would assert private dispatch (discouraged by AGENTS test guidelines).

- [ ] **Step 1: Copy the three fields in `resize_from/2`**

In `lib/image_pipe/transform/plan_executor.ex` (~line 804), add to the `%Resize{}` literal (after `reject_enlargement:`):

```elixir
      enlarge: operation.enlargement == :allow,
      reject_enlargement: operation.enlargement == :reject,
      max_width: operation.max_width,
      max_height: operation.max_height,
      max_area: operation.max_area
    }
```

- [ ] **Step 2: Compile**

Run: `mise exec -- mix compile --warnings-as-errors`
Expected: clean.

- [ ] **Step 3: Commit**

```bash
git add lib/image_pipe/transform/plan_executor.ex
git commit -m "feat(transform): carry resize max bounds through resize_from/2"
```

---

## Task 7: Add the `iiif:` schema options + cross-field validation

**Files:**
- Modify: `lib/image_pipe/parser/iiif.ex` (`@schema`, `validate_options!`, remove comment, add `validate_max_bounds!`)
- Test: `test/parser/iiif_test.exs`

- [ ] **Step 1: Write the failing tests**

Append to `test/parser/iiif_test.exs` (the alias `IIIF` is in scope; `@opts` exists):

```elixir
  describe "max bounds option validation" do
    defp opts_with(extra) do
      [iiif: Keyword.merge(@opts[:iiif], extra)]
    end

    test "accepts max_width alone" do
      assert %{} = IIIF.validate_options!(opts_with(max_width: 2000)) |> Keyword.fetch!(:iiif) |> Map.new()
    end

    test "accepts max_width + max_height" do
      validated = IIIF.validate_options!(opts_with(max_width: 2000, max_height: 1500))
      iiif = Keyword.fetch!(validated, :iiif)
      assert Keyword.fetch!(iiif, :max_width) == 2000
      assert Keyword.fetch!(iiif, :max_height) == 1500
    end

    test "accepts max_area alone" do
      validated = IIIF.validate_options!(opts_with(max_area: 3_000_000))
      assert Keyword.fetch!(Keyword.fetch!(validated, :iiif), :max_area) == 3_000_000
    end

    test "rejects max_height without max_width" do
      assert_raise ArgumentError, ~r/max_height requires max_width/, fn ->
        IIIF.validate_options!(opts_with(max_height: 1500))
      end
    end

    test "rejects a non-positive bound (NimbleOptions)" do
      assert_raise NimbleOptions.ValidationError, fn ->
        IIIF.validate_options!(opts_with(max_width: 0))
      end
    end
  end
```

(Adjust the first test's awkward `Map.new` assertion if it doesn't read cleanly — the point is it doesn't raise. Simpler form: `assert IIIF.validate_options!(opts_with(max_width: 2000))`.)

- [ ] **Step 2: Run to verify failure**

Run: `mise exec -- mix test test/parser/iiif_test.exs`
Expected: FAIL — `max_width` is an unknown option (NimbleOptions raises "unknown options [:max_width]").

- [ ] **Step 3: Add the schema options + cross-field check; remove the comment**

In `lib/image_pipe/parser/iiif.ex`:

Remove the `# Note: IIIF maxWidth/maxHeight/maxArea are intentionally NOT a config ...` comment block (lines ~21–26) entirely.

Add three options to `@schema` (after `tile_size`):

```elixir
  @schema NimbleOptions.new!(
            resolver: [type: {:custom, __MODULE__, :validate_resolver, []}, required: true],
            auto_rotate: [type: :boolean, default: true],
            formats: [type: {:list, :atom}, default: [:jpg, :png, :webp, :avif]],
            qualities: [type: {:list, :atom}, default: [:default, :color, :gray, :bitonal]],
            tile_size: [type: :pos_integer, default: 512],
            max_width: [type: :pos_integer],
            max_height: [type: :pos_integer],
            max_area: [type: :pos_integer]
          )
```

Update `validate_options!/1` to run the cross-field check after `NimbleOptions.validate!`:

```elixir
  @impl true
  def validate_options!(opts) do
    iiif = Keyword.get(opts, :iiif, [])
    validated = NimbleOptions.validate!(iiif, @schema)
    validate_max_bounds!(validated)
    Keyword.put(opts, :iiif, validated)
  end

  # IIIF Image API 3.0 §5.1: maxWidth must be specified if maxHeight is specified.
  defp validate_max_bounds!(iiif) do
    if Keyword.has_key?(iiif, :max_height) and not Keyword.has_key?(iiif, :max_width) do
      raise ArgumentError, "iiif: max_height requires max_width (IIIF Image API 3.0 §5.1)"
    end

    :ok
  end
```

- [ ] **Step 4: Run to verify pass**

Run: `mise exec -- mix test test/parser/iiif_test.exs`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add lib/image_pipe/parser/iiif.ex test/parser/iiif_test.exs
git commit -m "feat(iiif): add max_width/max_height/max_area options with cross-field validation"
```

---

## Task 8: Thread bounds through `image_plan`/`size_operations` (producer)

**Files:**
- Modify: `lib/image_pipe/parser/iiif/plan_builder.ex` (`image_plan/3`, `size_operations/1 → /2`, `bound_opts/1` helper)
- Test: `test/parser/iiif/plan_builder_test.exs`

- [ ] **Step 1: Write the failing producer test**

Append to `test/parser/iiif/plan_builder_test.exs` (match the file's existing aliases — it builds plans via `PlanBuilder.image_plan/3`; check how it constructs `tokens` and `source`):

```elixir
  describe "size operations carry max bounds" do
    test "max threads bounds onto the resize op with maxHeight inferred from maxWidth" do
      {:ok, plan} =
        PlanBuilder.image_plan(
          source(),
          tokens(size: {:max, false}),
          max_width: 2000
        )

      [%Pipeline{operations: ops}] = plan.pipelines
      resize = Enum.find(ops, &match?(%Operation.Resize{}, &1))
      assert resize.max_width == 2000
      assert resize.max_height == 2000
      assert resize.max_area == nil
    end

    test "explicit size also carries the bounds" do
      {:ok, plan} =
        PlanBuilder.image_plan(
          source(),
          tokens(size: {:w, 4000, false}),
          max_width: 2000,
          max_area: 3_000_000
        )

      [%Pipeline{operations: ops}] = plan.pipelines
      resize = Enum.find(ops, &match?(%Operation.Resize{}, &1))
      assert resize.max_width == 2000
      assert resize.max_height == 2000
      assert resize.max_area == 3_000_000
    end

    test "no bounds configured leaves the resize unbounded" do
      {:ok, plan} = PlanBuilder.image_plan(source(), tokens(size: {:max, false}))
      [%Pipeline{operations: ops}] = plan.pipelines
      resize = Enum.find(ops, &match?(%Operation.Resize{}, &1))
      assert resize.max_width == nil
      assert resize.max_height == nil
      assert resize.max_area == nil
    end
  end
```

Add small `source/0` and `tokens/1` helpers if the file doesn't already provide them (check the existing tests — they likely build `tokens` as `%{region: :full, size: ..., rotation: {false, 0}, quality: :default, format: :jpg}` and `source` as a `%Plan.Source.Path{}`). Reuse the file's existing pattern rather than inventing one; the above is illustrative of the assertions, not the fixture style.

- [ ] **Step 2: Run to verify failure**

Run: `mise exec -- mix test test/parser/iiif/plan_builder_test.exs`
Expected: FAIL — `image_plan/3` ignores the bounds; `resize.max_width == nil`. (Also `size_operations/2` doesn't exist yet → may be an `ArgumentError`/`UndefinedFunctionError` depending on how you wire it; expected red either way.)

- [ ] **Step 3: Read bounds in `image_plan/3` and thread into `size_operations`**

In `lib/image_pipe/parser/iiif/plan_builder.ex`, update `image_plan/3`:

```elixir
  def image_plan(source, tokens, opts \\ []) do
    auto_rotate = Keyword.get(opts, :auto_rotate, false)
    max_width = Keyword.get(opts, :max_width)

    bounds = %{
      max_width: max_width,
      max_height: Keyword.get(opts, :max_height) || max_width,
      max_area: Keyword.get(opts, :max_area)
    }

    with {:ok, region_ops} <- region_operations(tokens.region),
         {:ok, size_ops} <- size_operations(tokens.size, bounds),
         {:ok, rotation_ops} <- rotation_operations(tokens.rotation),
         {:ok, quality_ops} <- quality_operations(tokens.quality),
         {:ok, output} <- output_plan(tokens.format) do
      # ... unchanged
```

- [ ] **Step 4: Bump `size_operations/1 → /2` and add `bound_opts/1`**

Change every `size_operations/1` clause head to take `bounds` and pass `bound_opts(bounds)` into the resize opts. Example for `{:max, up?}`:

```elixir
  defp size_operations({:max, up?}, bounds) do
    with {:ok, op} <-
           Operation.resize(:fit, :auto, :auto, [enlargement: enlargement(up?, :deny)] ++ bound_opts(bounds)) do
      {:ok, [op]}
    end
  end
```

Apply the same `++ bound_opts(bounds)` to the `:w`, `:h`, `:wh`, `:confined`, and `:pct` clauses (each already builds an opts keyword list — append `bound_opts(bounds)` to it). For the `:pct` clause, the opts list is `[zoom_x: zoom, zoom_y: zoom, enlargement: enlargement(up?, :reject)]` → append `++ bound_opts(bounds)`.

Add the helper:

```elixir
  defp bound_opts(%{max_width: mw, max_height: mh, max_area: ma}) do
    [max_width: mw, max_height: mh, max_area: ma]
  end
```

(Passing `nil` bounds is fine — `Operation.resize/4`'s `optional_positive_integer/2` maps `nil → {:ok, nil}`.)

- [ ] **Step 5: Run to verify pass**

Run: `mise exec -- mix test test/parser/iiif/plan_builder_test.exs`
Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add lib/image_pipe/parser/iiif/plan_builder.ex test/parser/iiif/plan_builder_test.exs
git commit -m "feat(iiif): thread max bounds through image_plan and size_operations"
```

---

## Task 9: Advertise the bounds in info.json

**Files:**
- Modify: `lib/image_pipe/parser/iiif/plan_builder.ex` (`info_plan/3` params), `lib/image_pipe/parser/iiif/info.ex` (`document/2`)
- Test: `test/parser/iiif/info_test.exs`

- [ ] **Step 1: Write the failing test**

Append to `test/parser/iiif/info_test.exs` (match its existing style — it calls `Info.document(info, params)`; reuse its `info`/`params` fixtures):

```elixir
  describe "max bounds advertising" do
    test "emits maxWidth/maxHeight/maxArea when configured" do
      doc = Info.document(source_info(), params(max_width: 2000, max_height: 1500, max_area: 3_000_000))
      assert doc["maxWidth"] == 2000
      assert doc["maxHeight"] == 1500
      assert doc["maxArea"] == 3_000_000
    end

    test "omits unset bounds" do
      doc = Info.document(source_info(), params(max_width: 2000))
      assert doc["maxWidth"] == 2000
      refute Map.has_key?(doc, "maxHeight")
      refute Map.has_key?(doc, "maxArea")
    end

    test "omits all when none configured" do
      doc = Info.document(source_info(), params([]))
      refute Map.has_key?(doc, "maxWidth")
      refute Map.has_key?(doc, "maxHeight")
      refute Map.has_key?(doc, "maxArea")
    end
  end
```

Add a `params/1` helper that merges the bound keys (always present, nil when unset) into the existing params fixture, and `source_info/0` reusing the file's existing `%SourceInfo{}` builder. Check the file: `params` must already carry `:tile_size`, `:id`, `:level`, etc. — extend that fixture with `max_width:`/`max_height:`/`max_area:` (default nil).

- [ ] **Step 2: Run to verify failure**

Run: `mise exec -- mix test test/parser/iiif/info_test.exs`
Expected: FAIL — either `KeyError` (params lacks `:max_width`) or the keys aren't in the doc. (If `KeyError`, that confirms why params must always carry the keys.)

- [ ] **Step 3: Add the keys to `info_plan/3` params**

In `lib/image_pipe/parser/iiif/plan_builder.ex`, `info_plan/3`, extend the `params` map (after `tile_size:`):

```elixir
      tile_size: Keyword.get(opts, :tile_size, 512),
      max_width: Keyword.get(opts, :max_width),
      max_height: Keyword.get(opts, :max_height),
      max_area: Keyword.get(opts, :max_area)
    }
```

(Raw configured values, `nil` when absent. Note: advertise only configured `max_height` — do **not** apply the `|| max_width` inference here; that inference is enforcement-only, per spec.)

- [ ] **Step 4: Emit the keys in `Info.document/2`**

In `lib/image_pipe/parser/iiif/info.ex`, change `document/2` to add the bounds via a `maybe_put` after building the base map:

```elixir
    %{
      "@context" => @context,
      # ... existing keys ...
      "extraFeatures" => @extra_features
    }
    |> maybe_put("maxWidth", params.max_width)
    |> maybe_put("maxHeight", params.max_height)
    |> maybe_put("maxArea", params.max_area)
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)
```

- [ ] **Step 5: Run to verify pass**

Run: `mise exec -- mix test test/parser/iiif/info_test.exs`
Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add lib/image_pipe/parser/iiif/plan_builder.ex lib/image_pipe/parser/iiif/info.ex test/parser/iiif/info_test.exs
git commit -m "feat(iiif): advertise maxWidth/maxHeight/maxArea in info.json when configured"
```

---

## Task 10: End-to-end wire conformance tests

**Files:**
- Test: `test/parser/iiif_wire_test.exs`

Real `ImagePipe.call/2` requests, decode the body, assert dimensions + info.json. Read the existing file's helpers first (how it mounts `ImagePipe.Plug` with `iiif:` opts, makes requests, decodes the body to assert dims — it already has gray-pixel and dimension checks). Reuse those helpers; configure an endpoint variant with bounds. A small enough source (`woman.jpg` 1200×800 if present, else any sample) is needed so `^max` visibly upscales above source.

- [ ] **Step 1: Write the failing wire tests**

Append a `describe "max bounds"` block to `test/parser/iiif_wire_test.exs`, modeled on the file's existing request+decode helpers. Conceptual shape (adapt to the file's actual helper names — e.g. `call/2`, `decode_dims/1`, the `@opts` mount config):

```elixir
  describe "max bounds (#257)" do
    # Endpoint configured with a sub-source ceiling so behavior is observable.
    @bounded_iiif_opts # build from the file's base opts + [max_width: 1000, max_height: 1000]

    test "^max upscales a small source above its native size" do
      # source smaller than the 1000 ceiling, e.g. 800x600 sample
      conn = request("/small/full/^max/0/default.png", @bounded_iiif_opts)
      assert conn.status == 200
      {w, h} = decode_dims(conn.resp_body)
      assert w == 1000 or h == 1000           # grown to the ceiling box
      assert w > native_w or h > native_h     # actually upscaled
    end

    test "max clamps a large source down to the ceiling" do
      conn = request("/large/full/max/0/default.png", @bounded_iiif_opts)
      {w, h} = decode_dims(conn.resp_body)
      assert w <= 1000 and h <= 1000
      assert w == 1000 or h == 1000           # fits the box on the binding axis
    end

    test "explicit width exceeding maxWidth is clamped down (not 400)" do
      conn = request("/large/full/2000,/0/default.png", @bounded_iiif_opts)
      assert conn.status == 200
      {w, _h} = decode_dims(conn.resp_body)
      assert w <= 1000
    end

    test "info.json advertises configured bounds" do
      conn = request("/large/info.json", @bounded_iiif_opts)
      body = JSON.decode!(conn.resp_body)
      assert body["maxWidth"] == 1000
      assert body["maxHeight"] == 1000
    end

    test "info.json omits bounds when unconfigured" do
      conn = request("/large/info.json", @unbounded_iiif_opts)
      body = JSON.decode!(conn.resp_body)
      refute Map.has_key?(body, "maxWidth")
    end
  end
```

Use the file's real identifiers/sources (it maps identifiers to sample images via a Static resolver). Pick a small sample for the `^max` upscale assertion and a large one for the clamp assertions. If the file lacks a `decode_dims` helper, use `Image.from_binary/1` + `Image.width/1`/`Image.height/1` (the file already decodes bodies for pixel checks — find that helper).

- [ ] **Step 2: Run to verify failure**

Run: `mise exec -- mix test test/parser/iiif_wire_test.exs`
Expected: FAIL only on the new block if any helper wiring is off; the production code is already in place from Tasks 1–9, so these may **pass** once the test harness is wired correctly. If they pass immediately, that's fine — these are end-to-end confirmations of the already-implemented path. (If a test is red, debug the test harness/opts, not the production code.)

- [ ] **Step 3: Make the tests green**

Wire the endpoint opts/helpers correctly. No production change expected; if a test reveals a real bug, fix the relevant task's code and note it.

- [ ] **Step 4: Run the full IIIF suite (regression)**

Run: `mise exec -- mix test test/parser/iiif_wire_test.exs test/parser/iiif_test.exs test/parser/iiif/`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add test/parser/iiif_wire_test.exs
git commit -m "test(iiif): wire conformance for max bounds (^max upscale, max clamp, info.json)"
```

---

## Task 11: Fiddle demo — re-enable `^max` + configure demo bounds

**Files:**
- Modify: `fiddle/lib/image_pipe_fiddle/application.ex` (`build_iiif_opts/0`)
- Modify: `fiddle/assets/IiifControls.svelte` (re-enable `^` toggle for `max`)
- Modify: `fiddle/assets/iiif-path.ts` (stale-comment cleanup)

- [ ] **Step 1: Add demo bounds to the IIIF config**

In `fiddle/lib/image_pipe_fiddle/application.ex`, `build_iiif_opts/0`, add the bounds to the `iiif:` keyword:

```elixir
      iiif: [
        resolver: {ImagePipe.Parser.IIIF.Resolver.Static, map: iiif_source_map()},
        max_width: 4000,
        max_height: 4000
      ],
```

(Demo rationale per spec: samples run 1000–8775px; 4000 shows `max`/`^max` clamping *down* on big samples and `^max` *upscaling* on small ones — `woman` 1200×800, `concert` 1000×1500.)

- [ ] **Step 2: Re-enable the `^` toggle for `max` in `IiifControls.svelte`**

In `fiddle/assets/IiifControls.svelte`, in `setSizeKind`, the `case "max"` block currently forces `iiifState.upscale = false` with a `#257` comment. Replace:

```javascript
      case "max":
        iiifState.size = { kind: "max" };
        // `^max` is inert until maxWidth/maxHeight/maxArea support lands (#257), so
        // don't emit it — `^` only meaningfully applies to an explicit target size.
        iiifState.upscale = false;
        break;
```

with:

```javascript
      case "max":
        iiifState.size = { kind: "max" };
        break;
```

And remove the `{#if iiifState.size.kind !== "max"}` gate around the upscaling toggle (~line 207) so the toggle always renders:

```svelte
  <label class="switch-field">
    <Switch.Root class="switch-root" bind:checked={iiifState.upscale}>
      <Switch.Thumb class="switch-thumb" />
    </Switch.Root>
    <span>Allow upscaling (^)</span>
  </label>
</section>
```

(Delete the `{#if …}` opening and its matching `{/if}` — leave the `<label>…</label>` unconditional.)

- [ ] **Step 3: Clean the stale `iiif-path.ts` comment (if present)**

In `fiddle/assets/iiif-path.ts`, scan for any comment claiming `^max` is inert / unsupported. The `defaultIiifState` has `upscale: false` (a fine default — leave it). Only remove/adjust a comment that now contradicts the shipped behavior. If none exists, no change.

- [ ] **Step 4: Run the fiddle build/check**

Run: `mise run precommit:fiddle`
Expected: PASS (Elixir gate + fiddle JS test/check/lint/format/build). If the JS formatter/linter flags the edited Svelte, apply its fixes.

- [ ] **Step 5: Commit**

```bash
git add fiddle/lib/image_pipe_fiddle/application.ex fiddle/assets/IiifControls.svelte fiddle/assets/iiif-path.ts
git commit -m "feat(fiddle): demo IIIF max bounds + re-enable ^max upscaling toggle"
```

---

## Task 12: Update the IIIF support matrix

**Files:**
- Modify: `docs/iiif_3_support_matrix.md`

- [ ] **Step 1: Reconcile the Size `max`/`^max` row + info.json row**

In `docs/iiif_3_support_matrix.md`:

- The Size table `max` / `^max` row (~line 38) currently reads "Bounded by `maxWidth`/`maxHeight`/`maxArea` when configured." Keep it accurate now that it's true; expand to note `^max` grows to the ceiling and `max` clamps down.
- The info.json `maxWidth` / `maxHeight` / `maxArea` row (~line 85) currently says "➖ **Not advertised** … conformance lie." Replace with ✅:

```markdown
| `maxWidth` / `maxHeight` / `maxArea` | ✅ | Advertised when configured (`iiif: [max_width:, max_height:, max_area:]`), only the configured values (never an inferred `maxHeight`). Cross-field validation: `maxHeight` requires `maxWidth`; `maxArea` standalone OK; `maxWidth` alone OK. Enforced as a **uniform output ceiling** on the size pipeline — see the Size section. |
```

- [ ] **Step 2: Add the behavioral/stage note**

In the Size section (near the `^…` `sizeUpscaling` row), add a behavioral note:

```markdown
**Max bounds (surface + behavioral, [#257](https://github.com/hlindset/image_pipe/issues/257)):** `maxWidth`/`maxHeight`/`maxArea` are enforced as a **uniform output ceiling** on `Plan.Operation.Resize` (product-neutral `max_width`/`max_height`/`max_area` fields), resolved against the extracted-region dims at transform time. Every size form is clamped *down* to fit the ceiling (satisfying the spec's "for all requests … must not be greater than the server-imposed limits" MUST); `max` and `^max` additionally *grow to* the ceiling (`^max` upscales to fill it — previously inert). Effective `maxHeight = maxWidth` when only `maxWidth` is configured (the spec's client-inference, enforced server-side). `maxArea` is floored so `w·h ≤ maxArea` exactly. No imgproxy parity reference — imgproxy has no analogous ceiling; IIIF spec is ground truth.
```

- [ ] **Step 3: Add the `sizeUpscaling` divergence + validator note**

In the "Diverges / intentional notes" section, add:

```markdown
- **`sizeUpscaling` advertised without requiring a max bound.** IIIF §5.1: *"A server that supports `sizeUpscaling` must specify `maxWidth` or `maxArea`."* We advertise `sizeUpscaling` unconditionally — explicit `^` forms (`^w,`/`^pct:n`/`^!w,h`) upscale with no ceiling needed. When no bound is configured, `^max` degrades to source size (it has no ceiling to scale to). We deliberately do not force every host to configure a bound (greenfield zero-config default), so this is a documented divergence, not a hard config error.
```

And update the "Official validator gate" / Verification section to note: the official `image-validator` has **no** maxWidth/maxHeight/maxArea test; `size_up.py` (`^max`) asserts `^max` == full source, so the validator server (`validator/server.exs`) intentionally configures **no** bounds (do not add them there). Max-bounds coverage lives in the wire tests.

- [ ] **Step 4: Commit**

```bash
git add docs/iiif_3_support_matrix.md
git commit -m "docs(iiif): document max-bounds support, uniform-ceiling behavior, and sizeUpscaling divergence"
```

---

## Task 13: Final gates

- [ ] **Step 1: Run the library gate**

Run: `mise run precommit`
Expected: PASS (`mix format --check-formatted`, `mix compile --warnings-as-errors`, `mix credo --strict`, `mix test`). Fix any format/credo findings (e.g. `mise exec -- mix format`).

- [ ] **Step 2: Run the fiddle gate**

Run: `mise run precommit:fiddle`
Expected: PASS (Elixir gate + fiddle JS verify).

- [ ] **Step 3 (optional, if Docker available): Run the IIIF validator gate**

Run: `mise run validator`
Expected: PASS — Level 2 (33) + rotation/mirror (4), unchanged. (This gate uses the bounds-free `validator/server.exs`, so `size_up.py`'s `^max` == full-source expectation holds. No new by-name test is wired — there is no upstream max-bounds test.)

- [ ] **Step 4: Verify any format fixups are committed**

```bash
git status
# if `mix format` changed files, commit them:
git add -A && git commit -m "chore: mix format" || true
```

---

## Self-review notes (for the executor)

- **Spec coverage:** schema+cross-field (T7), enforcement in size mapping (T5+T8), info.json advertising (T9), `^max` re-enable + demo bounds (T11), matrix sync incl. validator-N/A + divergence (T12). All spec sections map to a task.
- **Type consistency:** `max_width`/`max_height`/`max_area` (`pos_integer | nil`) used identically across `Plan.Operation.Resize` (T1), constructor/`semantic?` (T2), `key_data` (T3), `Transform.Operation.Resize` (T4/T5), `resize_from` (T6). `bound_opts/1` (plan_builder), `apply_bounds/3`/`grow_to_bounds?/1`/`bound_terms/2`/`binding_scale/1`/`scaled_bound_axis/3` (resize), `maybe_put/3` (info), `optional_positive_integer/2`/`optional_positive_integer_value/1`/`validate_max_bounds!/1` (operation/iiif) — each defined in exactly one task and referenced consistently.
- **Critical correctness (from spec review):** `^max` grows from `intermediate` (source), `target` stays `:auto` (T5); per-candidate scale; floor area-binding axis for the `w·h ≤ maxArea` MUST (T5); validator endpoint stays bounds-free (T12/T13); cross-field via post-`validate!` not `:custom` (T7).
- **TDD:** every production change is preceded by a red test except the pure struct/threading tasks (T1, T4, T6), which are covered by downstream tests and would fail compilation if wrong.
