# imgproxy Pixel-Effects Cluster Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add the imgproxy Pro processing options `adjust`/`a`, `colorize`/`col`, and `gradient`/`gr`, and realign the existing `brightness`/`contrast`/`saturation` options to imgproxy's argument contract.

**Architecture:** Each effect is realized across the established layers — a neutral `ImagePipe.Plan.Operation.*` struct, an executable `ImagePipe.Transform.Operation.*` op, parser grammar + `Effects` field + `PlanBuilder` ordering, `Plan.KeyData` cache contribution, fiddle UI, and docs. `adjust` is pure parser sugar fanning out to brightness/contrast/saturation. `colorize`/`gradient` are new transform-chain overlay ops appended after `saturation` in the stage-9 effect order. All are imgproxy **Pro** with no OSS bake: arguments are made 1:1 with imgproxy (doc-sourced), pixel output is locked by ImagePipe's own fixtures.

**Tech Stack:** Elixir, Vix/libvips (`Vix.Vips.Operation`, the `Image` library), ExUnit + StreamData, Svelte/TypeScript (fiddle). Run everything through `mise exec -- ...`.

**Spec:** [docs/superpowers/specs/2026-06-19-imgproxy-pixel-effects-design.md](../specs/2026-06-19-imgproxy-pixel-effects-design.md)

**Compatibility ground truth:** imgproxy docs at `/Users/hlindset/src/imgproxy-docs/docs/usage/processing.mdx` (sections Adjust/Brightness/Contrast/Saturation/Colorize/Gradient). There is **no** OSS source for these (Pro), so the docs are authoritative for arguments.

---

## Conventions for every task

- Run focused tests with `mise exec -- mix test <file>[:line]`.
- The fresh-worktree gotcha: if `mise exec -- mix ...` fails on trust/deps, run `mise trust` and `mise exec -- mix deps.get` once first.
- Commit after each task with the message shown. Never push (that's a separate, later step).
- "Color hex" everywhere means 3- or 6-digit RGB via `ImagePipe.Plan.Color.rgb_hex/1`.

## File structure (what gets created / modified)

**New files:**
- `lib/image_pipe/plan/operation/colorize.ex` — neutral colorize struct
- `lib/image_pipe/plan/operation/gradient.ex` — neutral gradient struct
- `lib/image_pipe/transform/operation/colorize.ex` — executable colorize
- `lib/image_pipe/transform/operation/gradient.ex` — executable gradient

**Modified (core):**
- `lib/image_pipe/parser/imgproxy/option_grammar.ex` — split `:adjustment`; add colorize/gradient/adjust grammar
- `lib/image_pipe/parser/imgproxy/effects.ex` — add `colorize`, `gradient` fields
- `lib/image_pipe/parser/imgproxy/options.ex` — add the two fields to `@effect_fields`
- `lib/image_pipe/parser/imgproxy/plan_builder.ex` — realign br/co/sa no-op guards; append colorize/gradient ops; defaults
- `lib/image_pipe/plan/operation.ex` — split adjustment validation; colorize/gradient constructors + type + `semantic?`
- `lib/image_pipe/plan/operation/{brightness,contrast,saturation}.ex` — (unchanged structs; value type docs only)
- `lib/image_pipe/transform/operation/{brightness,contrast,saturation}.ex` — realign math
- `lib/image_pipe/plan/key_data.ex` — colorize/gradient cache key
- `lib/image_pipe/transform.ex` — export the two new transform ops
- `lib/image_pipe/transform/plan_executor.ex` — aliases + `executable_operations/3` for colorize/gradient

**Modified (UI/docs/tests):**
- `fiddle/assets/processing-path.ts`, `fiddle/assets/fiddle-url-state.ts`, `fiddle/assets/ImgproxyControls.svelte`
- `docs/imgproxy_support_matrix.md`, `docs/transform_operations.md`
- test files as named per task

---

# Phase 1 — Realign brightness / contrast / saturation

## Task 1: Brightness → integer `-255..255`, additive

imgproxy: `brightness` is an integer `-255..255`, default `0` (no-op), additive offset.

**Files:**
- Modify: `lib/image_pipe/parser/imgproxy/option_grammar.ex` (`@special_specs` brightness rows; add `apply_type(:brightness_value, …)` + `parse_brightness_value/1`)
- Modify: `lib/image_pipe/plan/operation.ex` (`brightness/1`, validation, `semantic?`)
- Modify: `lib/image_pipe/transform/operation/brightness.ex` (additive math)
- Modify: `lib/image_pipe/parser/imgproxy/plan_builder.ex` (`brightness_operation/1` no-op guard stays at `0`)
- Test: `test/parser/imgproxy/option_grammar_test.exs`, `test/image_pipe/transform/operation/brightness_test.exs` (create if absent), `test/image_pipe/transform/sequential_access_test.exs`

- [ ] **Step 1: Write failing parser test** — in `test/parser/imgproxy/option_grammar_test.exs`, add:

```elixir
  test "brightness accepts imgproxy integer range -255..255" do
    assert OptionGrammar.parse("br:255") == {:ok, {:pipeline, [brightness: 255]}}
    assert OptionGrammar.parse("brightness:-255") == {:ok, {:pipeline, [brightness: -255]}}
    assert OptionGrammar.parse("br:0") == {:ok, {:pipeline, [brightness: 0]}}
    assert OptionGrammar.parse("br:256") == {:error, {:invalid_brightness, "256"}}
    assert OptionGrammar.parse("br:1.5") == {:error, {:invalid_brightness, "1.5"}}
  end
```

- [ ] **Step 2: Run it, expect failure**

Run: `mise exec -- mix test test/parser/imgproxy/option_grammar_test.exs -k "brightness accepts imgproxy"`
Expected: FAIL (currently `br:256` parses; `br:1.5` parses as float; tag is `:invalid_adjustment`).

- [ ] **Step 3: Update the grammar** — in `option_grammar.ex`, change the brightness rows in `@special_specs`:

```elixir
    "brightness" => [{:brightness, :brightness_value}],
    "br" => [{:brightness, :brightness_value}],
```

Add an `apply_type` clause next to the others:

```elixir
  defp apply_type(:brightness_value, value), do: parse_brightness_value(value)
```

Add the parser near `parse_adjustment_value/1`:

```elixir
  defp parse_brightness_value(value) do
    case Integer.parse(value) do
      {integer, ""} when integer >= -255 and integer <= 255 -> {:ok, integer}
      _other -> {:error, {:invalid_brightness, value}}
    end
  end
```

- [ ] **Step 4: Run parser test, expect pass**

Run: `mise exec -- mix test test/parser/imgproxy/option_grammar_test.exs -k "brightness accepts imgproxy"`
Expected: PASS.

- [ ] **Step 5: Update the Plan.Operation constructor + validation** — in `lib/image_pipe/plan/operation.ex`:

Replace the shared `def brightness(value), do: adjustment(:brightness, Brightness, value)` with a dedicated path:

```elixir
  @spec brightness(term()) :: {:ok, Brightness.t()} | {:error, error()}
  def brightness(value) when is_integer(value) and value in @brightness_range,
    do: {:ok, %Brightness{value: value}}

  def brightness(value), do: invalid(:brightness, [value])
```

Add the range constant near `@adjustment_range`:

```elixir
  @brightness_range -255..255
```

Change the `semantic?` clause for brightness:

```elixir
  def semantic?(%Brightness{} = operation),
    do: is_integer(operation.value) and operation.value in @brightness_range
```

- [ ] **Step 6: Write failing transform test** — create `test/image_pipe/transform/operation/brightness_test.exs`:

```elixir
defmodule ImagePipe.Transform.Operation.BrightnessTest do
  use ExUnit.Case, async: true

  alias ImagePipe.Transform.Operation.Brightness
  alias ImagePipe.Transform.State
  alias Vix.Vips.Image, as: VipsImage

  defp mid_gray, do: Image.new!(4, 4, color: [128, 128, 128], bands: 3)

  test "positive brightness adds toward white" do
    {:ok, %State{image: out}} = Brightness.execute(%Brightness{value: 50}, %State{image: mid_gray()})
    [r, _g, _b] = flat_pixel(out, 0, 0)
    assert r > 170 and r < 190
  end

  test "zero brightness is identity" do
    {:ok, %State{image: out}} = Brightness.execute(%Brightness{value: 0}, %State{image: mid_gray()})
    assert flat_pixel(out, 0, 0) == [128, 128, 128]
  end

  defp flat_pixel(image, x, y), do: image |> VipsImage.get_pixel!(x, y) |> List.flatten()
end
```

(If `Image.new!/3` arity/options differ in this codebase, mirror the construction used in `test/image_pipe/imgproxy_wire_conformance_test.exs`'s `EffectOriginImage`, which builds images with `Image.new!`.)

- [ ] **Step 7: Run it, expect failure**

Run: `mise exec -- mix test test/image_pipe/transform/operation/brightness_test.exs`
Expected: FAIL (current op multiplies: value 50 → ×1.5 = 192, not ~179 additive).

- [ ] **Step 8: Make brightness additive** — replace the body of `lib/image_pipe/transform/operation/brightness.ex`:

```elixir
defmodule ImagePipe.Transform.Operation.Brightness do
  @moduledoc """
  Executable brightness adjustment operation: additive offset on the 0–255 scale
  (imgproxy `brightness`, integer -255..255).
  """

  use ImagePipe.Transform

  import ImagePipe.Transform.State

  alias ImagePipe.Transform.State
  alias Vix.Vips.Image, as: VipsImage
  alias Vix.Vips.Operation

  @enforce_keys [:value]
  defstruct [:value]

  @type t :: %__MODULE__{value: integer()}

  @impl ImagePipe.Transform
  def name(%__MODULE__{}), do: :brightness

  @impl ImagePipe.Transform
  def execute(%__MODULE__{value: value}, %State{} = state) do
    case apply_brightness(state.image, value) do
      {:ok, image} -> {:ok, set_image(state, image)}
      {:error, error} -> {:error, {__MODULE__, error}}
    end
  end

  defp apply_brightness(%VipsImage{} = image, value) do
    Image.without_alpha_band(image, fn image ->
      with {:ok, shifted} <- Operation.linear(image, [1.0], [value * 1.0]) do
        Operation.cast(shifted, VipsImage.format(image))
      end
    end)
  end
end
```

(`Operation.linear/3` with single-element coefficient lists broadcasts across all bands. `Image.without_alpha_band/2` is the same alpha-split helper `Duotone` uses; confirm its name in `lib/image_pipe/transform/operation/duotone.ex`.)

- [ ] **Step 9: Run transform test, expect pass**

Run: `mise exec -- mix test test/image_pipe/transform/operation/brightness_test.exs`
Expected: PASS.

- [ ] **Step 10: Keep the sequential-access gate green** — in `test/image_pipe/transform/sequential_access_test.exs`, the existing `"brightness streams"` test uses `%Brightness{value: 20}` (still valid). Run it:

Run: `mise exec -- mix test test/image_pipe/transform/sequential_access_test.exs -k brightness`
Expected: PASS.

- [ ] **Step 11: Update existing br assertions** — search and fix any test asserting the old multiplier/`-100..100` brightness. Run:

Run: `mise exec -- mix test test/parser/imgproxy test/image_pipe/transform -k bright`
Expected: PASS (update assertions that expected `-100..100`/multiplier behavior to the additive `-255..255` contract).

- [ ] **Step 12: Commit**

```bash
git add lib/image_pipe/parser/imgproxy/option_grammar.ex lib/image_pipe/plan/operation.ex lib/image_pipe/transform/operation/brightness.ex test/parser/imgproxy/option_grammar_test.exs test/image_pipe/transform/operation/brightness_test.exs
git commit -m "feat(imgproxy): realign brightness to imgproxy integer -255..255 additive"
```

## Task 2: Contrast → positive float, no-op at `1`

imgproxy: `contrast` is a positive float, default `1` (unchanged). The existing `Image.contrast/2` already treats `1.0` as unchanged, so drop the `(100+v)/100` remap and pass the float through.

**Files:**
- Modify: `option_grammar.ex` (contrast rows → `:scale_factor`; add `apply_type(:scale_factor, …)` + `parse_scale_factor/1`)
- Modify: `plan/operation.ex` (`contrast/1` validation + `semantic?`)
- Modify: `transform/operation/contrast.ex` (drop multiplier)
- Modify: `plan_builder.ex` (`contrast_operation/1` no-op guard → `1`)
- Test: `option_grammar_test.exs`, `plan_builder_test.exs`, a contrast transform test

- [ ] **Step 1: Write failing parser test**

```elixir
  test "contrast accepts a positive float, 1 = unchanged" do
    assert OptionGrammar.parse("co:1.5") == {:ok, {:pipeline, [contrast: 1.5]}}
    assert OptionGrammar.parse("contrast:1") == {:ok, {:pipeline, [contrast: 1.0]}}
    assert OptionGrammar.parse("co:0") == {:error, {:invalid_scale_factor, "0"}}
    assert OptionGrammar.parse("co:-1") == {:error, {:invalid_scale_factor, "-1"}}
  end
```

- [ ] **Step 2: Run it, expect failure**

Run: `mise exec -- mix test test/parser/imgproxy/option_grammar_test.exs -k "contrast accepts a positive"`
Expected: FAIL.

- [ ] **Step 3: Update grammar** — in `@special_specs`:

```elixir
    "contrast" => [{:contrast, :scale_factor}],
    "co" => [{:contrast, :scale_factor}],
    "saturation" => [{:saturation, :scale_factor}],
    "sa" => [{:saturation, :scale_factor}],
```

Add the type + parser (shared by contrast and saturation):

```elixir
  defp apply_type(:scale_factor, value), do: parse_scale_factor(value)
```

```elixir
  defp parse_scale_factor(value) do
    case parse_number(value) do
      {:ok, number} when number > 0 -> {:ok, number * 1.0}
      _other -> {:error, {:invalid_scale_factor, value}}
    end
  end
```

The `:scale_factor` type is shared by contrast and saturation, so the error tag is the generic `{:invalid_scale_factor, value}` (not per-option). Note the Step 1 test expects `{:error, {:invalid_scale_factor, "0"}}` for `co:0`.

- [ ] **Step 4: Run parser test, expect pass**

Run: `mise exec -- mix test test/parser/imgproxy/option_grammar_test.exs -k "contrast accepts a positive"`
Expected: PASS.

- [ ] **Step 5: Update Operation constructor + semantic?** — in `plan/operation.ex`:

```elixir
  @spec contrast(term()) :: {:ok, Contrast.t()} | {:error, error()}
  def contrast(value) when is_number(value) and value > 0,
    do: {:ok, %Contrast{value: value * 1.0}}

  def contrast(value), do: invalid(:contrast, [value])
```

```elixir
  def semantic?(%Contrast{} = operation),
    do: is_number(operation.value) and operation.value > 0
```

- [ ] **Step 6: Write failing transform test** — create `test/image_pipe/transform/operation/contrast_test.exs`:

```elixir
defmodule ImagePipe.Transform.Operation.ContrastTest do
  use ExUnit.Case, async: true

  alias ImagePipe.Transform.Operation.Contrast
  alias ImagePipe.Transform.State
  alias Vix.Vips.Image, as: VipsImage

  test "contrast of 1.0 is identity" do
    image = Image.new!(4, 4, color: [80, 80, 80], bands: 3)
    {:ok, %State{image: out}} = Contrast.execute(%Contrast{value: 1.0}, %State{image: image})
    assert List.flatten(VipsImage.get_pixel!(out, 0, 0)) == [80, 80, 80]
  end
end
```

- [ ] **Step 7: Run it, expect failure**

Run: `mise exec -- mix test test/image_pipe/transform/operation/contrast_test.exs`
Expected: FAIL (current op maps `1.0` → `(100+1)/100 = 1.01`, not identity).

- [ ] **Step 8: Drop the multiplier** — in `lib/image_pipe/transform/operation/contrast.ex` replace `defp multiplier(value), do: (100 + value) / 100` usage:

```elixir
  def execute(%__MODULE__{value: value}, %State{} = state) do
    case Image.contrast(state.image, value) do
      {:ok, image} -> {:ok, set_image(state, image)}
      {:error, error} -> {:error, {__MODULE__, error}}
    end
  end
```

Delete the `multiplier/1` private function.

- [ ] **Step 9: Run transform test, expect pass**

Run: `mise exec -- mix test test/image_pipe/transform/operation/contrast_test.exs`
Expected: PASS.

- [ ] **Step 10: Move the plan_builder no-op guard to 1** — in `plan_builder.ex`:

```elixir
  defp contrast_operation(%Effects{contrast: nil}), do: nil
  defp contrast_operation(%Effects{contrast: value}) when value == 1.0, do: nil
  defp contrast_operation(%Effects{contrast: value}), do: Operation.contrast(value)
```

- [ ] **Step 11: Update plan_builder + existing contrast tests** — fix any test asserting `contrast: 0` no-op or `-100..100`. Run:

Run: `mise exec -- mix test test/parser/imgproxy test/image_pipe/transform -k contrast`
Expected: PASS.

- [ ] **Step 12: Commit**

```bash
git add lib/image_pipe/parser/imgproxy/option_grammar.ex lib/image_pipe/plan/operation.ex lib/image_pipe/transform/operation/contrast.ex lib/image_pipe/parser/imgproxy/plan_builder.ex test/parser/imgproxy/option_grammar_test.exs test/image_pipe/transform/operation/contrast_test.exs
git commit -m "feat(imgproxy): realign contrast to imgproxy positive float (1 = unchanged)"
```

## Task 3: Saturation → positive float, no-op at `1`

Mirror of Task 2 (the grammar `:scale_factor` type already exists from Task 2).

**Files:** `plan/operation.ex`, `transform/operation/saturation.ex`, `plan_builder.ex`, tests.

- [ ] **Step 1: Write failing parser test**

```elixir
  test "saturation accepts a positive float, 1 = unchanged" do
    assert OptionGrammar.parse("sa:0.5") == {:ok, {:pipeline, [saturation: 0.5]}}
    assert OptionGrammar.parse("saturation:2") == {:ok, {:pipeline, [saturation: 2.0]}}
    assert OptionGrammar.parse("sa:0") == {:error, {:invalid_scale_factor, "0"}}
  end
```

- [ ] **Step 2: Run it, expect failure** — `mise exec -- mix test test/parser/imgproxy/option_grammar_test.exs -k "saturation accepts a positive"` → FAIL (grammar rows already point at `:scale_factor` from Task 2, so this may already pass for the valid cases; the failing piece is the Operation/transform below). If it passes, proceed.

- [ ] **Step 3: Update Operation constructor + semantic?**

```elixir
  @spec saturation(term()) :: {:ok, Saturation.t()} | {:error, error()}
  def saturation(value) when is_number(value) and value > 0,
    do: {:ok, %Saturation{value: value * 1.0}}

  def saturation(value), do: invalid(:saturation, [value])
```

```elixir
  def semantic?(%Saturation{} = operation),
    do: is_number(operation.value) and operation.value > 0
```

- [ ] **Step 4: Write failing transform test** — create `test/image_pipe/transform/operation/saturation_test.exs`:

```elixir
defmodule ImagePipe.Transform.Operation.SaturationTest do
  use ExUnit.Case, async: true

  alias ImagePipe.Transform.Operation.Saturation
  alias ImagePipe.Transform.State
  alias Vix.Vips.Image, as: VipsImage

  test "saturation of 1.0 is identity on a colorful pixel" do
    image = Image.new!(4, 4, color: [200, 40, 40], bands: 3)
    {:ok, %State{image: out}} = Saturation.execute(%Saturation{value: 1.0}, %State{image: image})
    [r, g, b] = List.flatten(VipsImage.get_pixel!(out, 0, 0))
    assert_in_delta r, 200, 2
    assert_in_delta g, 40, 2
    assert_in_delta b, 40, 2
  end
end
```

- [ ] **Step 5: Run it, expect failure** — `mise exec -- mix test test/image_pipe/transform/operation/saturation_test.exs` → FAIL.

- [ ] **Step 6: Drop the multiplier** — in `transform/operation/saturation.ex`, change `execute/2` to `Image.saturation(state.image, value)` and delete `multiplier/1` (same edit as contrast).

- [ ] **Step 7: Run transform test, expect pass** — PASS.

- [ ] **Step 8: Move no-op guard to 1** — in `plan_builder.ex`:

```elixir
  defp saturation_operation(%Effects{saturation: nil}), do: nil
  defp saturation_operation(%Effects{saturation: value}) when value == 1.0, do: nil
  defp saturation_operation(%Effects{saturation: value}), do: Operation.saturation(value)
```

- [ ] **Step 9: Fix existing saturation tests** — `mise exec -- mix test test/parser/imgproxy test/image_pipe/transform -k satur` → PASS.

- [ ] **Step 10: Remove now-dead shared adjustment code** — in `plan/operation.ex` delete `adjustment/3`, `adjustment_value/1`, `valid_adjustment_value?/1`, `canonical_adjustment_float/1`, and `@adjustment_range` if no remaining caller references them (grep first: `mise exec -- grep -rn "adjustment_value\|@adjustment_range\|defp adjustment(" lib/`). In `option_grammar.ex` delete `parse_adjustment_value/1` and the `apply_type(:adjustment, …)` clause if unreferenced.

- [ ] **Step 11: Run the parser + plan + transform effect tests** — `mise exec -- mix test test/parser/imgproxy test/image_pipe/transform/operation` → PASS.

- [ ] **Step 12: Commit**

```bash
git add lib/image_pipe/parser/imgproxy/option_grammar.ex lib/image_pipe/plan/operation.ex lib/image_pipe/transform/operation/saturation.ex lib/image_pipe/parser/imgproxy/plan_builder.ex test/
git commit -m "feat(imgproxy): realign saturation to positive float; drop shared adjustment helper"
```

---

# Phase 2 — `adjust` meta-option

## Task 4: `adjust` / `a` fans out to brightness/contrast/saturation

imgproxy: `a:%brightness:%contrast:%saturation`, all optional/omittable. Empty segment = use default (brightness `0`, contrast `1`, saturation `1`), which is a no-op.

**Files:**
- Modify: `option_grammar.ex` (add `parse_special_option` clause for `"adjust"`/`"a"` + `parse_adjust/2`)
- Test: `option_grammar_test.exs`, `plan_builder_test.exs`

- [ ] **Step 1: Write failing parser test**

```elixir
  test "adjust fans out to brightness/contrast/saturation" do
    assert OptionGrammar.parse("a:50") == {:ok, {:pipeline, [brightness: 50]}}
    assert OptionGrammar.parse("a::1.5") == {:ok, {:pipeline, [contrast: 1.5]}}
    assert OptionGrammar.parse("a:::0.8") == {:ok, {:pipeline, [saturation: 0.8]}}

    assert OptionGrammar.parse("adjust:10:1.2:0.9") ==
             {:ok, {:pipeline, [brightness: 10, contrast: 1.2, saturation: 0.9]}}

    assert OptionGrammar.parse("a:300") == {:error, {:invalid_brightness, "300"}}
    assert OptionGrammar.parse("a::0") == {:error, {:invalid_scale_factor, "0"}}
  end
```

- [ ] **Step 2: Run it, expect failure** — `mise exec -- mix test test/parser/imgproxy/option_grammar_test.exs -k "adjust fans out"` → FAIL (`unknown_option`).

- [ ] **Step 3: Add the parser clause** — in `option_grammar.ex`, add before the catch-all `parse_special_option(name, _args, _segment)`:

```elixir
  defp parse_special_option(name, args, segment) when name in ["adjust", "a"] do
    parse_adjust(args, segment)
  end
```

Add the bespoke parser (reuses `parse_brightness_value/1` and `parse_scale_factor/1`):

```elixir
  defp parse_adjust(args, _segment) when length(args) in 1..3 do
    specs = [{:brightness, &parse_brightness_value/1}, {:contrast, &parse_scale_factor/1}, {:saturation, &parse_scale_factor/1}]

    args
    |> Enum.zip(specs)
    |> Enum.reduce_while({:ok, []}, fn
      {"", _spec}, {:ok, acc} -> {:cont, {:ok, acc}}
      {value, {key, parser}}, {:ok, acc} ->
        case parser.(value) do
          {:ok, parsed} -> {:cont, {:ok, [{key, parsed} | acc]}}
          {:error, _reason} = error -> {:halt, error}
        end
    end)
    |> case do
      {:ok, acc} -> {:ok, Enum.reverse(acc)}
      {:error, _reason} = error -> error
    end
  end

  defp parse_adjust(_args, segment), do: {:error, {:invalid_option_segment, segment}}
```

The returned keyword (e.g. `[brightness: 50, contrast: 1.5]`) flows through `update_current_pipeline`'s `@effect_fields` clause exactly like the long forms — no `Effects` change needed.

- [ ] **Step 4: Run parser test, expect pass** — PASS.

- [ ] **Step 5: Write a plan-builder equivalence test** — in `test/parser/imgproxy/plan_builder_test.exs` (or a wire test in Task 13), assert `a:50:1.5:0.8` produces the same operations as `br:50/co:1.5/sa:0.8`. Minimal parser-level check:

```elixir
  test "adjust expands to the same effect assignments as the long forms" do
    assert OptionGrammar.parse("a:50:1.5:0.8") ==
             OptionGrammar.parse("br:50") |> merge_pipeline(OptionGrammar.parse("co:1.5")) |> merge_pipeline(OptionGrammar.parse("sa:0.8"))
  end
```

If a `merge_pipeline` helper is awkward, instead assert the literal expected keyword: `{:ok, {:pipeline, [brightness: 50, contrast: 1.5, saturation: 0.8]}}`.

- [ ] **Step 6: Run it, expect pass** — PASS.

- [ ] **Step 7: Commit**

```bash
git add lib/image_pipe/parser/imgproxy/option_grammar.ex test/parser/imgproxy/option_grammar_test.exs
git commit -m "feat(imgproxy): add adjust/a meta-option fanning to brightness/contrast/saturation"
```

---

# Phase 3 — `colorize`

## Task 5: Colorize neutral plan op + constructor + key data

imgproxy: `col:%opacity:%color:%keep_alpha`. opacity `0..1` (0 = no-op), color hex default `000`, keep_alpha bool default `false`.

**Files:**
- Create: `lib/image_pipe/plan/operation/colorize.ex`
- Modify: `lib/image_pipe/plan/operation.ex` (alias, type union, `colorize/3` constructor, `semantic?`)
- Modify: `lib/image_pipe/plan/key_data.ex` (alias + `data/1` clause)
- Test: `test/image_pipe/plan/operation_test.exs` (or wherever Operation constructors are tested — grep `def monochrome` test usage)

- [ ] **Step 1: Create the struct** — `lib/image_pipe/plan/operation/colorize.ex`:

```elixir
defmodule ImagePipe.Plan.Operation.Colorize do
  @moduledoc """
  Semantic solid-color overlay operation.
  """

  alias ImagePipe.Plan.Color

  @enforce_keys [:opacity, :color, :keep_alpha]
  defstruct [:opacity, :color, :keep_alpha]

  @type t :: %__MODULE__{
          opacity: Color.alpha(),
          color: Color.t(),
          keep_alpha: boolean()
        }
end
```

- [ ] **Step 2: Write failing constructor test** — in the Operation test file:

```elixir
  test "colorize/3 validates opacity ratio, color, keep_alpha" do
    {:ok, color} = Operation.color(0, 0, 0)
    assert {:ok, %Operation.Colorize{opacity: {:ratio, 1, 2}, keep_alpha: true}} =
             Operation.colorize({:ratio, 1, 2}, color, true)
    assert {:error, _} = Operation.colorize({:ratio, 0, 1}, color, false)
    assert {:error, _} = Operation.colorize({:ratio, 1, 2}, :not_a_color, false)
  end
```

- [ ] **Step 3: Run it, expect failure** — FAIL (`Operation.colorize/3` undefined).

- [ ] **Step 4: Implement constructor + type + semantic?** — in `plan/operation.ex`:

Add alias `alias ImagePipe.Plan.Operation.Colorize` (alphabetical, after `Canvas`). Add `| Colorize.t()` to the `effect_operation` union. Add:

```elixir
  @spec colorize(term(), term(), term()) :: {:ok, Colorize.t()} | {:error, error()}
  def colorize(opacity, %Color{} = color, keep_alpha) when is_boolean(keep_alpha) do
    with {:ok, opacity} <- effect_intensity(opacity),
         true <- Color.valid?(color) do
      {:ok, %Colorize{opacity: opacity, color: color, keep_alpha: keep_alpha}}
    else
      _reason -> invalid(:colorize, [opacity, color, keep_alpha])
    end
  end

  def colorize(opacity, color, keep_alpha), do: invalid(:colorize, [opacity, color, keep_alpha])
```

```elixir
  def semantic?(%Colorize{} = op),
    do: valid_effect_intensity?(op.opacity) and Color.valid?(op.color) and is_boolean(op.keep_alpha)
```

(`effect_intensity/1` rejects ratio `0` — exactly the no-op the plan_builder will pre-filter.)

- [ ] **Step 5: Run constructor test, expect pass** — PASS.

- [ ] **Step 6: Add the cache-key clause** — in `key_data.ex` add `alias ImagePipe.Plan.Operation.Colorize` and:

```elixir
  def data(%Colorize{} = operation) do
    [
      op: :colorize,
      opacity: data(operation.opacity),
      color: Color.key_data(operation.color),
      keep_alpha: operation.keep_alpha
    ]
  end
```

- [ ] **Step 7: Write + run a key-data test** — add to the key_data test file an assertion that two colorize ops with different opacity/color/keep_alpha produce different `data/1`. Run the key_data test file → PASS.

- [ ] **Step 8: Commit**

```bash
git add lib/image_pipe/plan/operation/colorize.ex lib/image_pipe/plan/operation.ex lib/image_pipe/plan/key_data.ex test/
git commit -m "feat(plan): add Colorize operation, constructor, and cache key"
```

## Task 6: Colorize executable transform op

Compositing contract: `out_rgb = src_rgb·(1−o) + C·o`, where `o = opacity` (float), `C` = color RGB. `keep_alpha: true` → preserve source alpha; `false` → opaque result.

**Files:**
- Create: `lib/image_pipe/transform/operation/colorize.ex`
- Modify: `lib/image_pipe/transform.ex` (export `Operation.Colorize`)
- Modify: `lib/image_pipe/transform/plan_executor.ex` (alias + `executable_operations/3` clause)
- Test: `test/image_pipe/transform/operation/colorize_test.exs`, `sequential_access_test.exs`

- [ ] **Step 1: Write failing transform test** — `test/image_pipe/transform/operation/colorize_test.exs`:

```elixir
defmodule ImagePipe.Transform.Operation.ColorizeTest do
  use ExUnit.Case, async: true

  alias ImagePipe.Transform.Operation.Colorize
  alias ImagePipe.Transform.State
  alias Vix.Vips.Image, as: VipsImage

  test "50% black overlay halves a white pixel" do
    image = Image.new!(4, 4, color: [255, 255, 255], bands: 3)
    op = %Colorize{opacity: 0.5, color: [0, 0, 0], keep_alpha: false}
    {:ok, %State{image: out}} = Colorize.execute(op, %State{image: image})
    [r, g, b] = List.flatten(VipsImage.get_pixel!(out, 0, 0))
    assert_in_delta r, 128, 2
    assert_in_delta g, 128, 2
    assert_in_delta b, 128, 2
  end
end
```

- [ ] **Step 2: Run it, expect failure** — FAIL (module undefined).

- [ ] **Step 3: Implement the op** — `lib/image_pipe/transform/operation/colorize.ex`:

```elixir
defmodule ImagePipe.Transform.Operation.Colorize do
  @moduledoc """
  Executable solid-color overlay: out = src·(1−o) + color·o.
  """

  use ImagePipe.Transform

  import ImagePipe.Transform.State

  alias ImagePipe.Transform.State
  alias Vix.Vips.Image, as: VipsImage
  alias Vix.Vips.Operation

  @enforce_keys [:opacity, :color, :keep_alpha]
  defstruct [:opacity, :color, :keep_alpha]

  @type t :: %__MODULE__{opacity: float(), color: [0..255], keep_alpha: boolean()}

  @impl ImagePipe.Transform
  def name(%__MODULE__{}), do: :colorize

  @impl ImagePipe.Transform
  def execute(%__MODULE__{opacity: o, color: [cr, cg, cb], keep_alpha: keep_alpha}, %State{} = state) do
    result =
      Image.without_alpha_band(state.image, fn rgb ->
        with {:ok, blended} <-
               Operation.linear(rgb, [1.0 - o, 1.0 - o, 1.0 - o], [cr * o, cg * o, cb * o]) do
          Operation.cast(blended, VipsImage.format(rgb))
        end
      end)

    case maybe_restore_alpha(result, state.image, keep_alpha) do
      {:ok, image} -> {:ok, set_image(state, image)}
      {:error, error} -> {:error, {__MODULE__, error}}
    end
  end

  defp maybe_restore_alpha({:error, _} = error, _src, _keep), do: error
  defp maybe_restore_alpha({:ok, rgb}, _src, false), do: {:ok, rgb}

  defp maybe_restore_alpha({:ok, rgb}, src, true) do
    case Image.has_alpha?(src) do
      false -> {:ok, rgb}
      true -> reattach_alpha(rgb, src)
    end
  end
```

Add a `reattach_alpha/2` helper that extracts the source alpha band and bandjoins it onto `rgb` (mirror how `Duotone`/`without_alpha_band` rejoin alpha — check `lib/image_pipe/transform/operation/duotone.ex` and the `Image.without_alpha_band/2` implementation for the exact rejoin call; reuse it rather than hand-rolling). End the module after the helper.

- [ ] **Step 4: Run transform test, expect pass** — PASS.

- [ ] **Step 5: Export + wire executor** — in `lib/image_pipe/transform.ex` add `Operation.Colorize` to the `exports:` list. In `plan_executor.ex` add `alias ImagePipe.Plan.Operation.Colorize, as: PlanColorize`, `alias ImagePipe.Transform.Operation.Colorize`, and:

```elixir
  defp executable_operations(%PlanColorize{} = operation, %State{}, _context) do
    [
      %Colorize{
        opacity: tagged_ratio_to_float(operation.opacity),
        color: Color.to_rgb_list(operation.color),
        keep_alpha: operation.keep_alpha
      }
    ]
  end
```

- [ ] **Step 6: Add to the sequential-access gate** — in `sequential_access_test.exs` add the alias and:

```elixir
  test "colorize streams" do
    assert_sequential_matches_random(
      [%Colorize{opacity: 0.5, color: [0, 0, 0], keep_alpha: false}],
      File.read!(@beach)
    )
  end
```

Set `requires_materialization?` default (`false`) — it is uniform, so no override needed. Run:

Run: `mise exec -- mix test test/image_pipe/transform/sequential_access_test.exs -k colorize`
Expected: PASS.

- [ ] **Step 7: Commit**

```bash
git add lib/image_pipe/transform/operation/colorize.ex lib/image_pipe/transform.ex lib/image_pipe/transform/plan_executor.ex test/image_pipe/transform
git commit -m "feat(transform): add Colorize executable op + executor wiring"
```

## Task 7: Colorize parser + plan-builder ordering

**Files:**
- Modify: `effects.ex` (add `colorize` field), `options.ex` (add to `@effect_fields`)
- Modify: `option_grammar.ex` (`parse_special_option` for `colorize`/`col` + `parse_colorize/2`)
- Modify: `plan_builder.ex` (`colorize_operation/1`, default color, append after `saturation_operation`)
- Test: `option_grammar_test.exs`, `plan_builder_test.exs`

- [ ] **Step 1: Write failing parser test**

```elixir
  test "colorize parses opacity, optional color, optional keep_alpha" do
    assert OptionGrammar.parse("col:0.5") ==
             {:ok, {:pipeline, [colorize: [opacity: {:ratio, 5, 10}]]}}

    assert OptionGrammar.parse("colorize:1:ff0000:1") ==
             {:ok, {:pipeline, [colorize: [opacity: {:ratio, 1, 1}, color: color!(255, 0, 0), keep_alpha: true]]}}

    assert OptionGrammar.parse("col:0.5:zzz") == {:error, {:invalid_colorize, "zzz"}}
  end
```

- [ ] **Step 2: Run it, expect failure** — FAIL.

- [ ] **Step 3: Add the field** — in `effects.ex` add `colorize: keyword() | nil` to the type and `colorize: nil` to the struct; in `options.ex` add `:colorize` to `@effect_fields`.

- [ ] **Step 4: Add grammar** — in `option_grammar.ex`, add a `parse_special_option` clause for `["colorize", "col"]` → `parse_colorize(args, segment)`, and:

```elixir
  defp parse_colorize([opacity], _segment) when opacity != "" do
    with {:ok, opacity} <- parse_intensity(opacity), do: {:ok, [colorize: [opacity: opacity]]}
  end

  defp parse_colorize([opacity, color], segment) when opacity != "" do
    parse_colorize([opacity, color, ""], segment)
  end

  defp parse_colorize([opacity, color, keep_alpha], _segment) when opacity != "" do
    with {:ok, opacity} <- parse_intensity(opacity),
         {:ok, color_assignments} <- parse_optional_colorize_color(color),
         {:ok, keep_assignments} <- parse_optional_keep_alpha(keep_alpha) do
      {:ok, [colorize: [opacity: opacity] ++ color_assignments ++ keep_assignments]}
    else
      {:error, {:invalid_color, _}} -> {:error, {:invalid_colorize, color}}
      {:error, _reason} = error -> error
    end
  end

  defp parse_colorize(_args, segment), do: {:error, {:invalid_option_segment, segment}}

  defp parse_optional_colorize_color(""), do: {:ok, []}
  defp parse_optional_colorize_color(value) do
    with {:ok, color} <- Color.rgb_hex(value), do: {:ok, [color: color]}
  end

  defp parse_optional_keep_alpha(""), do: {:ok, []}
  defp parse_optional_keep_alpha(value) do
    with {:ok, bool} <- parse_boolean(value), do: {:ok, [keep_alpha: bool]}
  end
```

- [ ] **Step 5: Run parser test, expect pass** — PASS.

- [ ] **Step 6: Write failing plan-builder ordering test** — in `plan_builder_test.exs`, assert colorize appears after saturation and before padding/background:

```elixir
  test "colorize plans after saturation" do
    assert {:ok, %Plan{pipelines: [%Pipeline{operations: ops}]}} =
             plan_pipeline(saturation: 1.5, colorize: [opacity: ratio(1, 2), color: color!(0, 0, 0)])

    assert [%Operation.Saturation{}, %Operation.Colorize{}] = ops
  end

  test "colorize opacity 0 is a no-op" do
    assert {:ok, %Plan{pipelines: [%Pipeline{operations: []}]}} =
             plan_pipeline(colorize: [opacity: ratio(0, 1)])
  end
```

- [ ] **Step 7: Run it, expect failure** — FAIL.

- [ ] **Step 8: Wire plan_builder** — in `effect_operations/1` append `colorize_operation(effects)` **after** `saturation_operation(effects)` in the list. Add:

```elixir
  defp colorize_operation(%Effects{colorize: nil}), do: nil
  defp colorize_operation(%Effects{colorize: colorize}) do
    case Keyword.fetch!(colorize, :opacity) do
      {:ratio, 0, _} ->
        nil

      _opacity ->
        Operation.colorize(
          Keyword.fetch!(colorize, :opacity),
          Keyword.get_lazy(colorize, :color, &default_colorize_color/0),
          Keyword.get(colorize, :keep_alpha, false)
        )
    end
  end

  defp default_colorize_color, do: color!(0, 0, 0)
```

(A keyword list can't be head-matched with `++` in a pattern, and the single-element monochrome-style match (`[opacity: {:ratio, 0, _}]`) would miss a colorize that also carries `color`/`keep_alpha`. So the no-op check reads the opacity via `Keyword.fetch!` — the same shape gradient uses in Task 10.)

- [ ] **Step 9: Run plan-builder test, expect pass** — PASS.

- [ ] **Step 10: Commit**

```bash
git add lib/image_pipe/parser/imgproxy/effects.ex lib/image_pipe/parser/imgproxy/options.ex lib/image_pipe/parser/imgproxy/option_grammar.ex lib/image_pipe/parser/imgproxy/plan_builder.ex test/parser/imgproxy
git commit -m "feat(imgproxy): parse colorize/col and plan it after saturation"
```

---

# Phase 4 — `gradient`

## Task 8: Gradient neutral plan op + constructor + key data

imgproxy: `gr:%opacity:%color:%direction:%start:%stop`. opacity `0..1` (0 = no-op), color default `000`, direction named (`down`/`up`/`right`/`left`) or clockwise angle (0°=down, 90°=left, 180°=up, 270°=right), start/stop in `[0,1]` defaults `0.0`/`1.0`.

**Files:**
- Create: `lib/image_pipe/plan/operation/gradient.ex`
- Modify: `plan/operation.ex` (alias, type, `gradient/5`, `semantic?`)
- Modify: `key_data.ex`
- Test: Operation + key_data tests

- [ ] **Step 1: Create struct** — `lib/image_pipe/plan/operation/gradient.ex`:

```elixir
defmodule ImagePipe.Plan.Operation.Gradient do
  @moduledoc """
  Semantic transparency→color gradient overlay operation.

  `angle` is canonical clockwise degrees (0=down, 90=left, 180=up, 270=right).
  """

  alias ImagePipe.Plan.Color

  @enforce_keys [:opacity, :color, :angle, :start, :stop]
  defstruct [:opacity, :color, :angle, :start, :stop]

  @type t :: %__MODULE__{
          opacity: Color.alpha(),
          color: Color.t(),
          angle: float(),
          start: float(),
          stop: float()
        }
end
```

- [ ] **Step 2: Write failing constructor test**

```elixir
  test "gradient/5 validates fields and clamps start/stop to [0,1]" do
    {:ok, color} = Operation.color(0, 0, 0)
    assert {:ok, %Operation.Gradient{angle: 90.0, start: 0.0, stop: 1.0}} =
             Operation.gradient({:ratio, 1, 2}, color, 90.0, 0.0, 1.0)
    assert {:error, _} = Operation.gradient({:ratio, 0, 1}, color, 0.0, 0.0, 1.0)
    assert {:error, _} = Operation.gradient({:ratio, 1, 2}, color, 0.0, -0.1, 1.0)
  end
```

- [ ] **Step 3: Run it, expect failure** — FAIL.

- [ ] **Step 4: Implement constructor + type + semantic?** — in `plan/operation.ex` add `alias ImagePipe.Plan.Operation.Gradient`, `| Gradient.t()` in the union, and:

```elixir
  @spec gradient(term(), term(), term(), term(), term()) :: {:ok, Gradient.t()} | {:error, error()}
  def gradient(opacity, %Color{} = color, angle, start, stop)
      when is_number(angle) and is_number(start) and is_number(stop) and
             start >= 0 and start <= 1 and stop >= 0 and stop <= 1 do
    with {:ok, opacity} <- effect_intensity(opacity),
         true <- Color.valid?(color) do
      {:ok, %Gradient{opacity: opacity, color: color, angle: angle * 1.0, start: start * 1.0, stop: stop * 1.0}}
    else
      _reason -> invalid(:gradient, [opacity, color, angle, start, stop])
    end
  end

  def gradient(opacity, color, angle, start, stop),
    do: invalid(:gradient, [opacity, color, angle, start, stop])
```

```elixir
  def semantic?(%Gradient{} = op),
    do:
      valid_effect_intensity?(op.opacity) and Color.valid?(op.color) and is_number(op.angle) and
        is_number(op.start) and is_number(op.stop) and op.start >= 0 and op.start <= 1 and
        op.stop >= 0 and op.stop <= 1
```

- [ ] **Step 5: Run constructor test, expect pass** — PASS.

- [ ] **Step 6: Add key-data clause** — in `key_data.ex` (`alias …Gradient`):

```elixir
  def data(%Gradient{} = operation) do
    [
      op: :gradient,
      opacity: data(operation.opacity),
      color: Color.key_data(operation.color),
      angle: operation.angle,
      start: operation.start,
      stop: operation.stop
    ]
  end
```

- [ ] **Step 7: Run a key-data difference test** — PASS.

- [ ] **Step 8: Commit**

```bash
git add lib/image_pipe/plan/operation/gradient.ex lib/image_pipe/plan/operation.ex lib/image_pipe/plan/key_data.ex test/
git commit -m "feat(plan): add Gradient operation, constructor, and cache key"
```

## Task 9: Gradient executable transform op (directional ramp)

Compositing contract: `m(x,y) = opacity · clamp01((p(x,y) − start)/(stop − start))`, then `out_rgb = src_rgb·(1−m) + C·m`, source alpha preserved. `p(x,y) ∈ [0,1]` is the normalized projection of the pixel onto the direction unit vector for `angle` (0°=down → p increases with y; 90°=left → p increases as x decreases; etc.).

**Files:**
- Create: `lib/image_pipe/transform/operation/gradient.ex`
- Modify: `transform.ex` (export), `plan_executor.ex` (alias + clause)
- Test: `test/image_pipe/transform/operation/gradient_test.exs`, `sequential_access_test.exs`

- [ ] **Step 1: Write failing transform test** — assert direction with a full-strength black gradient over white, default start/stop:

```elixir
defmodule ImagePipe.Transform.Operation.GradientTest do
  use ExUnit.Case, async: true

  alias ImagePipe.Transform.Operation.Gradient
  alias ImagePipe.Transform.State
  alias Vix.Vips.Image, as: VipsImage

  defp white(w \\ 16, h \\ 16), do: Image.new!(w, h, color: [255, 255, 255], bands: 3)
  defp lum(image, x, y), do: image |> VipsImage.get_pixel!(x, y) |> List.flatten() |> hd()

  test "down gradient (0°): top transparent, bottom opaque black" do
    op = %Gradient{opacity: 1.0, color: [0, 0, 0], angle: 0.0, start: 0.0, stop: 1.0}
    {:ok, %State{image: out}} = Gradient.execute(op, %State{image: white()})
    assert lum(out, 8, 0) > 230
    assert lum(out, 8, 15) < 25
  end

  test "left gradient (90°): right transparent, left opaque" do
    op = %Gradient{opacity: 1.0, color: [0, 0, 0], angle: 90.0, start: 0.0, stop: 1.0}
    {:ok, %State{image: out}} = Gradient.execute(op, %State{image: white()})
    assert lum(out, 15, 8) > 230
    assert lum(out, 0, 8) < 25
  end
end
```

- [ ] **Step 2: Run it, expect failure** — FAIL (module undefined).

- [ ] **Step 3: Implement the op** — `lib/image_pipe/transform/operation/gradient.ex`. Algorithm: build a coordinate image, project onto the direction vector, normalize to `p ∈ [0,1]`, compute mask `m`, blend.

```elixir
defmodule ImagePipe.Transform.Operation.Gradient do
  @moduledoc """
  Executable transparency→color gradient overlay.

  out = src·(1−m) + color·m, where m = opacity · clamp01((p − start)/(stop − start))
  and p is the normalized projection of each pixel onto the gradient direction.
  """

  use ImagePipe.Transform

  import ImagePipe.Transform.State

  alias ImagePipe.Transform.State
  alias Vix.Vips.Image, as: VipsImage
  alias Vix.Vips.Operation

  @enforce_keys [:opacity, :color, :angle, :start, :stop]
  defstruct [:opacity, :color, :angle, :start, :stop]

  @type t :: %__MODULE__{opacity: float(), color: [0..255], angle: float(), start: float(), stop: float()}

  @impl ImagePipe.Transform
  def name(%__MODULE__{}), do: :gradient

  @impl ImagePipe.Transform
  def execute(%__MODULE__{} = op, %State{} = state) do
    case apply_gradient(state.image, op) do
      {:ok, image} -> {:ok, set_image(state, image)}
      {:error, error} -> {:error, {__MODULE__, error}}
    end
  end

  defp apply_gradient(%VipsImage{} = image, %__MODULE__{} = op) do
    width = VipsImage.width(image)
    height = VipsImage.height(image)
    Image.without_alpha_band(image, fn rgb ->
      with {:ok, mask} <- gradient_mask(width, height, op),
           {:ok, blended} <- blend(rgb, mask, op.color) do
        Operation.cast(blended, VipsImage.format(rgb))
      end
    end)
    # NOTE: source alpha is rejoined by without_alpha_band/2 automatically; confirm.
  end

  # p(x,y) = ((x/(w-1)) * dx + (y/(h-1)) * dy) mapped into [0,1] for the direction.
  # Direction unit vector for clockwise angle θ with 0°=down:
  #   dx = -sin θ, dy = cos θ   (so 0°→(0,1)=down, 90°→(-1,0)=left)
  # Build a normalized coordinate ramp with Operation.xyz + linear, project, clamp.
  defp gradient_mask(width, height, %__MODULE__{angle: angle, start: start, stop: stop, opacity: opacity}) do
    # 1. coords = xyz(width,height) → 2-band [x,y]; normalize each axis to [0,1]
    # 2. project: p = nx*dx_pos + ny*dy_pos shifted so p∈[0,1] across the image
    # 3. ramp = clamp01((p - start)/(stop - start)); m = ramp * opacity
    # Implement with Vix.Vips.Operation.{xyz,linear,extract_band,add,multiply,clamp}.
    # Return {:ok, single_band_float_image_in_0..1}.
    :erlang.error(:todo)
  end

  defp blend(rgb, mask, [cr, cg, cb]) do
    # out = rgb*(1-mask) + color*mask, broadcasting the 1-band mask over 3 bands.
    with {:ok, inv} <- Operation.linear(mask, [-1.0], [1.0]),
         {:ok, src_term} <- Operation.multiply(rgb, inv),
         {:ok, color_img} <- color_constant(rgb, [cr, cg, cb]),
         {:ok, col_term} <- Operation.multiply(color_img, mask) do
      Operation.add(src_term, col_term)
    end
  end

  defp color_constant(ref, channels) do
    # A constant image matching ref's size/bands filled with `channels`.
    Operation.black(VipsImage.width(ref), VipsImage.height(ref), bands: length(channels))
    |> case do
      {:ok, base} -> Operation.linear(base, [1.0], Enum.map(channels, &(&1 * 1.0)))
      error -> error
    end
  end
end
```

**Implementer note:** the `gradient_mask/3` body is the only genuinely new math. Confirm the exact `Vix.Vips.Operation` signatures (`xyz/2`, `extract_band/3`, `linear/3`, `relational_const`/`clamp` for clamping) via `mise exec -- iex -S mix` and `h Vix.Vips.Operation.xyz`. The test in Step 1 (down + left directions, opaque endpoints) is the contract — iterate the mask math until both pass, then add `up` (180°) and `right` (270°) cases plus an oblique `45°` smoke case. Multiply/add broadcasting of a 1-band mask over a 3-band image is standard libvips; if `Operation.multiply` rejects mismatched bands, replicate the mask to 3 bands with `Operation.bandjoin` first.

- [ ] **Step 4: Iterate to green** — implement `gradient_mask/3`, run:

Run: `mise exec -- mix test test/image_pipe/transform/operation/gradient_test.exs`
Expected: PASS for down + left. Add up/right/45° cases and a `start`/`stop` case (e.g. `start: 0.25, stop: 0.75` keeps the top quarter fully transparent), re-run until all pass.

- [ ] **Step 5: Export + wire executor** — add `Operation.Gradient` to `transform.ex` exports; in `plan_executor.ex` add `alias ImagePipe.Plan.Operation.Gradient, as: PlanGradient`, `alias ImagePipe.Transform.Operation.Gradient`, and:

```elixir
  defp executable_operations(%PlanGradient{} = operation, %State{}, _context) do
    [
      %Gradient{
        opacity: tagged_ratio_to_float(operation.opacity),
        color: Color.to_rgb_list(operation.color),
        angle: operation.angle,
        start: operation.start,
        stop: operation.stop
      }
    ]
  end
```

- [ ] **Step 6: Flush pending orientation before gradient (display-frame correctness)** — gradient is **directional**, so like `pixelate`/`padding` it must run in the display frame. On the resize-less path the EXIF/user orientation is still pending (a resize would already have flushed). Add a dedicated `execute_operation` clause in `plan_executor.ex` next to the `PlanPixelate`/`PlanPadding` clauses (around line 303), mirroring them exactly:

```elixir
  defp execute_operation(
         %PlanGradient{} = operation,
         %State{pending_orientation: po} = state,
         ctx,
         opts
       )
       when not is_nil(po) do
    with {:ok, %State{} = state} <- flush_if_pending(state) do
      run_executable(operation, state, ctx, opts)
    end
  end
```

Extend the existing stage-9 comment above the pixelate clause to mention gradient's direction (same display-frame reason). `colorize` is uniform and needs **no** such clause — it commutes with orientation.

- [ ] **Step 7: Lock the display frame with a test** — write an executor-level test that builds a `%State{}` carrying a non-identity `pending_orientation` (orientation 6 / quarter turn) over a tall image, runs a `%PlanGradient{}` with `angle: 0.0` (down) through `PlanExecutor`'s operation path, and asserts the dark (opaque) end lands on the **display** bottom, not the storage edge. Mirror the setup of the existing pixelate/padding display-frame tests (grep `pending_orientation` in `test/image_pipe/transform/` for the established harness). Run it; expect PASS only with the Step 6 clause present (remove the clause to confirm it fails, then restore).

- [ ] **Step 8: Sequential-access gate** — add to `sequential_access_test.exs`:

```elixir
  test "gradient streams" do
    assert_sequential_matches_random(
      [%Gradient{opacity: 1.0, color: [0, 0, 0], angle: 0.0, start: 0.0, stop: 1.0}],
      File.read!(@beach)
    )
  end
```

Run: `mise exec -- mix test test/image_pipe/transform/sequential_access_test.exs -k gradient` → PASS. (The gradient mask is a function of pixel coordinates, sequential-safe; no materialization override.)

- [ ] **Step 9: Commit**

```bash
git add lib/image_pipe/transform/operation/gradient.ex lib/image_pipe/transform.ex lib/image_pipe/transform/plan_executor.ex test/image_pipe/transform
git commit -m "feat(transform): add Gradient executable op + display-frame executor wiring"
```

## Task 10: Gradient parser + plan-builder ordering

**Files:** `effects.ex`, `options.ex`, `option_grammar.ex`, `plan_builder.ex`, parser/plan tests.

- [ ] **Step 1: Write failing parser test**

```elixir
  test "gradient parses opacity + optional color/direction/start/stop" do
    assert OptionGrammar.parse("gr:0.5") ==
             {:ok, {:pipeline, [gradient: [opacity: {:ratio, 5, 10}]]}}

    assert OptionGrammar.parse("gradient:1:ff0000:left:0.25:0.75") ==
             {:ok, {:pipeline, [gradient: [opacity: {:ratio, 1, 1}, color: color!(255, 0, 0), angle: 90.0, start: 0.25, stop: 0.75]]}}

    assert OptionGrammar.parse("gr:1::45") ==
             {:ok, {:pipeline, [gradient: [opacity: {:ratio, 1, 1}, angle: 45.0]]}}

    assert OptionGrammar.parse("gr:0.5::sideways") == {:error, {:invalid_gradient, "sideways"}}
  end
```

- [ ] **Step 2: Run it, expect failure** — FAIL.

- [ ] **Step 3: Add field** — `effects.ex`: `gradient: keyword() | nil` + `gradient: nil`; `options.ex`: `:gradient` in `@effect_fields`.

- [ ] **Step 4: Add grammar** — `parse_special_option` for `["gradient", "gr"]` → `parse_gradient(args, segment)`. Implement variadic parsing (1–5 args), with direction parse:

```elixir
  @gradient_directions %{"down" => 0.0, "left" => 90.0, "up" => 180.0, "right" => 270.0}

  defp parse_gradient([opacity | rest], segment) when opacity != "" and length(rest) <= 4 do
    with {:ok, opacity} <- parse_intensity(opacity),
         {:ok, assignments} <- parse_gradient_tail(rest) do
      {:ok, [gradient: [opacity: opacity] ++ assignments]}
    else
      {:error, {:invalid_color, c}} -> {:error, {:invalid_gradient, c}}
      {:error, {:invalid_gradient, _}} = error -> error
      {:error, _reason} = error -> error
    end
  end

  defp parse_gradient(_args, segment), do: {:error, {:invalid_option_segment, segment}}

  # rest = [color, direction, start, stop] (any trailing omitted; empty = default)
  defp parse_gradient_tail(rest) do
    [color, direction, start, stop] = rest ++ List.duplicate("", 4 - length(rest))

    with {:ok, color_kw} <- parse_optional_colorize_color(color),
         {:ok, dir_kw} <- parse_optional_gradient_direction(direction),
         {:ok, start_kw} <- parse_optional_gradient_pos(:start, start),
         {:ok, stop_kw} <- parse_optional_gradient_pos(:stop, stop) do
      {:ok, color_kw ++ dir_kw ++ start_kw ++ stop_kw}
    end
  end

  defp parse_optional_gradient_direction(""), do: {:ok, []}
  defp parse_optional_gradient_direction(value) do
    case Map.fetch(@gradient_directions, value) do
      {:ok, angle} -> {:ok, [angle: angle]}
      :error ->
        case parse_number(value) do
          {:ok, number} -> {:ok, [angle: normalize_angle(number)]}
          {:error, _} -> {:error, {:invalid_gradient, value}}
        end
    end
  end

  defp parse_optional_gradient_pos(_field, ""), do: {:ok, []}
  defp parse_optional_gradient_pos(field, value) do
    case parse_number(value) do
      {:ok, number} when number >= 0 and number <= 1 -> {:ok, [{field, number * 1.0}]}
      _other -> {:error, {:invalid_gradient, value}}
    end
  end

  defp normalize_angle(number) do
    angle = :math.fmod(number * 1.0, 360.0)
    if angle < 0, do: angle + 360.0, else: angle
  end
```

(`parse_optional_colorize_color/1` from Task 7 is reused for the gradient color.)

- [ ] **Step 5: Run parser test, expect pass** — PASS.

- [ ] **Step 6: Write failing plan-builder ordering test**

```elixir
  test "gradient plans after colorize" do
    assert {:ok, %Plan{pipelines: [%Pipeline{operations: ops}]}} =
             plan_pipeline(
               colorize: [opacity: ratio(1, 2), color: color!(0, 0, 0)],
               gradient: [opacity: ratio(1, 2), color: color!(0, 0, 0), angle: 0.0]
             )

    assert [%Operation.Colorize{}, %Operation.Gradient{}] = ops
  end
```

- [ ] **Step 7: Run it, expect failure** — FAIL.

- [ ] **Step 8: Wire plan_builder** — append `gradient_operation(effects)` after `colorize_operation(effects)`. Add:

```elixir
  defp gradient_operation(%Effects{gradient: nil}), do: nil
  defp gradient_operation(%Effects{gradient: gradient}) do
    case Keyword.fetch!(gradient, :opacity) do
      {:ratio, 0, _} -> nil
      _opacity ->
        Operation.gradient(
          Keyword.fetch!(gradient, :opacity),
          Keyword.get_lazy(gradient, :color, &default_colorize_color/0),
          Keyword.get(gradient, :angle, 0.0),
          Keyword.get(gradient, :start, 0.0),
          Keyword.get(gradient, :stop, 1.0)
        )
    end
  end
```

(Default direction = `down` = `0.0`, defaults start `0.0` / stop `1.0`, default color black — matching imgproxy.)

- [ ] **Step 9: Run plan-builder test, expect pass** — PASS.

- [ ] **Step 10: Commit**

```bash
git add lib/image_pipe/parser/imgproxy/effects.ex lib/image_pipe/parser/imgproxy/options.ex lib/image_pipe/parser/imgproxy/option_grammar.ex lib/image_pipe/parser/imgproxy/plan_builder.ex test/parser/imgproxy
git commit -m "feat(imgproxy): parse gradient/gr (named+angle direction) and plan after colorize"
```

---

# Phase 5 — Fiddle UI, docs, wire tests, full gate

## Task 11: Fiddle UI — realign br/co/sa controls, add colorize/gradient

**Files:** `fiddle/assets/processing-path.ts`, `fiddle/assets/fiddle-url-state.ts`, `fiddle/assets/ImgproxyControls.svelte`, `fiddle/assets/processing-path.test.ts`

- [ ] **Step 1: Update `controlLimits.effects` + state types/defaults** — in `processing-path.ts`:

```typescript
  effects: {
    blur: { min: 0.1, max: 10, step: 0.1 },
    sharpen: { min: 0.1, max: 10, step: 0.1 },
    pixelate: { min: 2, max: 80, step: 1 },
    intensity: { min: 0, max: 1, step: 0.01 },
    brightness: { min: -255, max: 255, step: 1 },
    contrast: { min: 0, max: 4, step: 0.05 },
    saturation: { min: 0, max: 4, step: 0.05 },
  },
```

Add to `FiddleState`: `colorizeEnabled/colorizeOpacity/colorizeColor/colorizeKeepAlpha`, and `gradientEnabled/gradientOpacity/gradientColor/gradientDirection/gradientStart/gradientStop`. Update `defaultFiddleState`: `contrast: 1.2`, `saturation: 1.2` (was `20`); add the new fields' defaults (`colorizeOpacity: 0.5`, `colorizeColor: "#000000"`, `colorizeKeepAlpha: false`, `gradientOpacity: 0.5`, `gradientColor: "#000000"`, `gradientDirection: "down"`, `gradientStart: 0`, `gradientStop: 1`).

- [ ] **Step 2: Update `optionSegments`** — change nothing for br (still `br:${brightness}`); colorize/gradient:

```typescript
  if (currentState.colorizeEnabled) {
    segments.push(`col:${currentState.colorizeOpacity}:${currentState.colorizeColor.replace(/^#/, "")}:${currentState.colorizeKeepAlpha ? 1 : 0}`);
  }
  if (currentState.gradientEnabled) {
    segments.push(`gr:${currentState.gradientOpacity}:${currentState.gradientColor.replace(/^#/, "")}:${currentState.gradientDirection}:${currentState.gradientStart}:${currentState.gradientStop}`);
  }
```

- [ ] **Step 3: Update `fiddle-url-state.ts` parsing** — change contrast/saturation `parseAdjustmentOption` no-op sentinel from `0` to `1` (enable when `value !== 1`); brightness stays `value !== 0`. Add `col`/`colorize` and `gr`/`gradient` parse cases populating the new state fields.

- [ ] **Step 4: Update `ImgproxyControls.svelte`** — change the brightness/contrast/saturation `RangeNumber` to use the new limits and drop the `suffix="%"` (they're no longer percentages; brightness is a level, contrast/saturation are factors). Add Colorize and Gradient control blocks following the monochrome/duotone switch+RangeNumber+color-input pattern (opacity via the `intensity` limit, a color input, a keep-alpha switch for colorize; opacity, color, a direction text/select, start/stop ranges for gradient).

- [ ] **Step 5: Update + run the fiddle path test** — in `processing-path.test.ts`, add round-trip cases for `col:...` and `gr:...` and the new br/co/sa ranges. Build + test:

Run: `pnpm -C fiddle/assets install --frozen-lockfile && pnpm -C fiddle/assets run build && pnpm -C fiddle/assets test`
Expected: PASS. (Per the worktree note, the fiddle build must run before `mix test` in `precommit:fiddle`.)

- [ ] **Step 6: Commit**

```bash
git add fiddle/assets
git commit -m "feat(fiddle): realign br/co/sa controls; add colorize + gradient controls"
```

## Task 12: Docs — support matrix + transform order + progressive_blur gap

**Files:** `docs/imgproxy_support_matrix.md`, `docs/transform_operations.md`

- [ ] **Step 1: Update the effect order in `docs/transform_operations.md`** — change the line "Imgproxy effect order is blur, sharpen, pixelate, monochrome, duotone, brightness, contrast, then saturation." to append "…, saturation, colorize, then gradient."

- [ ] **Step 2: Update `docs/imgproxy_support_matrix.md` "Background, effects, and overlays" table** — add `adjust`/`a` row (✅ Supported, "Meta-option → brightness/contrast/saturation; 1:1 imgproxy args"); flip `colorize`/`col` and `gradient`/`gr` to ✅ Supported with the compositing-contract + "Pro, pixels not bake-verified" note; update `brightness`/`contrast`/`saturation` rows to drop the `-100..100` divergence and state the imgproxy-1:1 argument contract (brightness int `-255..255` additive; contrast/saturation positive float, `1` unchanged).

- [ ] **Step 3: Update the stage-9 pipeline row** — in the "Main pipeline" stage-9 `applyFilters` row, add colorize/gradient to the overlay ops list realized in the transform chain.

- [ ] **Step 4: Add the missing `progressive_blur`/`pbl` ⭕ row** — add a row to the effects table marking `progressive_blur`/`pbl` as ⭕ Missing, linking issue #346 (matrix-inventory gap fix).

- [ ] **Step 5: Commit**

```bash
git add docs/imgproxy_support_matrix.md docs/transform_operations.md
git commit -m "docs(imgproxy): document adjust/colorize/gradient + br/co/sa realignment; add pbl gap row"
```

## Task 13: Wire conformance tests

**Files:** `test/image_pipe/imgproxy_wire_conformance_test.exs`

- [ ] **Step 1: Add no-geometry pixel-change cases** — extend the existing `EffectOriginImage`-backed test (or add a sibling) asserting decoded pixels change vs a baseline, with no resize/crop:

```elixir
  test "colorize/gradient/adjust change decoded pixels without geometry" do
    baseline = "/_/f:png/plain/images/effects.png" |> call_imgproxy(effect_origin_opts()) |> decoded_image()

    for path <- [
          "/_/col:0.5:ff0000/f:png/plain/images/effects.png",
          "/_/gr:0.6:000000:down/f:png/plain/images/effects.png",
          "/_/a:40:1.4:0.7/f:png/plain/images/effects.png"
        ] do
      image = path |> call_imgproxy(effect_origin_opts()) |> decoded_image()
      assert dimensions(image) == dimensions(baseline)
      assert sampled_pixels(image) != sampled_pixels(baseline)
    end
  end
```

- [ ] **Step 2: Add an `adjust` ≡ long-form equivalence wire case** — assert `a:40:1.4:0.7` yields byte-identical output to `br:40/co:1.4/sa:0.7`:

```elixir
  test "adjust produces the same bytes as the equivalent br/co/sa" do
    via_adjust = "/_/a:40:1.4:0.7/f:png/plain/images/effects.png" |> call_imgproxy(effect_origin_opts())
    via_long = "/_/br:40/co:1.4/sa:0.7/f:png/plain/images/effects.png" |> call_imgproxy(effect_origin_opts())
    assert via_adjust.resp_body == via_long.resp_body
  end
```

- [ ] **Step 3: Run the wire test**

Run: `mise exec -- mix test test/image_pipe/imgproxy_wire_conformance_test.exs`
Expected: PASS.

- [ ] **Step 4: Commit**

```bash
git add test/image_pipe/imgproxy_wire_conformance_test.exs
git commit -m "test(imgproxy): wire coverage for adjust/colorize/gradient + adjust≡long-form"
```

## Task 14: Full gate + cleanup

- [ ] **Step 1: Run the Elixir gate**

Run: `mise run precommit`
Expected: `mix format --check-formatted`, `mix compile --warnings-as-errors`, `mix credo --strict`, `mix test` all green. Fix anything (formatting, unused aliases from the adjustment-helper removal, credo).

- [ ] **Step 2: Run the fiddle gate**

Run: `mise run precommit:fiddle`
Expected: PASS (Elixir gate + fiddle JS test/check/lint/format/build).

- [ ] **Step 3: Architecture boundary check** — confirm no request/source/response module names a concrete transform op and the parser emits only `Plan.Operation.*`:

Run: `mise exec -- mix test test/image_pipe/architecture_boundary_test.exs`
Expected: PASS.

- [ ] **Step 4: Final commit (only if cleanup edits were made)**

```bash
git add -A
git commit -m "chore(imgproxy): satisfy format/credo/boundary gate for pixel-effects cluster"
```

---

## Plan self-review notes

- **Spec coverage:** adjust (Task 4), colorize (Tasks 5–7), gradient (Tasks 8–10), br/co/sa realignment (Tasks 1–3). Display-frame gradient orientation is explicitly handled: gradient is directional, so it gets a dedicated `flush_if_pending` `execute_operation` clause mirroring pixelate/padding (Task 9 Step 6) plus a display-frame test (Task 9 Step 7); colorize is uniform and needs none. Fiddle (Task 11), docs incl. pbl gap (Task 12), fixtures-not-bake testing throughout.
- **Open implementation risk:** `gradient_mask/3` (Task 9 Step 3) is the one piece with unverified Vix signatures — its TDD test is the contract; iterate in `iex`. Everything else mirrors existing verbatim patterns (duotone/monochrome, `Operation.linear`, the `@special_specs`/`parse_special_option` grammar, the `executable_operations/3` dispatch).
- **Compatibility review (required before merge):** run the parallel reviewer cycle; ≥1 reviewer on the imgproxy-docs compatibility lens for argument parity (ranges, no-op sentinels, direction map), plus transform/libvips and parser/boundary lenses.
