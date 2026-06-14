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
    case bound_scales(dims, operation) do
      [] ->
        dims

      scales ->
        scale = Enum.min(scales)
        scale = if grow?, do: scale, else: min(1.0, scale)
        # Any active max_area makes `w·h <= max_area` a MUST. Floor (rather than
        # round) both axes whenever an area bound applies, so rounding an axis up
        # can never push the product over the ceiling — regardless of which bound
        # is the binding (smallest-scale) one. When the area term binds,
        # (w·s)(h·s) == max_area exactly; when an axis binds, the product is
        # strictly below max_area; flooring keeps both <= max_area.
        floor? = area_bounded?(operation) and scale != 1.0

        %{
          width: scaled_bound_axis(dims.width, scale, floor?),
          height: scaled_bound_axis(dims.height, scale, floor?)
        }
    end
  end

  # Each configured bound contributes a scale term, skipping :auto axes.
  defp bound_scales(%{width: w, height: h}, %__MODULE__{} = op) do
    []
    |> add_axis_scale(op.max_width, w)
    |> add_axis_scale(op.max_height, h)
    |> add_area_scale(op.max_area, w, h)
  end

  defp add_axis_scale(scales, nil, _value), do: scales
  defp add_axis_scale(scales, _max, :auto), do: scales
  defp add_axis_scale(scales, max, value), do: [max / value | scales]

  defp add_area_scale(scales, nil, _w, _h), do: scales
  defp add_area_scale(scales, _max, :auto, _h), do: scales
  defp add_area_scale(scales, _max, _w, :auto), do: scales
  defp add_area_scale(scales, max, w, h), do: [:math.sqrt(max / (w * h)) | scales]

  # True when a max_area ceiling is in force on a candidate with both axes numeric.
  defp area_bounded?(%__MODULE__{max_area: nil}), do: false
  defp area_bounded?(%__MODULE__{}), do: true

  defp scaled_bound_axis(:auto, _scale, _floor?), do: :auto
  defp scaled_bound_axis(value, scale, true), do: max(1, trunc(value * scale))
  defp scaled_bound_axis(value, scale, false), do: positive_round(value * scale)
```

Notes for the implementer:
- `Enum.min/1` is only called in the non-empty branch (`scales` guaranteed non-empty there).
- **Flooring rule (the maxArea MUST):** floor both axes whenever *any* `max_area` is configured and a real scale (≠ 1.0) applies — **not** only when the area term is the binding one. A binding *axis* term with `positive_round` could otherwise push `w·h` marginally over `max_area` when an axis and the area co-bind (verified counterexample: source 7622×1774, max_width=max_height=3874, max_area=3_494_075 → 3874×902 = 3_494_348 > max_area). Flooring closes it. (`area_bounded?/1` here keys only on `max_area != nil`; a `:auto` axis means no `max_area` *scale term* was added anyway, and flooring an `:auto` axis is a no-op via `scaled_bound_axis(:auto, …)`.)
- `:auto` axes pass through in both `add_axis_scale` (no term) and `scaled_bound_axis` (returned as `:auto`).

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

  # The IIIF path sets all three bounds at once (max_height inferred + max_area).
  # This is the case the single-bound properties above miss; it exercises the
  # floor-when-area-bounded rule.
  property "all three bounds combined never exceed any ceiling" do
    check all src_w <- integer(64..8000),
              src_h <- integer(64..8000),
              max_w <- integer(64..4000),
              max_h <- integer(64..4000),
              max_a <- integer(10_000..40_000_000),
              enlarge <- boolean() do
      op = %Resize{mode: :fit, width: :auto, height: :auto, enlarge: enlarge,
                   max_width: max_w, max_height: max_h, max_area: max_a}
      r = Resize.resolve_dimensions(op, source_width: src_w, source_height: src_h)
      assert r.intermediate_width <= max_w
      assert r.intermediate_height <= max_h
      assert r.intermediate_width * r.intermediate_height <= max_a
    end
  end

  # all-nil is a genuine no-op: the bounded-but-unset op resolves identically to
  # the same op with the field-free struct default (no rounding perturbation).
  property "all-nil bounds resolve identically to the default struct" do
    check all src_w <- integer(64..8000),
              src_h <- integer(64..8000),
              w <- integer(1..8000) do
      base = %Resize{mode: :fit, width: {:pixels, w}, height: :auto, enlarge: false}
      explicit_nil = %Resize{base | max_width: nil, max_height: nil, max_area: nil}

      r_base = Resize.resolve_dimensions(base, source_width: src_w, source_height: src_h)
      r_nil = Resize.resolve_dimensions(explicit_nil, source_width: src_w, source_height: src_h)

      assert r_base.intermediate_width == r_nil.intermediate_width
      assert r_base.intermediate_height == r_nil.intermediate_height
    end
  end
end
```

- [ ] **Step 7: Run the property test**

Run: `mise exec -- mix test test/image_pipe/transform/resize_bounds_property_test.exs`
Expected: PASS (all three properties). A pure axis-cap fit holds on `positive_round` because a binding axis term `max/value` applied to `value` gives `positive_round(max) == max` exactly (integer `max`). The combined-bounds property is the one that would fail without the `area_bounded?` flooring — if it fails with `w·h == max_a + small`, confirm `floor?` floors whenever `max_area` is configured (not only when the area term binds).

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

Append to `test/parser/iiif_test.exs`. The file has a module-level `@opts` (`[iiif: [resolver: {...}]]`) and a module-level `defp validated/1`. Add the helper at **module level** (next to `validated/1`), not inside the `describe` block (the file's style; a `defp` inside `describe` compiles but reads poorly):

```elixir
  defp opts_with(extra), do: [iiif: Keyword.merge(@opts[:iiif], extra)]
```

Then the `describe` block:

```elixir
  describe "max bounds option validation" do
    test "accepts max_width alone (does not raise)" do
      assert validated = IIIF.validate_options!(opts_with(max_width: 2000))
      assert Keyword.fetch!(Keyword.fetch!(validated, :iiif), :max_width) == 2000
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

The file already has: `@source %SourcePath{segments: ["images", "beach.jpg"]}`, a `defp build(tokens), do: PlanBuilder.image_plan(@source, tokens, auto_rotate: true)` (which hardcodes opts and **cannot** thread bounds — call `image_plan/3` directly instead), `Resize` aliased **directly** (`%Resize{}`, not `%Operation.Resize{}`), and pipelines matched as bare maps `[%{operations: ops}]` (there is **no `Pipeline` alias**). A `{:max, _}`/`{:w, _, _}` size with `region: :full` produces the resize as the **only** op (region `:full` → `[]`), so pattern-match `[%Resize{} = resize]` directly. Append:

```elixir
  describe "size operations carry max bounds" do
    test "max threads bounds onto the resize with maxHeight inferred from maxWidth" do
      {:ok, %Plan{pipelines: [%{operations: [%Resize{} = resize]}]}} =
        PlanBuilder.image_plan(
          @source,
          %{region: :full, size: {:max, false}, rotation: {false, 0}, quality: :default, format: :jpg},
          max_width: 2000
        )

      assert resize.max_width == 2000
      assert resize.max_height == 2000
      assert resize.max_area == nil
    end

    test "explicit size also carries the bounds (area too)" do
      {:ok, %Plan{pipelines: [%{operations: [%Resize{} = resize]}]}} =
        PlanBuilder.image_plan(
          @source,
          %{region: :full, size: {:w, 4000, false}, rotation: {false, 0}, quality: :default, format: :jpg},
          max_width: 2000,
          max_area: 3_000_000
        )

      assert resize.max_width == 2000
      assert resize.max_height == 2000
      assert resize.max_area == 3_000_000
    end

    test "no bounds configured leaves the resize unbounded" do
      {:ok, %Plan{pipelines: [%{operations: [%Resize{} = resize]}]}} =
        PlanBuilder.image_plan(
          @source,
          %{region: :full, size: {:max, false}, rotation: {false, 0}, quality: :default, format: :jpg},
          auto_rotate: true
        )

      assert resize.max_width == nil
      assert resize.max_height == nil
      assert resize.max_area == nil
    end
  end
```

(`%Plan{}` is already aliased in the file. The first two tests omit `auto_rotate` — `image_plan/3` defaults it to `false`, irrelevant to these assertions.)

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

- [ ] **Step 1: Extend the shared `@params` attribute first (prevents a KeyError regression)**

The file has a module-level `@info %SourceInfo{format: :jpeg, width: 1000, height: 600, orientation: 1}` and a shared `@params` map (`id`/`level`/`offers`/`formats`/`qualities`/`tile_size`) reused by ~6 existing tests. Once `Info.document/2` dot-accesses `params.max_width` (Step 4), **every existing test that passes `@params` will `KeyError`** unless `@params` carries the keys. So add them to the attribute itself (default `nil`):

```elixir
  @params %{
    id: "http://x/iiif/abc",
    level: "level2",
    offers: [],
    formats: [:jpg, :png],
    qualities: [:default, :color, :gray, :bitonal],
    tile_size: 512,
    max_width: nil,
    max_height: nil,
    max_area: nil
  }
```

- [ ] **Step 2: Write the failing test**

Append to `test/parser/iiif/info_test.exs`. Reuse `@info` and `%{@params | ...}` overrides (the file's established style):

```elixir
  describe "max bounds advertising" do
    test "emits maxWidth/maxHeight/maxArea when configured" do
      doc = Info.document(@info, %{@params | max_width: 2000, max_height: 1500, max_area: 3_000_000})
      assert doc["maxWidth"] == 2000
      assert doc["maxHeight"] == 1500
      assert doc["maxArea"] == 3_000_000
    end

    test "omits unset bounds (only maxWidth configured)" do
      doc = Info.document(@info, %{@params | max_width: 2000})
      assert doc["maxWidth"] == 2000
      refute Map.has_key?(doc, "maxHeight")
      refute Map.has_key?(doc, "maxArea")
    end

    test "omits all when none configured (the @params default)" do
      doc = Info.document(@info, @params)
      refute Map.has_key?(doc, "maxWidth")
      refute Map.has_key?(doc, "maxHeight")
      refute Map.has_key?(doc, "maxArea")
    end
  end
```

- [ ] **Step 3: Run to verify failure**

Run: `mise exec -- mix test test/parser/iiif/info_test.exs`
Expected: FAIL — the `maxWidth`/etc. keys aren't in the doc yet (the new `describe` tests fail; the existing tests still pass now that `@params` carries the keys).

- [ ] **Step 4: Add the keys to `info_plan/3` params**

In `lib/image_pipe/parser/iiif/plan_builder.ex`, `info_plan/3`, extend the `params` map (after `tile_size:`):

```elixir
      tile_size: Keyword.get(opts, :tile_size, 512),
      max_width: Keyword.get(opts, :max_width),
      max_height: Keyword.get(opts, :max_height),
      max_area: Keyword.get(opts, :max_area)
    }
```

(Raw configured values, `nil` when absent. Note: advertise only configured `max_height` — do **not** apply the `|| max_width` inference here; that inference is enforcement-only, per spec.)

- [ ] **Step 5: Emit the keys in `Info.document/2`**

In `lib/image_pipe/parser/iiif/info.ex`, `document/2` currently returns a **bare map literal** ending in `"extraFeatures" => @extra_features`. Wrap that literal in parentheses and pipe it into `maybe_put` (the map literal is the last expression in the function, so the pipe must attach to the whole literal):

```elixir
    (%{
       "@context" => @context,
       # ... existing keys unchanged ...
       "extraFeatures" => @extra_features
     })
    |> maybe_put("maxWidth", params.max_width)
    |> maybe_put("maxHeight", params.max_height)
    |> maybe_put("maxArea", params.max_area)
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)
```

(If `mix format` prefers a temp binding over the parenthesized literal — e.g. `doc = %{...}; doc |> maybe_put(...)` — either form is fine; the parens just make the pipe target unambiguous. `@extra_features` stays untouched.)

- [ ] **Step 6: Run to verify pass**

Run: `mise exec -- mix test test/parser/iiif/info_test.exs`
Expected: PASS (new `describe` + all existing tests).

- [ ] **Step 7: Commit**

```bash
git add lib/image_pipe/parser/iiif/plan_builder.ex lib/image_pipe/parser/iiif/info.ex test/parser/iiif/info_test.exs
git commit -m "feat(iiif): advertise maxWidth/maxHeight/maxArea in info.json when configured"
```

---

## Task 10: End-to-end wire conformance tests

**Files:**
- Test: `test/parser/iiif_wire_test.exs`

Real end-to-end requests, decode the body, assert dimensions + info.json. **The file's real helpers (read them first):**
- `call_iiif(path, opts, req_headers \\ [])` — mounts `ImagePipe.Plug` under `script_name: ["iiif"]`; `path` is e.g. `"/img/full/^max/0/default.png"` (no `/iiif` prefix).
- `iiif_opts(origin_plug)` — base opts with `iiif: [resolver: static_resolver()]`. **There is no `@opts` attribute.** Add a bounded variant (Step 1a).
- `dimensions(conn)` → `{width, height}` (decodes `conn.resp_body`). `decoded_image(conn)` → the `Image`.
- The only origin is `OriginImage`, a **fixed 200×300 opaque PNG**. The resolver maps `"img"`/`"imgrgba"` → 200×300. **There is no "small"/"large" source** — use `"img"` (200×300) and choose ceilings relative to it: a ceiling **> 300** makes `^max` upscale; a ceiling **< 200** makes `max`/explicit clamp.
- info.json: decode with `JSON.decode!(conn.resp_body)` (already used elsewhere in the file).

- [ ] **Step 1a: Add a bounded opts helper**

Next to `iiif_opts_tile/2`, add:

```elixir
  defp iiif_opts_bounded(origin_plug, bounds) do
    [
      parser: ImagePipe.Parser.IIIF,
      iiif: [resolver: static_resolver()] ++ bounds,
      sources: [
        path: {RootHTTPAdapter, root_url: "http://origin.test", req_options: [plug: origin_plug]}
      ]
    ]
  end
```

- [ ] **Step 1b: Write the failing wire tests**

Append to `test/parser/iiif_wire_test.exs`. Expected dims are computed from the real **200×300** source (portrait → height binds for a square ceiling):

```elixir
  describe "max bounds (#257)" do
    test "^max upscales the 200x300 source toward a larger ceiling box" do
      # 1000-box on 200x300 (height-binding): scale 1000/300 -> 667x1000.
      conn = call_iiif("/img/full/^max/0/default.png", iiif_opts_bounded(OriginImage, max_width: 1000, max_height: 1000))
      assert conn.status == 200
      {w, h} = dimensions(conn)
      assert h == 1000               # grew to the ceiling on the binding axis
      assert w > 200                 # actually upscaled past native width
    end

    test "max clamps the 200x300 source down to a sub-source ceiling" do
      # 100-box on 200x300 (height-binding): scale 100/300 -> 67x100.
      conn = call_iiif("/img/full/max/0/default.png", iiif_opts_bounded(OriginImage, max_width: 100, max_height: 100))
      {w, h} = dimensions(conn)
      assert w <= 100 and h <= 100
      assert h == 100                # fits the box on the binding axis
    end

    test "explicit width exceeding maxWidth is clamped down (not 400)" do
      # request width 150 (<= 200, no upscale-400) with maxWidth 100 -> clamped.
      conn = call_iiif("/img/full/150,/0/default.png", iiif_opts_bounded(OriginImage, max_width: 100))
      assert conn.status == 200
      {w, _h} = dimensions(conn)
      assert w <= 100
    end

    test "info.json advertises configured bounds" do
      conn = call_iiif("/img/info.json", iiif_opts_bounded(OriginImage, max_width: 1000, max_height: 800, max_area: 500_000))
      body = JSON.decode!(conn.resp_body)
      assert body["maxWidth"] == 1000
      assert body["maxHeight"] == 800
      assert body["maxArea"] == 500_000
    end

    test "info.json omits bounds when unconfigured" do
      conn = call_iiif("/img/info.json", iiif_opts(OriginImage))
      body = JSON.decode!(conn.resp_body)
      refute Map.has_key?(body, "maxWidth")
      refute Map.has_key?(body, "maxHeight")
      refute Map.has_key?(body, "maxArea")
    end
  end
```

- [ ] **Step 2: Run to verify failure**

Run: `mise exec -- mix test test/parser/iiif_wire_test.exs`
Expected: FAIL on the new block (production code from Tasks 1–9 is already in place, so failures here indicate test-harness wiring; if they pass immediately that's a valid end-to-end confirmation). If a test is red on dims, recompute the expected box from the real 200×300 source — do not change production code unless a genuine bug surfaces.

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

- The Size table `max` / `^max` row (~line 38) already reads "Bounded by `maxWidth`/`maxHeight`/`maxArea` when configured." **Edit that row in place** (do not append a second overlapping description elsewhere) to note `^max` grows to the ceiling and `max` clamps down.
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
- **Type consistency:** `max_width`/`max_height`/`max_area` (`pos_integer | nil`) used identically across `Plan.Operation.Resize` (T1), constructor/`semantic?` (T2), `key_data` (T3), `Transform.Operation.Resize` (T4/T5), `resize_from` (T6). `bound_opts/1` (plan_builder), `apply_bounds/3`/`grow_to_bounds?/1`/`bound_scales/2`/`add_axis_scale/3`/`add_area_scale/4`/`area_bounded?/1`/`scaled_bound_axis/3` (resize), `maybe_put/3` (info), `optional_positive_integer/2`/`optional_positive_integer_value/1`/`validate_max_bounds!/1` (operation/iiif) — each defined in exactly one task and referenced consistently.
- **Critical correctness (from spec + plan review):** `^max` grows from `intermediate` (source), `target` stays `:auto` (T5); per-candidate scale; **floor both axes whenever `max_area` is configured** (not only when the area term binds) for the `w·h ≤ maxArea` MUST, with a combined-bounds property guarding it (T5); validator endpoint stays bounds-free (T12/T13); cross-field via post-`validate!` not `:custom` (T7); test fixtures use the real `@source`/`@params`/`call_iiif`/`dimensions`/`iiif_opts_bounded` shapes and the fixed 200×300 wire source (T8/T9/T10).
- **TDD:** every production change is preceded by a red test except the pure struct/threading tasks (T1, T4, T6), which are covered by downstream tests and would fail compilation if wrong.
