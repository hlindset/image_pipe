# Imgproxy Aspect-Ratio Geometry Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Fix the imgproxy `extend_aspect_ratio` (`exar`) parser option to imgproxy's real `extend:gravity` semantics, and add the `crop_aspect_ratio` (`car`) Pro option, both translating into the existing `ImagePipe.Plan` and reusing existing transforms.

**Architecture:** imgproxy parsing stays declarative. `ImagePipe.Parser.Imgproxy.OptionGrammar` parses URL syntax into `PipelineRequest` fields, `ImagePipe.Parser.Imgproxy.PlanBuilder` emits canonical `ImagePipe.Plan.Operation.*` structs, and `ImagePipe.Transform.PlanExecutor` lowers them to executable transforms after cache lookup. `exar` reuses the existing `ExtendCanvas` `{:aspect_ratio, …}` rule (fix is parser + plan-builder only). `car` threads an aspect-ratio correction into `CropGuided` → the `Crop` transform, where relative/full-axis crop dims resolve to pixels.

**Tech Stack:** Elixir, ExUnit, Vix/libvips via the `Image` package, Svelte, TypeScript, Vitest, the demo test runner.

**Source of truth:** `docs/superpowers/specs/2026-05-28-imgproxy-aspect-ratio-geometry-design.md`. imgproxy reference: the upstream processing-options docs at <https://docs.imgproxy.net/usage/processing> (the `extend_aspect_ratio` and `crop_aspect_ratio` sections).

**Conventions:**
- Run everything through `mise exec -- …`.
- `git commit` after each task; do not amend.
- Tests live under `test/`; demo tests under `demo/src/*.test.ts` run via `mise exec -- pnpm demo:test` (the project uses pnpm with root-level `demo:*` scripts — there is no `demo/package.json`). Demo typecheck is `mise exec -- pnpm demo:check`.

---

## File Structure

**Feature 1 — `exar` (parser + plan builder only):**
- Modify `lib/image_pipe/parser/imgproxy/option_grammar.ex` — parse `exar` as boolean + gravity; parameterize the extend-gravity helper.
- Modify `lib/image_pipe/parser/imgproxy/pipeline_request.ex` — replace `extend_aspect_ratio` ratio field with boolean + gravity/offset fields.
- Modify `lib/image_pipe/parser/imgproxy/plan_builder.ex` — derive the canvas ratio from the resize target; update the padding predicate.

**Feature 2 — `car`:**
- Modify `lib/image_pipe/parser/imgproxy/option_grammar.ex` — parse `car`.
- Modify `lib/image_pipe/parser/imgproxy/pipeline_request.ex` — add `crop_aspect_ratio` fields.
- Modify `lib/image_pipe/plan/operation/crop_guided.ex` — add `aspect_ratio`/`enlarge` fields.
- Modify `lib/image_pipe/plan/operation.ex` — constructor keys + validation.
- Modify `lib/image_pipe/plan/key_data.ex` — include new CropGuided fields.
- Modify `lib/image_pipe/transform/plan_executor.ex` — pass fields through.
- Modify `lib/image_pipe/transform/operation/crop.ex` — apply the correction.
- Modify `lib/image_pipe/parser/imgproxy/plan_builder.ex` — populate fields.

**Demo (both features):** `demo/src/processing-path.ts`, `demo/src/demo-url-state.ts`, `demo/src/App.svelte`, `demo/src/processing-path.test.ts`.

**Docs:** `docs/imgproxy_support_matrix.md`, `docs/imgproxy_path_api.md`, `docs/transform_operations.md`.

---

## Task 1: Fix `exar` parser shape, request fields, and plan-builder ratio

This task spans the parser struct rename and the plan builder together because the field rename breaks compilation otherwise. Intermediate steps will not compile until all edits land; that's expected.

**Files:**
- Modify: `lib/image_pipe/parser/imgproxy/option_grammar.ex` (`parse_extend_aspect_ratio/2` ~673-681, `parse_optional_extend_gravity/2` ~299-332)
- Modify: `lib/image_pipe/parser/imgproxy/pipeline_request.ex:29,60`
- Modify: `lib/image_pipe/parser/imgproxy/plan_builder.ex` (`extend_aspect_ratio_operation/1` ~391-399, `effective_padding_pixel_ratio/1` ~552-561)
- Test: `test/parser/imgproxy/options_test.exs`, `test/parser/imgproxy/option_grammar_test.exs`, `test/parser/imgproxy/plan_builder_test.exs`

- [ ] **Step 1: Rewrite the existing `exar` parser tests to the new shape**

In `test/parser/imgproxy/options_test.exs`, find the two assertions around lines 11 and 29 that assert `exar:16:9` parses to `pipeline.extend_aspect_ratio == {16, 9}`. Replace them with the boolean+gravity shape. Example (adapt to the surrounding test names/helpers in that file):

```elixir
test "exar enables aspect-ratio canvas extension with default gravity" do
  assert {:ok, %PipelineRequest{} = pipeline} = parse_pipeline("exar:1")
  assert pipeline.extend_aspect_ratio == true
  assert pipeline.extend_aspect_ratio_requested == true
  assert pipeline.extend_aspect_ratio_gravity == nil
end

test "exar:0 disables aspect-ratio canvas extension" do
  assert {:ok, %PipelineRequest{} = pipeline} = parse_pipeline("exar:0")
  assert pipeline.extend_aspect_ratio == false
  assert pipeline.extend_aspect_ratio_requested == true
end

test "exar accepts a gravity argument" do
  assert {:ok, %PipelineRequest{} = pipeline} = parse_pipeline("exar:1:no")
  assert pipeline.extend_aspect_ratio == true
  assert pipeline.extend_aspect_ratio_gravity == {:anchor, :center, :top}
end

test "exar rejects smart/object gravity" do
  assert {:error, _} = parse_pipeline("exar:1:sm")
end
```

In `test/parser/imgproxy/option_grammar_test.exs` lines ~232-234, the arity-rejection list contains `extend_aspect_ratio:16:9:1` / `exar:16:9:1`. Update those entries to a now-invalid arity for the new shape, e.g. `exar:1:no:0:0:9` (too many parts) or remove the `exar` entries from that list if they no longer represent invalid arity.

- [ ] **Step 2: Run the tests to confirm they fail**

Run: `mise exec -- mix test test/parser/imgproxy/options_test.exs`
Expected: FAIL (the new field names don't exist yet; compile or assertion errors).

- [ ] **Step 3: Replace the `extend_aspect_ratio` field on `PipelineRequest`**

In `lib/image_pipe/parser/imgproxy/pipeline_request.ex`, in the `@type t()` block replace line 29:

```elixir
          extend_aspect_ratio: ImagePipe.imgp_ratio() | nil,
```

with:

```elixir
          extend_aspect_ratio: boolean(),
          extend_aspect_ratio_requested: boolean(),
          extend_aspect_ratio_gravity: gravity_anchor() | nil,
          extend_aspect_ratio_x_offset: float() | nil,
          extend_aspect_ratio_y_offset: float() | nil,
```

and in the `defstruct` block replace line 60 `extend_aspect_ratio: nil,` with:

```elixir
            extend_aspect_ratio: false,
            extend_aspect_ratio_requested: false,
            extend_aspect_ratio_gravity: nil,
            extend_aspect_ratio_x_offset: nil,
            extend_aspect_ratio_y_offset: nil,
```

- [ ] **Step 4: Parameterize the extend-gravity helper by key prefix**

In `lib/image_pipe/parser/imgproxy/option_grammar.ex`, change `parse_optional_extend_gravity/2` (lines ~299-332) to accept a key prefix. Replace the whole helper with:

```elixir
  defp parse_optional_extend_gravity(segment, parts),
    do: parse_optional_extend_gravity(:extend, segment, parts)

  defp parse_optional_extend_gravity(_prefix, _segment, []), do: {:ok, []}
  defp parse_optional_extend_gravity(_prefix, _segment, [""]), do: {:ok, []}
  defp parse_optional_extend_gravity(_prefix, _segment, ["", ""]), do: {:ok, []}
  defp parse_optional_extend_gravity(_prefix, _segment, ["", "", ""]), do: {:ok, []}

  defp parse_optional_extend_gravity(prefix, _segment, [gravity]) do
    case parse_gravity_anchor(gravity) do
      {:ok, anchor} -> {:ok, [{gravity_key(prefix, :gravity), anchor}]}
      {:error, _reason} = error -> error
    end
  end

  defp parse_optional_extend_gravity(prefix, _segment, [gravity, "", ""]) do
    case parse_gravity_anchor(gravity) do
      {:ok, anchor} -> {:ok, [{gravity_key(prefix, :gravity), anchor}]}
      {:error, _reason} = error -> error
    end
  end

  defp parse_optional_extend_gravity(prefix, _segment, [gravity, x_offset, y_offset]) do
    with {:ok, anchor} <- parse_gravity_anchor(gravity),
         {:ok, x_offset} <- parse_float(x_offset),
         {:ok, y_offset} <- parse_float(y_offset) do
      {:ok,
       [
         {gravity_key(prefix, :gravity), anchor},
         {gravity_key(prefix, :x_offset), x_offset},
         {gravity_key(prefix, :y_offset), y_offset}
       ]}
    end
  end

  defp parse_optional_extend_gravity(_prefix, segment, _parts),
    do: {:error, {:invalid_option_segment, segment}}

  defp gravity_key(:extend, :gravity), do: :extend_gravity
  defp gravity_key(:extend, :x_offset), do: :extend_x_offset
  defp gravity_key(:extend, :y_offset), do: :extend_y_offset
  defp gravity_key(:extend_aspect_ratio, :gravity), do: :extend_aspect_ratio_gravity
  defp gravity_key(:extend_aspect_ratio, :x_offset), do: :extend_aspect_ratio_x_offset
  defp gravity_key(:extend_aspect_ratio, :y_offset), do: :extend_aspect_ratio_y_offset
```

The existing `parse_extend/2` calls `parse_optional_extend_gravity(segment, gravity_parts)` (2-arity), which now delegates to the `:extend` prefix — no change needed there.

- [ ] **Step 5: Rewrite `parse_extend_aspect_ratio/2` to the boolean+gravity shape**

In the same file replace `parse_extend_aspect_ratio/2` (lines ~673-681) with:

```elixir
  defp parse_extend_aspect_ratio([value], _segment) when value != "" do
    with {:ok, extend?} <- parse_boolean(value) do
      {:ok, [extend_aspect_ratio: extend?, extend_aspect_ratio_requested: true]}
    end
  end

  defp parse_extend_aspect_ratio([value | gravity_parts], segment) when value != "" do
    with {:ok, extend?} <- parse_boolean(value),
         {:ok, gravity_assignments} <-
           parse_optional_extend_gravity(:extend_aspect_ratio, segment, gravity_parts) do
      {:ok,
       Keyword.merge(
         [extend_aspect_ratio: extend?, extend_aspect_ratio_requested: true],
         gravity_assignments
       )}
    end
  end

  defp parse_extend_aspect_ratio(_args, segment),
    do: {:error, {:invalid_option_segment, segment}}
```

- [ ] **Step 6: Update the plan builder to derive the ratio from the resize target**

In `lib/image_pipe/parser/imgproxy/plan_builder.ex` replace `extend_aspect_ratio_operation/1` (lines ~391-399) with:

```elixir
  defp extend_aspect_ratio_operation(%PipelineRequest{} = request) do
    if extend_aspect_ratio_requested?(request) do
      case resize_target_ratio(request) do
        {:ok, {ratio_w, ratio_h}} ->
          placement_gravity = request.extend_aspect_ratio_gravity || @default_gravity

          with {:ok, placement} <- canvas_placement(placement_gravity) do
            Operation.canvas(
              {:ratio, ratio_w, 1},
              {:ratio, ratio_h, 1},
              placement,
              fill: :transparent,
              overflow: :reject,
              x_offset: request.extend_aspect_ratio_x_offset || 0.0,
              y_offset: request.extend_aspect_ratio_y_offset || 0.0
            )
          end

        :no_ratio ->
          nil
      end
    end
  end

  defp extend_aspect_ratio_requested?(%PipelineRequest{extend_aspect_ratio: extend?}), do: extend?

  defp resize_target_ratio(%PipelineRequest{width: {:pixels, w}, height: {:pixels, h}})
       when is_integer(w) and is_integer(h) and w > 0 and h > 0,
       do: {:ok, {w, h}}

  defp resize_target_ratio(%PipelineRequest{}), do: :no_ratio
```

Then update `effective_padding_pixel_ratio/1` (lines ~552-561): replace the condition `not is_nil(request.extend_aspect_ratio)` with `request.extend_aspect_ratio` (now a boolean), so the line reads:

```elixir
      if extend_operation_requested?(request) or request.extend_aspect_ratio do
```

- [ ] **Step 7: Add a plan-builder test for the derived ratio and no-op**

In `test/parser/imgproxy/plan_builder_test.exs`, replace the line ~233 usage `plan_pipeline(extend_aspect_ratio: {16, 9})` and add coverage. Use the file's existing `plan_pipeline/1` helper (it builds a `PipelineRequest` and runs the plan builder). Example:

```elixir
test "exar emits a canvas ratio derived from the resize target" do
  pipeline =
    plan_pipeline(
      width: {:pixels, 1600},
      height: {:pixels, 900},
      extend_aspect_ratio: true,
      extend_aspect_ratio_requested: true
    )

  assert Enum.any?(pipeline.operations, fn
           %ImagePipe.Plan.Operation.Canvas{width: {:ratio, 1600, 1}, height: {:ratio, 900, 1}} ->
             true

           _ ->
             false
         end)
end

test "exar is a no-op when a resize dimension is auto" do
  pipeline =
    plan_pipeline(
      width: {:pixels, 1600},
      height: :auto,
      extend_aspect_ratio: true,
      extend_aspect_ratio_requested: true
    )

  refute Enum.any?(pipeline.operations, &match?(%ImagePipe.Plan.Operation.Canvas{}, &1))
end
```

If `plan_pipeline/1` does not accept arbitrary `PipelineRequest` fields, adapt to however that helper constructs the request (check the top of the test file). Match the canonical operation list field name the helper returns (`operations` or the pipeline's operation list).

- [ ] **Step 8: Run the focused suites green**

Run: `mise exec -- mix test test/parser/imgproxy/options_test.exs test/parser/imgproxy/option_grammar_test.exs test/parser/imgproxy/plan_builder_test.exs`
Expected: PASS.

- [ ] **Step 9: Compile with warnings as errors**

Run: `mise exec -- mix compile --warnings-as-errors`
Expected: clean compile (no references to the removed `imgp_ratio` shape of `extend_aspect_ratio`).

- [ ] **Step 10: Commit**

```bash
git add lib/image_pipe/parser/imgproxy/option_grammar.ex lib/image_pipe/parser/imgproxy/pipeline_request.ex lib/image_pipe/parser/imgproxy/plan_builder.ex test/parser/imgproxy/options_test.exs test/parser/imgproxy/option_grammar_test.exs test/parser/imgproxy/plan_builder_test.exs
git commit -m "Fix imgproxy extend_aspect_ratio to extend:gravity semantics"
```

---

## Task 2: `exar` wire-level conformance

**Files:**
- Test: `test/image_pipe/imgproxy_wire_conformance_test.exs`

- [ ] **Step 1: Add a failing wire test that decodes output dimensions**

Open `test/image_pipe/imgproxy_wire_conformance_test.exs` and study an existing test for the request/decoding helpers (how it issues `ImagePipe.call/2`, decodes the body with `Image`, and reads dimensions). Add, mirroring those helpers:

```elixir
test "exar:1 under fit extends the canvas to the resize aspect ratio" do
  # A landscape source resized fit into a square box leaves letterbox room;
  # exar:1 extends the canvas to the 1:1 requested ratio.
  conn = request("/_/rs:fit:300:300/exar:1/plain/#{source_url("landscape")}")

  assert conn.status == 200
  {width, height} = decoded_dimensions(conn)
  assert width == height
end

test "exar:1 under force is a no-op" do
  base = request("/_/rs:force:300:200/plain/#{source_url("landscape")}")
  with_exar = request("/_/rs:force:300:200/exar:1/plain/#{source_url("landscape")}")

  assert decoded_dimensions(base) == decoded_dimensions(with_exar)
end
```

Replace `request/1`, `source_url/1`, `decoded_dimensions/1`, and the fixture name (`"landscape"`) with the actual helpers and fixtures used in this file. If there is no landscape fixture, use an existing fixture whose orientation makes the `fit` box leave extension room and assert the resulting ratio rather than exact equality.

- [ ] **Step 2: Run it to confirm it fails (or passes if already correct)**

Run: `mise exec -- mix test test/image_pipe/imgproxy_wire_conformance_test.exs`
Expected: the new tests run; if `exar` was previously broken the test exercises the now-fixed path and should PASS after Task 1. If it FAILS, the dimension assertion needs adjusting to the chosen fixture's geometry — fix the expected values, not the implementation.

- [ ] **Step 3: Commit**

```bash
git add test/image_pipe/imgproxy_wire_conformance_test.exs
git commit -m "Add wire-level exar aspect-ratio conformance tests"
```

---

## Task 3: `exar` demo UI and demo tests

**Files:**
- Modify: `demo/src/processing-path.ts` (DemoState ~38-40, defaults ~225-227, emit ~328-330)
- Modify: `demo/src/demo-url-state.ts` (`parseAspectCanvas` ~557-575)
- Modify: `demo/src/App.svelte` (aspect-canvas summary ~127-128 and its control block)
- Modify: `demo/src/processing-path.test.ts` (~263-286, ~744-770)

- [ ] **Step 1: Update the demo state shape for the new exar form**

In `demo/src/processing-path.ts`, replace the DemoState fields (lines ~38-40):

```typescript
  aspectCanvasEnabled: boolean;
  extendAspectWidth: number;
  extendAspectHeight: number;
```

with:

```typescript
  aspectCanvasEnabled: boolean;
  aspectCanvasGravity: Gravity | "ce";
```

(`Gravity` is already imported in this file; `"ce"` is the default center.) Update the defaults (lines ~225-227) from:

```typescript
  aspectCanvasEnabled: false,
  extendAspectWidth: 16,
  extendAspectHeight: 9,
```

to:

```typescript
  aspectCanvasEnabled: false,
  aspectCanvasGravity: "ce",
```

Update the emit block (lines ~328-330) from:

```typescript
  if (currentState.aspectCanvasEnabled) {
    segments.push(`exar:${currentState.extendAspectWidth}:${currentState.extendAspectHeight}`);
  }
```

to:

```typescript
  if (currentState.aspectCanvasEnabled) {
    segments.push(
      currentState.aspectCanvasGravity === "ce"
        ? "exar:1"
        : `exar:1:${currentState.aspectCanvasGravity}`,
    );
  }
```

- [ ] **Step 2: Update the demo parser for the new exar form**

In `demo/src/demo-url-state.ts` replace `parseAspectCanvas` (lines ~557-575) with:

```typescript
function parseAspectCanvas(currentState: DemoState, args: string[]): DemoState | null {
  if (args.length < 1 || args.length > 2) {
    return null;
  }

  const enabled = args[0] === "1" || args[0] === "t" || args[0] === "true";
  const disabled = args[0] === "0" || args[0] === "f" || args[0] === "false";

  if (!enabled && !disabled) {
    return null;
  }

  const gravityArg = args[1];

  if (gravityArg !== undefined && !isGravity(gravityArg)) {
    return null;
  }

  return {
    ...currentState,
    aspectCanvasEnabled: enabled,
    aspectCanvasGravity: gravityArg !== undefined ? (gravityArg as Gravity) : "ce",
  };
}
```

- [ ] **Step 3: Update the Svelte control**

In `demo/src/App.svelte`, change the summary (lines ~127-128) from:

```svelte
  $: aspectCanvasSummary = state.aspectCanvasEnabled
    ? `exar:${state.extendAspectWidth}:${state.extendAspectHeight}`
```

to:

```svelte
  $: aspectCanvasSummary = state.aspectCanvasEnabled
    ? state.aspectCanvasGravity === "ce"
      ? "exar:1"
      : `exar:1:${state.aspectCanvasGravity}`
```

Then locate the aspect-canvas control block (the inputs bound to `state.extendAspectWidth`/`state.extendAspectHeight`). Replace the two numeric ratio inputs with a single gravity `<select>` bound to `state.aspectCanvasGravity`. The crop section already renders a gravity `<select>` (the `cropGravity` control) — copy that markup and its option list (`ce`, `no`, `so`, `ea`, `we`, `noea`, `nowe`, `soea`, `sowe`); the enable toggle uses the existing `ToolToggleHeader.svelte` component (see how the crop/aspect sections already use it). Keep the enable toggle bound to `state.aspectCanvasEnabled`. Remove every reference to `extendAspectWidth`/`extendAspectHeight` (the `demo:check` typecheck — `tsgo` + `svelte-check` — will fail on any leftover reference, since those fields no longer exist on `DemoState`).

- [ ] **Step 4: Update the demo tests to the new shape**

In `demo/src/processing-path.test.ts`:

- Lines ~263-286: replace the state `{ aspectCanvasEnabled: true, extendAspectWidth: 16, extendAspectHeight: 9 }` with `{ aspectCanvasEnabled: true, aspectCanvasGravity: "ce" }`, and update expectations from `["exar:16:9"]` to `["exar:1"]` and the path accordingly (`/_/exar:1/...`, `["exar:1", "pd:8:16:24:32"]`, `/_/exar:1/pd:8:16:24:32/...`).
- Lines ~744-770: in the combined round-trip, replace the `exar:16:9` segment in the path string with `exar:1`, and replace the state assertion `extendAspectWidth: 16, extendAspectHeight: 9` with `aspectCanvasGravity: "ce"`.

Add a gravity round-trip test:

```typescript
it("round-trips exar with gravity", () => {
  const state = { ...defaultDemoState, aspectCanvasEnabled: true, aspectCanvasGravity: "no" as const };
  expect(optionSegments(state)).toEqual(["exar:1:no"]);
});
```

- [ ] **Step 5: Run demo type-check and tests**

Run: `mise exec -- pnpm demo:test`
Expected: PASS. Then run the typecheck: `mise exec -- pnpm demo:check`.
Expected: no type errors (all `extendAspectWidth`/`extendAspectHeight` references removed).

- [ ] **Step 6: Commit**

```bash
git add demo/src/processing-path.ts demo/src/demo-url-state.ts demo/src/App.svelte demo/src/processing-path.test.ts
git commit -m "Update demo for imgproxy exar extend:gravity shape"
```

---

## Task 4: `car` parser and request fields

**Files:**
- Modify: `lib/image_pipe/parser/imgproxy/option_grammar.ex` (`parse_special_option/3` dispatch ~369; add `parse_crop_aspect_ratio/2`)
- Modify: `lib/image_pipe/parser/imgproxy/pipeline_request.ex` (add fields)
- Test: `test/parser/imgproxy/options_test.exs`, `test/parser/imgproxy/option_grammar_test.exs`

- [ ] **Step 1: Write failing parser tests for `car`**

In `test/parser/imgproxy/options_test.exs` add:

```elixir
test "car parses aspect ratio with default reduce" do
  assert {:ok, %PipelineRequest{} = pipeline} = parse_pipeline("car:1.5")
  assert pipeline.crop_aspect_ratio == 1.5
  assert pipeline.crop_aspect_ratio_enlarge == false
end

test "car parses aspect ratio with enlarge flag" do
  assert {:ok, %PipelineRequest{} = pipeline} = parse_pipeline("car:1:1")
  assert pipeline.crop_aspect_ratio == 1.0
  assert pipeline.crop_aspect_ratio_enlarge == true
end

test "car:0 is a no-op ratio" do
  assert {:ok, %PipelineRequest{} = pipeline} = parse_pipeline("car:0")
  assert pipeline.crop_aspect_ratio == 0.0
end

test "car rejects a negative ratio" do
  assert {:error, _} = parse_pipeline("car:-1")
end
```

Use whatever `parse_pipeline/1` helper the file already defines.

- [ ] **Step 2: Run to confirm failure**

Run: `mise exec -- mix test test/parser/imgproxy/options_test.exs`
Expected: FAIL — `car` currently returns an unknown-option error and the new fields don't exist.

- [ ] **Step 3: Add the request fields**

In `lib/image_pipe/parser/imgproxy/pipeline_request.ex`, add to `@type t()` (near the crop field, line ~40):

```elixir
          crop_aspect_ratio: float() | nil,
          crop_aspect_ratio_enlarge: boolean(),
```

and to `defstruct` (near `crop: nil`, line ~71):

```elixir
            crop_aspect_ratio: nil,
            crop_aspect_ratio_enlarge: false,
```

- [ ] **Step 4: Add the parser dispatch and function**

In `lib/image_pipe/parser/imgproxy/option_grammar.ex`, add a dispatch clause in `parse_special_option/3` next to the crop clause (after line ~371):

```elixir
  defp parse_special_option(name, args, segment)
       when name in ["crop_aspect_ratio", "crop_ar", "car"] do
    parse_crop_aspect_ratio(args, segment)
  end
```

Add the parsing function near `parse_crop` (after line ~688):

```elixir
  defp parse_crop_aspect_ratio([ratio], segment) when ratio != "" do
    parse_crop_aspect_ratio([ratio, "0"], segment)
  end

  defp parse_crop_aspect_ratio([ratio, enlarge], _segment)
       when ratio != "" and enlarge != "" do
    with {:ok, ratio} <- parse_non_negative_float(ratio),
         {:ok, enlarge?} <- parse_boolean(enlarge) do
      {:ok, [crop_aspect_ratio: ratio, crop_aspect_ratio_enlarge: enlarge?]}
    end
  end

  defp parse_crop_aspect_ratio(_args, segment),
    do: {:error, {:invalid_option_segment, segment}}
```

- [ ] **Step 5: Remove `car` from the unknown-option rejection test**

In `test/parser/imgproxy/option_grammar_test.exs` lines ~203-211, the "dropped options return unknown option errors" test lists `crop_aspect_ratio`, `crop_ar`, `car`, and `crop_ar:1:1` as expected `{:error, {:unknown_option, _}}`. Remove those four entries — they are now implemented options.

- [ ] **Step 6: Run the parser suites green**

Run: `mise exec -- mix test test/parser/imgproxy/options_test.exs test/parser/imgproxy/option_grammar_test.exs`
Expected: PASS.

- [ ] **Step 7: Commit**

```bash
git add lib/image_pipe/parser/imgproxy/option_grammar.ex lib/image_pipe/parser/imgproxy/pipeline_request.ex test/parser/imgproxy/options_test.exs test/parser/imgproxy/option_grammar_test.exs
git commit -m "Parse imgproxy crop_aspect_ratio (car) option"
```

---

## Task 5: `car` plan operation, constructor, key data, executor, plan builder

**Files:**
- Modify: `lib/image_pipe/plan/operation/crop_guided.ex`
- Modify: `lib/image_pipe/plan/operation.ex` (`@crop_guided_keys:53`, `crop_guided/4` ~169-191, `valid_crop_guided?/1` ~375-385)
- Modify: `lib/image_pipe/plan/key_data.ex` (`data(%CropGuided{})` ~67-76)
- Modify: `lib/image_pipe/transform/plan_executor.ex` (`executable_operations(%CropGuided{}…)` ~127-138)
- Modify: `lib/image_pipe/parser/imgproxy/plan_builder.ex` (`crop_operations/1` ~236-250)
- Test: `test/image_pipe/plan/operation_test.exs`, `test/image_pipe/plan/operation_key_data_test.exs`, `test/parser/imgproxy/plan_builder_test.exs`

- [ ] **Step 1: Write failing constructor and key-data tests**

In `test/image_pipe/plan/operation_test.exs` add (adapt module aliases to the file's existing style):

```elixir
test "crop_guided carries aspect_ratio and enlarge" do
  assert {:ok, %Operation.CropGuided{aspect_ratio: {:ratio, 3, 2}, enlarge: true}} =
           Operation.crop_guided({:px, 300}, {:px, 200}, :center,
             aspect_ratio: {:ratio, 3, 2},
             enlarge: true
           )
end

test "crop_guided defaults aspect_ratio to nil and enlarge to false" do
  assert {:ok, %Operation.CropGuided{aspect_ratio: nil, enlarge: false}} =
           Operation.crop_guided({:px, 300}, {:px, 200}, :center)
end
```

In `test/image_pipe/plan/operation_key_data_test.exs` add:

```elixir
test "crop_guided key data includes aspect_ratio and enlarge" do
  {:ok, op} =
    Operation.crop_guided({:px, 300}, {:px, 200}, :center,
      aspect_ratio: {:ratio, 1, 1},
      enlarge: true
    )

  data = KeyData.data(op)
  assert data[:aspect_ratio] == [unit: :ratio, numerator: 1, denominator: 1]
  assert data[:enlarge] == true
end
```

- [ ] **Step 2: Run to confirm failure**

Run: `mise exec -- mix test test/image_pipe/plan/operation_test.exs test/image_pipe/plan/operation_key_data_test.exs`
Expected: FAIL — fields and options not supported yet.

- [ ] **Step 3: Add fields to the CropGuided struct**

In `lib/image_pipe/plan/operation/crop_guided.ex`, change the defstruct line 7 from:

```elixir
  defstruct @enforce_keys ++ [x_offset: {:pixels, 0.0}, y_offset: {:pixels, 0.0}]
```

to:

```elixir
  defstruct @enforce_keys ++
              [x_offset: {:pixels, 0.0}, y_offset: {:pixels, 0.0}, aspect_ratio: nil, enlarge: false]
```

and add to the `@type t()` map (after `y_offset:` line ~32):

```elixir
          aspect_ratio: nil | {:ratio, pos_integer(), pos_integer()},
          enlarge: boolean(),
```

- [ ] **Step 4: Extend the constructor, allow-list, and validation**

In `lib/image_pipe/plan/operation.ex`:

Change `@crop_guided_keys` (line 53) from:

```elixir
  @crop_guided_keys [:x_offset, :y_offset]
```

to:

```elixir
  @crop_guided_keys [:x_offset, :y_offset, :aspect_ratio, :enlarge]
```

In `crop_guided/4` (lines ~169-191), add the two fields into the constructed struct. After the `y_offset` binding, build the struct as:

```elixir
      {:ok,
       %CropGuided{
         width: width,
         height: height,
         guide: guide,
         x_offset: x_offset,
         y_offset: y_offset,
         aspect_ratio: Keyword.get(opts, :aspect_ratio),
         enlarge: Keyword.get(opts, :enlarge, false)
       }}
```

In `valid_crop_guided?/1` (lines ~375-385), add validation for the new fields. Replace it with:

```elixir
  defp valid_crop_guided?(%CropGuided{} = operation) do
    with {:ok, _width} <- tagged_crop_dimension(operation.width),
         {:ok, _height} <- tagged_crop_dimension(operation.height),
         {:ok, _guide} <- tagged_crop_guide(operation.guide),
         :ok <- tagged_offset(operation.x_offset),
         :ok <- tagged_offset(operation.y_offset),
         true <- valid_crop_aspect_ratio?(operation.aspect_ratio),
         true <- is_boolean(operation.enlarge) do
      true
    else
      _error -> false
    end
  end

  defp valid_crop_aspect_ratio?(nil), do: true

  defp valid_crop_aspect_ratio?({:ratio, numerator, denominator})
       when is_integer(numerator) and is_integer(denominator) and numerator > 0 and denominator > 0,
       do: true

  defp valid_crop_aspect_ratio?(_other), do: false
```

- [ ] **Step 5: Add key data for the new fields**

In `lib/image_pipe/plan/key_data.ex`, replace `data(%CropGuided{})` (lines ~67-76) with:

```elixir
  def data(%CropGuided{} = operation) do
    [
      op: :crop_guided,
      width: data(operation.width),
      height: data(operation.height),
      guide: guide_data(operation.guide),
      x_offset: operation.x_offset,
      y_offset: operation.y_offset,
      aspect_ratio: crop_aspect_ratio_data(operation.aspect_ratio),
      enlarge: operation.enlarge
    ]
  end
```

Add a private helper near the other `*_data` helpers in this module:

```elixir
  defp crop_aspect_ratio_data(nil), do: nil
  defp crop_aspect_ratio_data({:ratio, numerator, denominator}), do: data({:ratio, numerator, denominator})
```

(`data({:ratio, n, d})` already returns `[unit: :ratio, numerator: n, denominator: d]` per the `ratio_data` type — verify against the existing ratio clause in this file; if the ratio clause lives elsewhere, call it the same way the Canvas path does.)

- [ ] **Step 6: Add the Crop transform struct fields, then pass them through PlanExecutor**

The executable `%Crop{}` must gain the fields here (in the same task/commit) so this task compiles on its own — Elixir resolves struct keys at compile time and will raise on unknown keys otherwise.

First, in `lib/image_pipe/transform/operation/crop.ex` add the two fields to the defstruct (lines ~99-107):

```elixir
  defstruct [
    :width,
    :height,
    :crop_from,
    gravity: nil,
    x_offset: 0.0,
    y_offset: 0.0,
    offset_scale: 1.0,
    aspect_ratio: nil,
    enlarge: false
  ]
```

and to the `@type t()` map (after `offset_scale:` ~line 124):

```elixir
          aspect_ratio: nil | {:ratio, pos_integer(), pos_integer()},
          enlarge: boolean(),
```

(Task 6 adds the correction *logic* that consumes these fields; here they are inert defaults, so existing crop behavior is unchanged.)

Then in `lib/image_pipe/transform/plan_executor.ex`, in `executable_operations(%CropGuided{}…)` (lines ~127-138) add the two fields to the `%Crop{}` it builds:

```elixir
  defp executable_operations(%CropGuided{} = operation, %State{}, _context) do
    [
      %Crop{
        width: crop_dimension(operation.width),
        height: crop_dimension(operation.height),
        crop_from: :gravity,
        gravity: tagged_executable_gravity(operation.guide),
        x_offset: operation.x_offset,
        y_offset: operation.y_offset,
        aspect_ratio: operation.aspect_ratio,
        enlarge: operation.enlarge
      }
    ]
  end
```

- [ ] **Step 7: Populate the fields in the plan builder**

In `lib/image_pipe/parser/imgproxy/plan_builder.ex`, `crop_operations/1` (lines ~236-250) currently calls `Operation.crop_guided(width, height, guide, x_offset: crop.x_offset, y_offset: crop.y_offset)`. Add the aspect-ratio opts derived from the request. Replace the `Operation.crop_guided(...)` call with:

```elixir
           Operation.crop_guided(
             width,
             height,
             guide,
             x_offset: crop.x_offset,
             y_offset: crop.y_offset,
             aspect_ratio: crop_aspect_ratio(request),
             enlarge: request.crop_aspect_ratio_enlarge
           )
```

Add a private helper near the other crop helpers:

```elixir
  defp crop_aspect_ratio(%PipelineRequest{crop_aspect_ratio: nil}), do: nil
  defp crop_aspect_ratio(%PipelineRequest{crop_aspect_ratio: ratio}) when ratio == 0.0, do: nil

  defp crop_aspect_ratio(%PipelineRequest{crop_aspect_ratio: ratio}) do
    {:ok, tagged} = tagged_ratio_from_decimal(ratio)
    tagged
  end
```

IMPORTANT: `tagged_ratio_from_decimal/1` (line ~623) returns `{:ok, {:ratio, numerator, denominator}}`, NOT a bare tuple — you must unwrap it as shown, otherwise `aspect_ratio:` would be set to `{:ok, {:ratio, …}}` and fail validation. For a positive `ratio` (the `0.0` and `nil` cases are handled above) this always returns `{:ok, _}`, so the strict match is safe.

- [ ] **Step 8: Add a plan-builder test for car population**

In `test/parser/imgproxy/plan_builder_test.exs` add:

```elixir
test "car populates CropGuided aspect_ratio and enlarge" do
  pipeline =
    plan_pipeline(
      crop: %ImagePipe.Parser.Imgproxy.CropRequest{width: {:pixels, 100}, height: {:pixels, 200}},
      crop_aspect_ratio: 1.0,
      crop_aspect_ratio_enlarge: true
    )

  assert Enum.any?(pipeline.operations, fn
           %ImagePipe.Plan.Operation.CropGuided{aspect_ratio: {:ratio, 1, 1}, enlarge: true} -> true
           _ -> false
         end)
end

test "car:0 yields no aspect-ratio correction" do
  pipeline =
    plan_pipeline(
      crop: %ImagePipe.Parser.Imgproxy.CropRequest{width: {:pixels, 100}, height: {:pixels, 200}},
      crop_aspect_ratio: 0.0
    )

  assert Enum.any?(pipeline.operations, fn
           %ImagePipe.Plan.Operation.CropGuided{aspect_ratio: nil} -> true
           _ -> false
         end)
end
```

Adapt the `CropRequest` shape and `plan_pipeline/1` usage to the helper conventions already in the file.

- [ ] **Step 9: Run suites green and compile**

Run: `mise exec -- mix test test/image_pipe/plan/operation_test.exs test/image_pipe/plan/operation_key_data_test.exs test/parser/imgproxy/plan_builder_test.exs`
Expected: PASS.
Run: `mise exec -- mix compile --warnings-as-errors`
Expected: clean (the `Crop` struct fields added in Step 6 make the executor passthrough compile).

- [ ] **Step 10: Commit**

```bash
git add lib/image_pipe/plan/operation/crop_guided.ex lib/image_pipe/plan/operation.ex lib/image_pipe/plan/key_data.ex lib/image_pipe/transform/plan_executor.ex lib/image_pipe/transform/operation/crop.ex lib/image_pipe/parser/imgproxy/plan_builder.ex test/image_pipe/plan/operation_test.exs test/image_pipe/plan/operation_key_data_test.exs test/parser/imgproxy/plan_builder_test.exs
git commit -m "Thread crop_aspect_ratio through plan and key data"
```

---

## Task 6: `car` correction logic in the Crop transform

The `Crop` struct already has `aspect_ratio`/`enlarge` fields (added in Task 5 Step 6). This task adds the correction *logic* that consumes them.

**Files:**
- Modify: `lib/image_pipe/transform/operation/crop.ex` (`crop_coordinates/4` :gravity clause ~147-173; add correction helpers)
- Test: create `test/image_pipe/transform/crop_operation_test.exs` (no crop transform test exists today)

- [ ] **Step 1: Write failing transform unit tests**

No crop transform test file exists. Create `test/image_pipe/transform/crop_operation_test.exs`, following the State/image setup pattern in `test/transform_chain_test.exs` (build images with `Image.new(width, height, color: :white)`, wrap in `%ImagePipe.Transform.State{image: image}`, and read result dimensions with `Image.width/1` / `Image.height/1`):

```elixir
defmodule ImagePipe.Transform.CropOperationTest do
  use ExUnit.Case, async: true

  alias ImagePipe.Transform.Operation.Crop
  alias ImagePipe.Transform.State

  defp state(width, height) do
    {:ok, image} = Image.new(width, height, color: :white)
    %State{image: image}
  end

  defp dimensions(%State{image: image}), do: {Image.width(image), Image.height(image)}

  test "reduce shrinks the long axis to match ratio (default)" do
    op = %Crop{
      width: {:pixels, 100},
      height: {:pixels, 200},
      crop_from: :gravity,
      gravity: {:anchor, :center, :center},
      aspect_ratio: {:ratio, 1, 1},
      enlarge: false
    }

    {:ok, result} = Crop.execute(op, state(400, 400))
    assert {100, 100} == dimensions(result)
  end

  test "enlarge grows the short axis to match ratio" do
    op = %Crop{
      width: {:pixels, 100},
      height: {:pixels, 200},
      crop_from: :gravity,
      gravity: {:anchor, :center, :center},
      aspect_ratio: {:ratio, 1, 1},
      enlarge: true
    }

    {:ok, result} = Crop.execute(op, state(400, 400))
    assert {200, 200} == dimensions(result)
  end

  test "enlarge clamps to image bounds keeping ratio" do
    op = %Crop{
      width: {:pixels, 100},
      height: {:pixels, 200},
      crop_from: :gravity,
      gravity: {:anchor, :center, :center},
      aspect_ratio: {:ratio, 1, 1},
      enlarge: true
    }

    # image only 150 tall; enlarged 200x200 must shrink to fit
    {:ok, result} = Crop.execute(op, state(400, 150))
    {w, h} = dimensions(result)
    assert w == h
    assert h <= 150
  end

  test "nil aspect_ratio leaves the crop unchanged" do
    op = %Crop{
      width: {:pixels, 100},
      height: {:pixels, 200},
      crop_from: :gravity,
      gravity: {:anchor, :center, :center},
      aspect_ratio: nil,
      enlarge: false
    }

    {:ok, result} = Crop.execute(op, state(400, 400))
    assert {100, 200} == dimensions(result)
  end
end
```

Note the crop height 200 fits inside the 400-tall images for the unclamped cases. If `Image.new/3` arity/options differ from `test/transform_chain_test.exs` usage, copy that file's exact call form.

- [ ] **Step 2: Run to confirm failure**

Run: `mise exec -- mix test test/image_pipe/transform/crop_operation_test.exs`
Expected: FAIL — the crop applies no aspect-ratio correction yet (reduce/enlarge tests get `100x200`, not the corrected sizes).

- [ ] **Step 3: Apply the correction in the gravity crop path**

In `crop_coordinates/4` for the `crop_from: :gravity` clause (lines ~147-173), insert an aspect-ratio correction between resolving the dimensions and computing coordinates. After these two lines in the `with` chain:

```elixir
         {:ok, crop_width} <- crop_dimension(crop.width, image_width),
         {:ok, crop_height} <- crop_dimension(crop.height, image_height),
```

add a plain `=` match clause (it always succeeds, so use `=`, not `<-`):

```elixir
         {crop_width, crop_height} =
           correct_aspect_ratio(
             crop_width,
             crop_height,
             params.aspect_ratio,
             params.enlarge,
             image_width,
             image_height
           ),
```

Add the correction helpers at the bottom of the module (before the final `end`):

```elixir
  defp correct_aspect_ratio(width, height, nil, _enlarge, _image_width, _image_height),
    do: {width, height}

  defp correct_aspect_ratio(width, height, {:ratio, numerator, denominator}, enlarge, image_width, image_height) do
    target = numerator / denominator
    current = width / height

    {corrected_width, corrected_height} =
      cond do
        current == target -> {width, height}
        enlarge and current > target -> {width, round_ties_to_even(width / target)}
        enlarge -> {round_ties_to_even(height * target), height}
        current > target -> {round_ties_to_even(height * target), height}
        true -> {width, round_ties_to_even(width / target)}
      end

    clamp_to_bounds(corrected_width, corrected_height, image_width, image_height)
  end

  defp clamp_to_bounds(width, height, image_width, image_height) do
    scale = min(1.0, min(image_width / width, image_height / height))

    width = max(1, min(image_width, round_ties_to_even(width * scale)))
    height = max(1, min(image_height, round_ties_to_even(height * scale)))

    {width, height}
  end
```

Note: for the reduce branches, `current > target` means the crop is wider than the target ratio, so the width shrinks to `height * target`; otherwise the height shrinks to `width / target`. For enlarge the deficient axis grows instead. `clamp_to_bounds/4` uniformly scales the (already ratio-correct) box down to fit the image while preserving the ratio, which only bites for the enlarge case.

- [ ] **Step 4: Run the transform tests green**

Run: `mise exec -- mix test test/image_pipe/transform/crop_operation_test.exs`
Expected: PASS.

- [ ] **Step 5: Run the broader transform/plan suites and compile**

Run: `mise exec -- mix test test/image_pipe/transform/ test/image_pipe/plan/`
Expected: PASS (no regressions in existing crop behavior — uncorrected crops use `aspect_ratio: nil`).
Run: `mise exec -- mix compile --warnings-as-errors`
Expected: clean.

- [ ] **Step 6: Commit**

```bash
git add lib/image_pipe/transform/operation/crop.ex test/image_pipe/transform/crop_operation_test.exs
git commit -m "Apply crop_aspect_ratio correction in the crop transform"
```

---

## Task 7: `car` wire-level conformance

**Files:**
- Test: `test/image_pipe/imgproxy_wire_conformance_test.exs`

- [ ] **Step 1: Add failing wire tests that decode dimensions**

Using the same request/decode helpers as Task 2, add:

```elixir
test "car corrects the crop area aspect ratio (enlarge)" do
  # crop 100x200 then car:1:1 enlarge -> 200x200 crop, no resize
  conn = request("/_/c:100:200:ce/car:1:1/plain/#{source_url("large")}")

  assert conn.status == 200
  assert {200, 200} == decoded_dimensions(conn)
end

test "car works without a resize (no-geometry-resize case)" do
  reduced = request("/_/c:100:200:ce/car:1/plain/#{source_url("large")}")

  assert reduced.status == 200
  assert {100, 100} == decoded_dimensions(reduced)
end

test "car leaves gravity placement unchanged" do
  # The corrected crop is still anchored by the original gravity; compare a
  # corrected gravity crop against the same crop dimensions stated directly.
  via_car = request("/_/c:200:400:no/car:1:1/plain/#{source_url("large")}")
  direct = request("/_/c:400:400:no/plain/#{source_url("large")}")

  assert decoded_dimensions(via_car) == decoded_dimensions(direct)
end
```

Replace `source_url("large")` with a fixture at least 400x400 so the enlarge case isn't clamped. Adjust expected dimensions if the chosen fixture forces clamping; keep the implementation untouched and fix the expectations to the fixture geometry.

- [ ] **Step 2: Run to confirm pass**

Run: `mise exec -- mix test test/image_pipe/imgproxy_wire_conformance_test.exs`
Expected: PASS (the parser→plan→transform path from Tasks 4-6 is complete). If a dimension assertion fails, reconcile it against the fixture size, not the code.

- [ ] **Step 3: Commit**

```bash
git add test/image_pipe/imgproxy_wire_conformance_test.exs
git commit -m "Add wire-level crop_aspect_ratio conformance tests"
```

---

## Task 8: `car` demo UI and demo tests

**Files:**
- Modify: `demo/src/processing-path.ts` (DemoState, defaults, `optionSegments` emit, near the crop segment ~300-304)
- Modify: `demo/src/demo-url-state.ts` (dispatch ~159-161; add `parseCropAspectRatio`)
- Modify: `demo/src/App.svelte` (crop control section)
- Modify: `demo/src/processing-path.test.ts`

- [ ] **Step 1: Add demo state fields and emit**

In `demo/src/processing-path.ts`, add to DemoState (near the crop fields):

```typescript
  cropAspectRatioEnabled: boolean;
  cropAspectRatio: number;
  cropAspectRatioEnlarge: boolean;
```

Add to `defaultDemoState` defaults:

```typescript
  cropAspectRatioEnabled: false,
  cropAspectRatio: 1,
  cropAspectRatioEnlarge: false,
```

In `optionSegments`, after the crop segment is pushed (after lines ~300-304), add:

```typescript
  if (currentState.cropAspectRatioEnabled) {
    segments.push(
      currentState.cropAspectRatioEnlarge
        ? `car:${currentState.cropAspectRatio}:1`
        : `car:${currentState.cropAspectRatio}`,
    );
  }
```

- [ ] **Step 2: Add the demo parser**

In `demo/src/demo-url-state.ts`, add dispatch cases next to the crop cases (~159-161):

```typescript
    case "car":
    case "crop_ar":
    case "crop_aspect_ratio":
      return parseCropAspectRatio(currentState, args);
```

Add the function near `parseCrop`:

```typescript
function parseCropAspectRatio(currentState: DemoState, args: string[]): DemoState | null {
  if (args.length < 1 || args.length > 2) {
    return null;
  }

  const ratio = parseNumber(args[0]);

  if (ratio === null || ratio < 0) {
    return null;
  }

  const enlargeArg = args[1];
  const enlarge = enlargeArg === "1" || enlargeArg === "t" || enlargeArg === "true";

  if (enlargeArg !== undefined && !enlarge && enlargeArg !== "0" && enlargeArg !== "f" && enlargeArg !== "false") {
    return null;
  }

  return {
    ...currentState,
    cropAspectRatioEnabled: true,
    cropAspectRatio: ratio,
    cropAspectRatioEnlarge: enlarge,
  };
}
```

- [ ] **Step 3: Add the Svelte control**

In `demo/src/App.svelte`, within the crop control section, add a sub-control: an enable toggle bound to `state.cropAspectRatioEnabled`, a number input bound to `state.cropAspectRatio` (min 0, step 0.1), and an "enlarge" checkbox/toggle bound to `state.cropAspectRatioEnlarge`. Mirror the existing crop controls in this file — the number input can follow the `RangeNumber.svelte`/plain number-input pattern already used for crop dimensions, and the enable/enlarge toggles follow the existing toggle pattern (`ToolToggleHeader.svelte` / the boolean switches used by `resizeExtendEnabled` etc.). Add a summary expression next to the existing crop summary:

```svelte
  $: cropAspectRatioSummary = state.cropAspectRatioEnabled
    ? state.cropAspectRatioEnlarge
      ? `car:${state.cropAspectRatio}:1`
      : `car:${state.cropAspectRatio}`
    : "Off";
```

- [ ] **Step 4: Add demo tests**

In `demo/src/processing-path.test.ts` add:

```typescript
it("emits car with enlarge", () => {
  const state = {
    ...defaultDemoState,
    cropEnabled: true,
    cropAspectRatioEnabled: true,
    cropAspectRatio: 1,
    cropAspectRatioEnlarge: true,
  };
  expect(optionSegments(state)).toContain("car:1:1");
});

it("emits car without enlarge", () => {
  const state = {
    ...defaultDemoState,
    cropEnabled: true,
    cropAspectRatioEnabled: true,
    cropAspectRatio: 1.5,
    cropAspectRatioEnlarge: false,
  };
  expect(optionSegments(state)).toContain("car:1.5");
});
```

- [ ] **Step 5: Run demo tests and typecheck**

Run: `mise exec -- pnpm demo:test`
Expected: PASS.
Run the demo typecheck: `mise exec -- pnpm demo:check`.
Expected: no type errors.

- [ ] **Step 6: Commit**

```bash
git add demo/src/processing-path.ts demo/src/demo-url-state.ts demo/src/App.svelte demo/src/processing-path.test.ts
git commit -m "Add demo controls for imgproxy crop_aspect_ratio"
```

---

## Task 9: Documentation

**Files:**
- Modify: `docs/imgproxy_support_matrix.md` (lines 470, 479, 487)
- Modify: `docs/imgproxy_path_api.md`
- Modify: `docs/transform_operations.md`

- [ ] **Step 1: Update the support matrix**

In `docs/imgproxy_support_matrix.md`:

- Line ~470 (`resizing_algorithm` / `ra`): keep status `Missing`, but mark it Pro. Change the row's notes to indicate it is an imgproxy Pro option (add a `(pro)` marker consistent with sibling Pro rows like `gravity:obj`).
- Line ~479 (`extend_aspect_ratio`): change `Partial` to `Supported`. Update the note to: "Boolean extend + gravity; extends the canvas to the requested resize aspect ratio. `fp` extend-gravity is not supported (matches `extend`)."
- Line ~487 (`crop_aspect_ratio` / `crop_ar` / `car`): change `Missing` to `Supported`, and mark it Pro. Update the note to: "imgproxy Pro. Corrects the crop area aspect ratio; `aspect_ratio` 0 is a no-op, `enlarge` grows the area then clamps to image bounds. Corrects size only, not gravity. Wired through gravity crops."

- [ ] **Step 2: Update the path API and transform docs**

In `docs/imgproxy_path_api.md`, find the `extend_aspect_ratio` and crop documentation. Document the corrected `exar` form (`exar:%extend:%gravity`, default `false:ce`, ratio derived from the resize target, no-op when a resize dimension is auto) and add `crop_aspect_ratio` (`car:%aspect_ratio:%enlarge`, `aspect_ratio` 0 = no correction, `enlarge` boolean) with examples.

In `docs/transform_operations.md`, if it documents canvas/crop operations, note that `CropGuided` now supports an optional aspect-ratio correction (reduce default / enlarge with clamp) and that aspect-ratio canvas extension is driven by the resize target ratio.

Match the existing doc structure and tone in each file; do not invent new sections if an existing option table/row is the right home.

- [ ] **Step 4: Commit**

```bash
git add docs/imgproxy_support_matrix.md docs/imgproxy_path_api.md docs/transform_operations.md
git commit -m "Document exar fix and crop_aspect_ratio; fix matrix Pro markers"
```

---

## Final Verification

- [ ] **Step 1: Full Elixir test suite**

Run: `mise exec -- mix test`
Expected: PASS.

- [ ] **Step 2: Compile with warnings as errors**

Run: `mise exec -- mix compile --warnings-as-errors`
Expected: clean.

- [ ] **Step 3: Credo**

Run: `mise exec -- mix credo --strict`
Expected: no new issues introduced by these changes.

- [ ] **Step 4: Demo tests and typecheck**

Run: `mise exec -- pnpm demo:test`
Expected: PASS.
Run: `mise exec -- pnpm demo:check`
Expected: no type errors.

- [ ] **Step 5: Architecture boundary test**

Run: `mise exec -- mix test test/image_pipe/architecture_boundary_test.exs`
Expected: PASS (request/source/response code still avoids concrete transform modules; parser emits semantic plan operations).
