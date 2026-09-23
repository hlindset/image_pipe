# Imgproxy Color Controls Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add Imgproxy-compatible brightness, contrast, and saturation operations, including parser support, transform execution, documentation, support matrix updates, and demo controls.

**Architecture:** Imgproxy parsing stays declarative: `ImagePipe.Parser.Imgproxy.OptionGrammar` parses URL syntax into parser request fields, `ImagePipe.Parser.Imgproxy.PlanBuilder` emits canonical `ImagePipe.Plan.Operation.*` structs in the existing effect phase, and `ImagePipe.Transform.PlanExecutor` lowers semantic operations into executable transforms after cache lookup. The demo emits the same URL segments and parses them back from `/demo/...` paths.

**Tech Stack:** Elixir, ExUnit, Vix/libvips through the `Image` package, Svelte, TypeScript, the demo test runner.

---

### Task 1: Add Semantic Color Adjustment Operations

**Files:**
- Create: `lib/image_pipe/plan/operation/brightness.ex`
- Create: `lib/image_pipe/plan/operation/contrast.ex`
- Create: `lib/image_pipe/plan/operation/saturation.ex`
- Modify: `lib/image_pipe/plan.ex`
- Modify: `lib/image_pipe/plan/operation.ex`
- Modify: `lib/image_pipe/plan/key_data.ex`
- Test: `test/image_pipe/plan/operation_test.exs`
- Test: `test/image_pipe/plan/operation_key_data_test.exs`
- Test: `test/image_pipe/architecture_boundary_test.exs`

- [ ] **Step 1: Write failing constructor and key-data tests**

Add tests that call `Operation.brightness/1`, `Operation.contrast/1`, and `Operation.saturation/1`.

```elixir
assert {:ok, %Operation.Brightness{value: 20}} = Operation.brightness(20)
assert {:ok, %Operation.Contrast{value: -15}} = Operation.contrast(-15)
assert {:ok, %Operation.Saturation{value: 35}} = Operation.saturation(35)

assert {:error, {:invalid_operation, :brightness, [101]}} = Operation.brightness(101)
assert {:error, {:invalid_operation, :contrast, [-101]}} = Operation.contrast(-101)
assert {:error, {:invalid_operation, :saturation, [101]}} = Operation.saturation(101)
```

Add key-data assertions:

```elixir
assert KeyData.data(brightness) == [op: :brightness, value: 20]
assert KeyData.data(contrast) == [op: :contrast, value: -15]
assert KeyData.data(saturation) == [op: :saturation, value: 35]
```

Add numeric normalization assertions so matching numeric spellings produce identical operation fields and key data:

```elixir
assert {:ok, integer_brightness} = Operation.brightness(20)
assert {:ok, float_brightness} = Operation.brightness(20.0)
assert integer_brightness == float_brightness
assert KeyData.data(integer_brightness) == KeyData.data(float_brightness)
```

- [ ] **Step 2: Run focused tests and verify they fail**

Run: `mise exec -- mix test test/image_pipe/plan/operation_test.exs test/image_pipe/plan/operation_key_data_test.exs test/image_pipe/architecture_boundary_test.exs`

Expected: failures mention missing `Operation.brightness/1`, `Operation.contrast/1`, or `Operation.saturation/1`.

- [ ] **Step 3: Implement semantic structs, constructors, semantic checks, and key data**

Add one enforced-key struct per operation with a numeric `value`. In `ImagePipe.Plan.Operation`, accept integer or float values from `-100` through `100`, normalize whole-number floats to integers, and otherwise store a rounded canonical float so matching requests don't create different cache key material. Reject values outside that range and non-numeric values. Add aliases, semantic type union entries, `semantic?/1` clauses, `ImagePipe.Plan.KeyData.data/1` clauses, and Boundary exports in `ImagePipe.Plan`.

- [ ] **Step 4: Run focused tests and verify they pass**

Run: `mise exec -- mix test test/image_pipe/plan/operation_test.exs test/image_pipe/plan/operation_key_data_test.exs test/image_pipe/architecture_boundary_test.exs`

Expected: all focused tests pass.

### Task 2: Parse And Plan Imgproxy Color Operations

**Files:**
- Modify: `lib/image_pipe/parser/imgproxy/option_grammar.ex`
- Modify: `lib/image_pipe/parser/imgproxy/pipeline_request.ex`
- Modify: `lib/image_pipe/parser/imgproxy/plan_builder.ex`
- Test: `test/parser/imgproxy_test.exs`
- Test: `test/parser/imgproxy/options_test.exs`
- Test: `test/parser/imgproxy/plan_builder_test.exs`

- [ ] **Step 1: Write failing parser and planner tests**

Add tests for short and long aliases:

```elixir
assert operations_for("/_/br:20/co:-15/sa:35/plain/images/cat.jpg")
       |> operation_names() == [:brightness, :contrast, :saturation]

assert operations_for("/_/brightness:20/contrast:-15/saturation:35/plain/images/cat.jpg")
       |> operation_names() == [:brightness, :contrast, :saturation]
```

Add a canonical-order test with deliberately scrambled URL order and existing effects:

```elixir
operations = operations_for("/_/sa:35/pix:8/co:-15/sh:0.7/br:20/bl:2.5/plain/images/cat.jpg")

assert operation_names(operations) == [
         :blur,
         :sharpen,
         :pixelate,
         :brightness,
         :contrast,
         :saturation
       ]
```

Add no-op tests for `0` values:

```elixir
assert operations_for("/_/br:0/co:0/sa:0/plain/images/cat.jpg") == []
```

Add invalid-value tests showing values outside `-100..100` fail at parse/planning time:

```elixir
assert {:error, _reason} = Imgproxy.parse("/_/br:101/plain/images/cat.jpg")
assert {:error, _reason} = Imgproxy.parse("/_/co:-101/plain/images/cat.jpg")
assert {:error, _reason} = Imgproxy.parse("/_/sa:101/plain/images/cat.jpg")
```

Add cache-key tests proving matching numeric spellings and URL orderings resolve to the same cache key material:

```elixir
first = plan_for!("/_/br:20.0/co:-15/sa:35/plain/images/cat.jpg")
second = plan_for!("/_/sa:35/br:20/co:-15.0/plain/images/cat.jpg")

assert canonical_pipeline_key_data(first) == canonical_pipeline_key_data(second)
```

- [ ] **Step 2: Run focused tests and verify they fail**

Run: `mise exec -- mix test test/parser/imgproxy_test.exs test/parser/imgproxy/options_test.exs test/parser/imgproxy/plan_builder_test.exs`

Expected: failures identify unknown Imgproxy options or missing operation mappings.

- [ ] **Step 3: Implement parser request fields and planner mappings**

Add `brightness`, `contrast`, and `saturation` fields to `PipelineRequest`. Parse `brightness`/`br`, `contrast`/`co`, and `saturation`/`sa` as signed numeric values in `OptionGrammar`, accepting only `-100..100`. Emit semantic operations from `PlanBuilder.effect_operations/1` after blur, sharpen, and pixelate, preserving the documented canonical effect order independent of URL option order: `blur`, `sharpen`, `pixelate`, `brightness`, `contrast`, then `saturation`. Treat `0` as an Imgproxy-compatible no-op, matching the existing blur/sharpen/pixelate no-op pattern.

- [ ] **Step 4: Run focused parser/planner tests and verify they pass**

Run: `mise exec -- mix test test/parser/imgproxy_test.exs test/parser/imgproxy/options_test.exs test/parser/imgproxy/plan_builder_test.exs`

Expected: all focused Imgproxy parser tests pass.

### Task 3: Execute Color Adjustments

**Files:**
- Create: `lib/image_pipe/transform/operation/brightness.ex`
- Create: `lib/image_pipe/transform/operation/contrast.ex`
- Create: `lib/image_pipe/transform/operation/saturation.ex`
- Modify: `lib/image_pipe/transform.ex`
- Modify: `lib/image_pipe/transform/decode_planner.ex`
- Modify: `lib/image_pipe/transform/plan_executor.ex`
- Test: `test/transform_chain_test.exs`
- Test: `test/image_pipe/decode_planner_test.exs`
- Test: `test/image_pipe/transform/plan_executor_test.exs`
- Test: `test/image_pipe/imgproxy_wire_conformance_test.exs`
- Test: `test/image_pipe/request_safety_test.exs`
- Test: `test/image_pipe/architecture_boundary_test.exs`

- [ ] **Step 1: Write failing transform and wire tests**

Add direct transform chain coverage showing `Transform.transform_name/1` delegates correctly for brightness, contrast, and saturation.

Add decode planner coverage asserting color-only requests use random access:

```elixir
assert DecodePlanner.open_options(plan([brightness])) == [access: :random]
assert DecodePlanner.open_options(plan([contrast])) == [access: :random]
assert DecodePlanner.open_options(plan([saturation])) == [access: :random]
```

Add separate no-geometry request-boundary cases for each operation, using the existing effects fixture or origin pattern:

```elixir
for path <- [
      "/_/br:25/f:png/plain/images/effects.png",
      "/_/co:10/f:png/plain/images/effects.png",
      "/_/sa:-30/f:png/plain/images/effects.png"
    ] do
  adjusted = call_imgproxy(path, opts)
  baseline = call_imgproxy("/_/f:png/plain/images/effects.png", opts)

  assert adjusted.status == 200
  assert dimensions(adjusted) == dimensions(baseline)
  assert decoded_sample_pixels(adjusted) != decoded_sample_pixels(baseline)
end
```

Add a Plug-level safety test for invalid color-operation values:

```elixir
for path <- [
      "/_/br:101/plain/images/effects.png",
      "/_/co:-101/plain/images/effects.png",
      "/_/sa:101/plain/images/effects.png"
    ] do
  conn = call_imgproxy(path, opts_with_origin_and_cache_probes)

  assert conn.status == 400
  refute_received :cache_lookup
  refute_received :cache_put
  refute_received :origin_fetch
end
```

- [ ] **Step 2: Run focused tests and verify they fail**

Run: `mise exec -- mix test test/transform_chain_test.exs test/image_pipe/decode_planner_test.exs test/image_pipe/transform/plan_executor_test.exs test/image_pipe/imgproxy_wire_conformance_test.exs test/image_pipe/request_safety_test.exs test/image_pipe/architecture_boundary_test.exs`

Expected: failures mention missing executable operation modules, unknown parser options, or unchanged output.

- [ ] **Step 3: Implement executable transforms**

Add executable transform modules with `@behaviour ImagePipe.Transform`, `name/1`, and `execute/2`. Convert Imgproxy `-100..100` values to positive multipliers used by the `Image` package: `0` maps to `1.0`, positive values map above `1.0`, and negative values map below `1.0`. Use `Image.brightness/2`, `Image.contrast/2`, and `Image.saturation/2`, each of which preserves dimensions and handles alpha through the Image package's helper paths.

- [ ] **Step 4: Wire semantic operations into `PlanExecutor`**

Alias the new semantic and executable operations in `ImagePipe.Transform.PlanExecutor`, and add `executable_operations/3` clauses that lower each semantic operation to its executable transform. Add the new executable modules to `ImagePipe.Transform` Boundary exports. Add `DecodePlanner` access-requirement clauses classifying brightness, contrast, and saturation as `:random`, preserving conservative decoding for color-only/no-geometry requests.

- [ ] **Step 5: Run focused transform and wire tests and verify they pass**

Run: `mise exec -- mix test test/transform_chain_test.exs test/image_pipe/decode_planner_test.exs test/image_pipe/transform/plan_executor_test.exs test/image_pipe/imgproxy_wire_conformance_test.exs test/image_pipe/request_safety_test.exs test/image_pipe/architecture_boundary_test.exs`

Expected: all focused transform and wire tests pass.

### Task 4: Update Demo URL State And Controls

**Files:**
- Modify: `demo/src/processing-path.ts`
- Modify: `demo/src/demo-url-state.ts`
- Modify: `demo/src/App.svelte`
- Test: `demo/src/processing-path.test.ts`

- [ ] **Step 1: Write failing demo path tests**

Add tests proving `optionSegments` emits color operations after existing effects:

```ts
expect(
  optionSegments({
    ...defaultDemoState,
    blurEnabled: true,
    blur: 2,
    sharpenEnabled: true,
    sharpen: 1,
    pixelateEnabled: true,
    pixelate: 8,
    brightnessEnabled: true,
    brightness: 20,
    contrastEnabled: true,
    contrast: -15,
    saturationEnabled: true,
    saturation: 35,
  }),
).toEqual(["bl:2", "sh:1", "pix:8", "br:20", "co:-15", "sa:35"]);
```

Add parse tests for `/demo/brightness:20/contrast:-15/saturation:35/plain/local:///images/dog.jpg`, zero-valued color segments normalizing to inactive defaults, invalid `-101` and `101` values falling back to `defaultDemoState`, and `expandedToolboxesForState` opening Effects when any color operation is active.

- [ ] **Step 2: Run demo tests and verify they fail**

Run: `mise exec -- pnpm demo:test`

Expected: TypeScript tests fail because the state fields and parser cases don't exist.

- [ ] **Step 3: Add demo state fields, limits, URL emission, and URL parsing**

Add `brightnessEnabled`, `brightness`, `contrastEnabled`, `contrast`, `saturationEnabled`, and `saturation` to `DemoState` and `defaultDemoState`. Add control limits from `-100` to `100` with integer steps. Emit `br`, `co`, and `sa` segments only when enabled and non-zero. Parse short and long aliases back into enabled state, with `0` disabling the operation and restoring the default displayed value.

- [ ] **Step 4: Add controls to the existing Effects section**

Extend the current Effects section in `App.svelte` with the existing `label.switch-field`, `Switch.Root`, and `RangeNumber` pattern already used by blur, sharpen, and pixelate. Update `effectSegments` so summaries include `br:20`, `co:-15`, and `sa:35` after `bl`, `sh`, and `pix`.

- [ ] **Step 5: Run demo checks and verify they pass**

Run: `mise exec -- pnpm demo:test`

Run: `mise exec -- pnpm demo:check`

Expected: demo tests pass and `svelte-check` reports 0 errors and 0 warnings.

### Task 5: Update Documentation And Support Matrix

**Files:**
- Modify: `docs/imgproxy_support_matrix.md`
- Modify: `docs/transform_operations.md`
- Modify: `docs/imgproxy_path_api.md`

- [ ] **Step 1: Update docs with code-checked behavior**

Change `brightness`, `contrast`, and `saturation` from `Missing` to `Supported` in the support matrix. Each row must list its alias, accepted value range `-100..100`, and `0` no-op behavior. Keep `adjust` marked `Missing`.

Document the fixed effect order as `blur`, `sharpen`, `pixelate`, `brightness`, `contrast`, then `saturation` in `docs/imgproxy_path_api.md` and `docs/transform_operations.md`. Avoid broad "color controls" wording unless the sentence names these exact operations.

### Task 6: Final Verification

**Files:**
- All modified Elixir, TypeScript, Svelte, and documentation files.

- [ ] **Step 1: Format changed code**

Run: `mise exec -- mix format`

Run: `mise exec -- pnpm demo:format`

- [ ] **Step 2: Run focused and broad verification**

Run: `mise exec -- mix test`

Run: `mise exec -- mix compile --warnings-as-errors`

Run: `mise exec -- mix credo --strict`

Run: `mise exec -- pnpm demo:test`

Run: `mise exec -- pnpm demo:check`

Run: `mise exec -- pnpm demo:lint`

Expected: all commands pass.

- [ ] **Step 3: Review final diff**

Run: `git diff --stat`

Run: `git diff --check`

Expected: diff contains only the selected operations, docs, tests, and demo changes. `git diff --check` reports no whitespace errors.

---

## Self-Review

- Spec coverage: The plan covers parser support, semantic operations, transform execution, request-boundary safety, request-boundary pixel behavior, demo UI, support matrix, docs, and final verification.
- Placeholder scan: No `TBD`, `TODO`, or unspecified test commands remain.
- Type consistency: Operation names use `brightness`, `contrast`, and `saturation` across parser fields, semantic operations, executable operations, key data, demo state, and URL segments.
