# Thread neutral config into IIIF + TwicPics — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Route the neutral `ImagePipe.Config` boundary through the IIIF and TwicPics parsers the same way #418/#419 did for imgproxy, so host config (quality, format_quality, strip_metadata, color-profile/HDR policy, jxl_effort, autoquality) is honored by those dialects.

**Architecture:** Finish neutralizing autoquality (promote imgproxy's private fallback constants into `Config` map defaults; lift its `quality_search` builder into a neutral `ImagePipe.Plan.Output.QualitySearch` module). Add two neutral `Config` helpers — `apply_to_output/2` (stamp resolved config onto a `Plan.Output`) and `reject_unsupported!/3` (a dialect-declared support seam). Wire both adapters' `validate_options!` to split neutral vs dialect keys, resolve through `Config`, eagerly catch config-only misconfig at boot, and thread the resolved values onto `Plan.Output`.

**Tech Stack:** Elixir, NimbleOptions, the `Boundary` library, ExUnit, libvips (via Vix/Image).

**Reference spec:** `docs/superpowers/specs/2026-06-28-thread-config-iiif-twicpics-design.md`

**Run everything through the repo toolchain:** prefix mix/elixir invocations with `mise exec -- `. On a fresh worktree, first run `mise trust` and `mise exec -- mix deps.get` if `mise exec -- mix ...` fails.

---

## File Structure

**Neutral core**
- `lib/image_pipe/config.ex` — *modify*: populate two map defaults; add `apply_to_output/2` + `reject_unsupported!/3`; aliases + moduledoc.
- `lib/image_pipe/plan/output/quality_search.ex` — *create*: `build/3` + `from_config/1` (the relocated builder).
- `lib/image_pipe/plan.ex` — *modify*: add `Output.QualitySearch` to the boundary `exports`.

**imgproxy (behavior-preserving)**
- `lib/image_pipe/parser/imgproxy/options.ex` — *modify*: delete private fallback constants + builder; call the neutral `build/3`.

**IIIF**
- `lib/image_pipe/parser/iiif.ex` — *modify*: neutral/dialect split, drop dialect `auto_rotate`, `reject_unsupported!` + eager `from_config` boot check, `iiif_overlay/0`.
- `lib/image_pipe/parser/iiif/plan_builder.ex` — *modify*: `image_plan` sources `auto_rotate` from neutral + runs `apply_to_output/2`.

**TwicPics**
- `lib/image_pipe/parser/twic_pics.ex` — *modify*: neutral/dialect split, `reject_unsupported!` + eager `from_config` boot check, `twicpics_overlay/0`, thread config through `parse/2`.
- `lib/image_pipe/parser/twic_pics/plan_builder.ex` — *modify*: `to_plan/3` sources `auto_rotate` from neutral + runs `apply_to_output/2`.

**Tests / docs**
- `test/image_pipe/config_test.exs`, a new `test/image_pipe/plan/output/quality_search_test.exs`, `test/image_pipe/architecture_boundary_test.exs`, IIIF/TwicPics wire test files, and the three support matrices.

---

## Task 1: Promote autoquality fallback defaults into `Config`

**Files:**
- Modify: `lib/image_pipe/config.ex:59-65` (`@map_defaults`)
- Test: `test/image_pipe/config_test.exs`

- [ ] **Step 1: Write the failing test**

Add to `test/image_pipe/config_test.exs`:

```elixir
describe "autoquality fallback defaults" do
  test "resolve! seeds per-metric target and allowed_error defaults" do
    resolved = ImagePipe.Config.resolve!([])
    assert Keyword.fetch!(resolved, :autoquality_target) == %{ssimulacra2: 78, butteraugli: 1.0}
    assert Keyword.fetch!(resolved, :autoquality_allowed_error) == %{ssimulacra2: 1.0, butteraugli: 0.1}
  end

  test "a host override merges onto the seeded map, keeping the other metric" do
    resolved = ImagePipe.Config.resolve!(autoquality_target: %{ssimulacra2: 90})
    assert Keyword.fetch!(resolved, :autoquality_target) == %{ssimulacra2: 90, butteraugli: 1.0}
  end
end
```

- [ ] **Step 2: Run it to confirm it fails**

Run: `mise exec -- mix test test/image_pipe/config_test.exs -v`
Expected: FAIL — the two maps currently resolve to `%{}`.

- [ ] **Step 3: Populate the map defaults**

In `lib/image_pipe/config.ex`, change `@map_defaults` (currently lines 59-65) to:

```elixir
  @map_defaults [
    format_quality: %{webp: 79, avif: 63, jpeg_xl: 77},
    autoquality_target: %{ssimulacra2: 78, butteraugli: 1.0},
    autoquality_allowed_error: %{ssimulacra2: 1.0, butteraugli: 0.1},
    autoquality_format_min_quality: %{avif: 60, jpeg_xl: 45},
    autoquality_format_max_quality: %{avif: 65, jpeg_xl: 80}
  ]
```

- [ ] **Step 4: Run the test + the imgproxy autoquality regression**

Run: `mise exec -- mix test test/image_pipe/config_test.exs test/parser/imgproxy_test.exs -v`
Expected: PASS. (The imgproxy suite proves the promotion is behavior-preserving — its private builder still reads these maps via `||`, now hitting the seeded value instead of the constant.)

- [ ] **Step 5: Commit**

```bash
git add lib/image_pipe/config.ex test/image_pipe/config_test.exs
git commit -m "feat(config): seed per-metric autoquality target/allowed_error defaults

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Task 2: Create the neutral `Plan.Output.QualitySearch` builder

**Files:**
- Create: `lib/image_pipe/plan/output/quality_search.ex`
- Modify: `lib/image_pipe/plan.ex:9-15` (boundary `exports`)
- Modify: `test/image_pipe/architecture_boundary_test.exs:603-645` (plan exports assertion)
- Test: `test/image_pipe/plan/output/quality_search_test.exs` (create)

- [ ] **Step 1: Write the failing test**

Create `test/image_pipe/plan/output/quality_search_test.exs`:

```elixir
defmodule ImagePipe.Plan.Output.QualitySearchTest do
  use ExUnit.Case, async: true

  alias ImagePipe.Plan.Output.QualitySearch
  alias ImagePipe.Plan.Output.QualitySearch.{Size, Ssimulacra2, Butteraugli}

  # A config keyword shaped like Config.resolve!([]) for the autoquality keys.
  defp config(extra \\ []) do
    Keyword.merge(
      [
        autoquality_method: :none,
        autoquality_min_quality: 70,
        autoquality_max_quality: 80,
        autoquality_max_resolution: 0,
        autoquality_target: %{ssimulacra2: 78, butteraugli: 1.0},
        autoquality_allowed_error: %{ssimulacra2: 1.0, butteraugli: 0.1},
        autoquality_format_min_quality: %{avif: 60, jpeg_xl: 45},
        autoquality_format_max_quality: %{avif: 65, jpeg_xl: 80}
      ],
      extra
    )
  end

  describe "from_config/1" do
    test ":none method yields :none" do
      assert {:ok, :none} = QualitySearch.from_config(config())
    end

    test "ssimulacra2 method builds the struct from seeded defaults" do
      assert {:ok, %Ssimulacra2{target: 78, allowed_error: 1.0, min_quality: 70, max_quality: 80}} =
               QualitySearch.from_config(config(autoquality_method: :ssimulacra2))
    end

    test "butteraugli method builds from seeded defaults" do
      assert {:ok, %Butteraugli{target: 1.0, allowed_error: 0.1}} =
               QualitySearch.from_config(config(autoquality_method: :butteraugli))
    end

    test "size method with no target errors (no :size default exists)" do
      assert {:error, {:invalid_option, :autoquality, :missing_target}} =
               QualitySearch.from_config(config(autoquality_method: :size))
    end

    test "size method with a config target builds" do
      cfg = config(autoquality_method: :size, autoquality_target: %{size: 50_000})
      assert {:ok, %Size{target: 50_000}} = QualitySearch.from_config(cfg)
    end
  end

  describe "build/3 with URL fields" do
    test "url target overrides the config target and is range-checked" do
      assert {:ok, %Ssimulacra2{target: 90}} =
               QualitySearch.build(:ssimulacra2, [target: 90], config())
    end

    test "an in-range seeded default survives the range re-check" do
      assert {:ok, %Butteraugli{target: 1.0}} = QualitySearch.build(:butteraugli, [], config())
    end
  end
end
```

- [ ] **Step 2: Run it to confirm it fails**

Run: `mise exec -- mix test test/image_pipe/plan/output/quality_search_test.exs -v`
Expected: FAIL — `ImagePipe.Plan.Output.QualitySearch` does not exist.

- [ ] **Step 3: Create the module**

Create `lib/image_pipe/plan/output/quality_search.ex`:

```elixir
defmodule ImagePipe.Plan.Output.QualitySearch do
  @moduledoc """
  Builds a per-request autoquality search struct
  (`Size`/`Ssimulacra2`/`Butteraugli`) from resolved neutral config, optionally
  overlaid with URL-supplied fields. Product-neutral: every dialect (imgproxy via
  `build/3` with URL fields, IIIF/TwicPics via `from_config/1` with none) shares
  this one builder, so the struct shape and the per-metric fallbacks live in one
  place.

  Per-metric target and `allowed_error` fallbacks come from the config maps
  (`ImagePipe.Config` seeds `autoquality_target`/`autoquality_allowed_error` for
  the perceptual metrics), so there are no built-in constants here. `:size` has no
  default target — a byte budget must be supplied (URL or config) or `build/3`
  returns a missing-target error.
  """

  alias ImagePipe.Plan.Output.QualitySearch.{Butteraugli, Metric, Size, Ssimulacra2}

  @doc """
  Config-only entry point: select the metric from `autoquality_method` and build.
  `:none` short-circuits to `{:ok, :none}`. No URL fields.
  """
  @spec from_config(keyword()) :: {:ok, struct() | :none} | {:error, term()}
  def from_config(config) do
    case Keyword.get(config, :autoquality_method, :none) do
      :none -> {:ok, :none}
      metric -> build(metric, [], config)
    end
  end

  @doc "Build a search struct for an already-decided metric, URL fields over config."
  @spec build(:size | :ssimulacra2 | :butteraugli, keyword(), keyword()) ::
          {:ok, struct()} | {:error, term()}
  def build(:size, fields, config) do
    with {:ok, target} <- resolve_target(:size, fields, config) do
      {:ok,
       %Size{
         target: target,
         min_quality: Keyword.get(config, :autoquality_min_quality, 70),
         max_quality: Keyword.get(config, :autoquality_max_quality, 80),
         url_min_quality: Keyword.get(fields, :min_quality),
         url_max_quality: Keyword.get(fields, :max_quality),
         format_min: Keyword.get(config, :autoquality_format_min_quality, %{}),
         format_max: Keyword.get(config, :autoquality_format_max_quality, %{}),
         max_resolution: Keyword.get(config, :autoquality_max_resolution, 0)
       }}
    end
  end

  def build(:ssimulacra2, fields, config),
    do: build_perceptual(Ssimulacra2, :ssimulacra2, fields, config)

  def build(:butteraugli, fields, config),
    do: build_perceptual(Butteraugli, :butteraugli, fields, config)

  defp build_perceptual(struct_mod, metric, fields, config) do
    with {:ok, target} <- resolve_target(metric, fields, config) do
      {:ok,
       struct(struct_mod, %{
         target: target,
         min_quality: Keyword.get(config, :autoquality_min_quality, 70),
         max_quality: Keyword.get(config, :autoquality_max_quality, 80),
         url_min_quality: Keyword.get(fields, :min_quality),
         url_max_quality: Keyword.get(fields, :max_quality),
         allowed_error: resolve_allowed_error(metric, fields, config),
         format_min: Keyword.get(config, :autoquality_format_min_quality, %{}),
         format_max: Keyword.get(config, :autoquality_format_max_quality, %{}),
         max_resolution: Keyword.get(config, :autoquality_max_resolution, 0)
       })}
    end
  end

  # URL arg → per-metric config map. The config map is always seeded for the
  # perceptual metrics, so no built-in constant fallback remains. 0/0.0 are truthy
  # in Elixir, so a configured 0 is honored by the `||`.
  defp resolve_allowed_error(metric, fields, config) do
    Keyword.get(fields, :allowed_error) ||
      Map.get(Keyword.get(config, :autoquality_allowed_error, %{}), metric)
  end

  # URL arg → per-metric config map → missing-target error (`:size` only, since the
  # perceptual metrics are seeded).
  defp resolve_target(metric, fields, config) do
    config_target = Map.get(Keyword.get(config, :autoquality_target, %{}), metric)

    case Keyword.get(fields, :target, config_target) do
      nil -> {:error, {:invalid_option, :autoquality, :missing_target}}
      target -> validate_target_range(metric, target)
    end
  end

  defp validate_target_range(:size, target) when is_integer(target) and target > 0,
    do: {:ok, target}

  defp validate_target_range(:size, target),
    do: {:error, {:invalid_option, :autoquality, {:target_out_of_range, target}}}

  defp validate_target_range(metric, target) do
    {lo, hi} = Metric.target_range(metric)

    if is_number(target) and target >= lo and target <= hi,
      do: {:ok, target},
      else: {:error, {:invalid_option, :autoquality, {:target_out_of_range, target}}}
  end
end
```

- [ ] **Step 4: Export the parent module from the `Plan` boundary**

In `lib/image_pipe/plan.ex`, add `Output.QualitySearch` to the `exports:` list, right before the `Output.QualitySearch.Metric` line:

```elixir
      Pipeline,
      Output,
      Output.QualitySearch,
      Output.QualitySearch.Metric,
```

In `test/image_pipe/architecture_boundary_test.exs`, add the matching entry to the `assert_boundary_exports(plan, [...])` list (before `ImagePipe.Plan.Output.QualitySearch.Metric`):

```elixir
      ImagePipe.Plan.Output,
      ImagePipe.Plan.Output.QualitySearch,
      ImagePipe.Plan.Output.QualitySearch.Metric,
```

- [ ] **Step 5: Run the unit test + architecture test**

Run: `mise exec -- mix test test/image_pipe/plan/output/quality_search_test.exs test/image_pipe/architecture_boundary_test.exs -v`
Expected: PASS (both the builder tests and the exact-match export assertion).

- [ ] **Step 6: Commit**

```bash
git add lib/image_pipe/plan/output/quality_search.ex lib/image_pipe/plan.ex \
  test/image_pipe/plan/output/quality_search_test.exs test/image_pipe/architecture_boundary_test.exs
git commit -m "feat(plan): neutral Plan.Output.QualitySearch builder (build/3 + from_config/1)

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Task 3: Route imgproxy through the neutral builder

**Files:**
- Modify: `lib/image_pipe/parser/imgproxy/options.ex` (delete private builder + constants ~lines 13-24, 415-494; rewire `resolve_quality_search_defaults` ~lines 386-402)
- Test: `test/parser/imgproxy_test.exs`, `test/image_pipe/imgproxy_wire_conformance_test.exs`

- [ ] **Step 1: Rewire `resolve_quality_search_defaults` to call the neutral builder**

In `lib/image_pipe/parser/imgproxy/options.ex`, the `metric ->` branch of `resolve_quality_search_defaults` (lines 391-396) currently calls the private `build_quality_search`. Change it to call the neutral builder (the module already has `alias ImagePipe.Plan.Output.QualitySearch` at line 10):

```elixir
      metric ->
        QualitySearch.build(
          metric,
          url_quality_search_fields(output.quality_search),
          defaults
        )
        |> case do
          {:ok, search} -> {:ok, %{output | quality_search: search}}
          {:error, _reason} = error -> error
        end
```

- [ ] **Step 2: Delete the now-dead private builder and constants**

In the same file, delete:
- The module attributes `@default_ssim2_target 78` (line 20) and `@default_butteraugli_target 1.0` (line 24), plus their leading comments.
- The private functions `build_quality_search/3`, `build_quality_metric/4`, `resolve_allowed_error/3`, `default_allowed_error/1`, `resolve_quality_search_target/3`, `validate_target_range/2`, and `default_target/1` (the block spanning roughly lines 415-494).

Keep `effective_quality_search_method/2` and `url_quality_search_fields/1` (metric selection stays in the adapter). Verify no other references to the deleted names remain:

Run: `mise exec -- grep -n "default_target\|default_allowed_error\|build_quality_search\|build_quality_metric\|resolve_quality_search_target\|@default_ssim2_target\|@default_butteraugli_target" lib/image_pipe/parser/imgproxy/options.ex`
Expected: no matches.

- [ ] **Step 3: Run the imgproxy regression suites**

Run: `mise exec -- mix test test/parser/imgproxy_test.exs test/image_pipe/imgproxy_wire_conformance_test.exs -v`
Expected: PASS unchanged — same resolved structs, same values (behavior-preserving).

- [ ] **Step 4: Compile with warnings-as-errors (catches any orphaned helper)**

Run: `mise exec -- mix compile --warnings-as-errors`
Expected: clean compile, no "function X is unused" warnings.

- [ ] **Step 5: Commit**

```bash
git add lib/image_pipe/parser/imgproxy/options.ex
git commit -m "refactor(imgproxy): delegate autoquality search to neutral builder

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Task 4: Add `Config.apply_to_output/2`

**Files:**
- Modify: `lib/image_pipe/config.ex` (aliases + new function)
- Test: `test/image_pipe/config_test.exs`

- [ ] **Step 1: Write the failing test**

Add to `test/image_pipe/config_test.exs`:

```elixir
describe "apply_to_output/2" do
  alias ImagePipe.Plan.Output
  alias ImagePipe.Plan.Output.QualitySearch.Ssimulacra2

  test "stamps the neutral fields, normalizing quality, without touching :quality" do
    resolved = ImagePipe.Config.resolve!([])
    base = %Output{mode: {:explicit, :webp}}

    assert {:ok, out} = ImagePipe.Config.apply_to_output(base, resolved)
    assert out.quality == :default
    assert out.default_quality == {:quality, 80}
    assert out.format_qualities == %{webp: {:quality, 79}, avif: {:quality, 63}, jpeg_xl: {:quality, 77}}
    assert out.color_profile == :strip
    assert out.hdr == :tone_map
    assert out.quality_search == :none
  end

  test "a URL quality on the base output is preserved" do
    resolved = ImagePipe.Config.resolve!([])
    base = %Output{mode: {:explicit, :webp}, quality: {:quality, 55}}
    assert {:ok, out} = ImagePipe.Config.apply_to_output(base, resolved)
    assert out.quality == {:quality, 55}
  end

  test "keep_copyright is forced false when metadata is not stripped" do
    resolved = ImagePipe.Config.resolve!(strip_metadata: false, keep_copyright: true)
    assert {:ok, out} = ImagePipe.Config.apply_to_output(%Output{mode: :automatic}, resolved)
    assert out.strip_metadata == false
    assert out.keep_copyright == false
  end

  test "builds the quality_search from a configured autoquality method" do
    resolved = ImagePipe.Config.resolve!(autoquality_method: :ssimulacra2)
    assert {:ok, %Output{quality_search: %Ssimulacra2{target: 78}}} =
             ImagePipe.Config.apply_to_output(%Output{mode: :automatic}, resolved)
  end

  test "propagates a from_config error (size method, no target)" do
    resolved = ImagePipe.Config.resolve!(autoquality_method: :size)
    assert {:error, {:invalid_option, :autoquality, :missing_target}} =
             ImagePipe.Config.apply_to_output(%Output{mode: :automatic}, resolved)
  end
end
```

- [ ] **Step 2: Run it to confirm it fails**

Run: `mise exec -- mix test test/image_pipe/config_test.exs -v`
Expected: FAIL — `apply_to_output/2` is undefined.

- [ ] **Step 3: Add aliases and the function**

In `lib/image_pipe/config.ex`, the existing alias is `alias ImagePipe.Plan.Output.QualitySearch.Metric`. Add the two modules this function needs:

```elixir
  alias ImagePipe.Plan.Output
  alias ImagePipe.Plan.Output.QualitySearch
  alias ImagePipe.Plan.Output.QualitySearch.Metric
```

Add the public function (place it after `resolve!/2`):

```elixir
  @doc """
  Stamp resolved neutral config onto a base `Plan.Output`. Sets the encoder/
  metadata/color/autoquality fields; deliberately leaves `:quality` (the URL-level
  quality a dialect may have set) untouched, so a URL quality wins over the config
  `default_quality`/`format_qualities` base. Returns `{:error, _}` if the
  autoquality config is invalid (e.g. `:size` method with no target).
  """
  @spec apply_to_output(Output.t(), keyword()) :: {:ok, Output.t()} | {:error, term()}
  def apply_to_output(%Output{} = output, resolved) when is_list(resolved) do
    strip = Keyword.fetch!(resolved, :strip_metadata)
    keep = Keyword.fetch!(resolved, :keep_copyright)

    with {:ok, quality_search} <- QualitySearch.from_config(resolved) do
      {:ok,
       %{
         output
         | default_quality: {:quality, Keyword.fetch!(resolved, :quality)},
           format_qualities: normalize_format_qualities(Keyword.fetch!(resolved, :format_quality)),
           strip_metadata: strip,
           keep_copyright: strip and keep,
           color_profile: color_profile_policy(Keyword.fetch!(resolved, :strip_color_profile)),
           hdr: hdr_policy(Keyword.fetch!(resolved, :preserve_hdr)),
           jxl_effort: Keyword.get(resolved, :jxl_effort),
           quality_search: quality_search
       }}
    end
  end

  # Config carries bare per-format ints; Plan.Output wants the {:quality, n} shape.
  defp normalize_format_qualities(map), do: Map.new(map, fn {fmt, q} -> {fmt, {:quality, q}} end)

  defp color_profile_policy(true), do: :strip
  defp color_profile_policy(false), do: :preserve_source

  defp hdr_policy(true), do: :preserve
  defp hdr_policy(false), do: :tone_map
```

- [ ] **Step 4: Run the test + the boundary test**

Run: `mise exec -- mix test test/image_pipe/config_test.exs test/image_pipe/architecture_boundary_test.exs -v`
Expected: PASS (the boundary test confirms `Config → [Plan]` still holds — `Output`/`QualitySearch` are exported Plan modules).

- [ ] **Step 5: Commit**

```bash
git add lib/image_pipe/config.ex test/image_pipe/config_test.exs
git commit -m "feat(config): apply_to_output/2 stamps resolved config onto Plan.Output

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Task 5: Add `Config.reject_unsupported!/3`

**Files:**
- Modify: `lib/image_pipe/config.ex`
- Test: `test/image_pipe/config_test.exs`

- [ ] **Step 1: Write the failing test**

Add to `test/image_pipe/config_test.exs`:

```elixir
describe "reject_unsupported!/3" do
  test ":all returns the input keyword verbatim (same keys and order)" do
    input = [quality: 80, strip_metadata: true]
    assert ImagePipe.Config.reject_unsupported!(input, :all, "IIIF") == input
  end

  test "a declared subset returns input unchanged when all keys are inside it" do
    input = [quality: 80]
    assert ImagePipe.Config.reject_unsupported!(input, [:quality, :strip_metadata], "X") == input
  end

  test "raises a dialect-named ArgumentError for an out-of-subset key" do
    assert_raise ArgumentError, ~r/Demo parser does not support config.*autoquality_method/, fn ->
      ImagePipe.Config.reject_unsupported!([autoquality_method: :ssimulacra2], [:quality], "Demo")
    end
  end
end
```

- [ ] **Step 2: Run it to confirm it fails**

Run: `mise exec -- mix test test/image_pipe/config_test.exs -v`
Expected: FAIL — `reject_unsupported!/3` is undefined.

- [ ] **Step 3: Add the function**

In `lib/image_pipe/config.ex`, add (after `apply_to_output/2`):

```elixir
  @doc """
  Reject host config keys a dialect declares unsupported. The adapter passes the
  neutral subset it honors (`:all` for full support); any key outside it raises a
  uniform, dialect-named `ArgumentError`. Otherwise returns the input keyword
  **verbatim** — it never filters, so a key is never silently dropped.
  """
  @spec reject_unsupported!(keyword(), [atom()] | :all, String.t()) :: keyword()
  def reject_unsupported!(neutral, :all, _dialect) when is_list(neutral), do: neutral

  def reject_unsupported!(neutral, supported, dialect)
      when is_list(neutral) and is_list(supported) and is_binary(dialect) do
    case Keyword.keys(neutral) -- supported do
      [] ->
        neutral

      unsupported ->
        raise ArgumentError,
              "the #{dialect} parser does not support config: #{inspect(unsupported)}"
    end
  end
```

- [ ] **Step 4: Run the test**

Run: `mise exec -- mix test test/image_pipe/config_test.exs -v`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add lib/image_pipe/config.ex test/image_pipe/config_test.exs
git commit -m "feat(config): reject_unsupported!/3 seam for dialect-unsupported config

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Task 6: IIIF — route `validate_options!` through Config

**Files:**
- Modify: `lib/image_pipe/parser/iiif.ex:21-47` (schema + `validate_options!` + `validate_max_bounds!`)
- Test: `test/parser/iiif_test.exs` (or the existing IIIF parser test file — confirm with `mise exec -- ls test/parser | grep -i iiif`)

- [ ] **Step 1: Write the failing test**

Add to the IIIF parser test file (a resolver stub module + cases). Use whatever resolver stub the file already defines; if none, add:

```elixir
defmodule IIIFConfigTest.Resolver do
  def resolve(_id, _opts), do: {:ok, %ImagePipe.Plan.Source.Path{path: "/tmp/x.jpg"}}
end

describe "validate_options! neutral config" do
  @valid [resolver: {IIIFConfigTest.Resolver, []}]

  test "accepts and resolves a neutral quality key" do
    opts = ImagePipe.Parser.IIIF.validate_options!(iiif: @valid ++ [quality: 90])
    iiif = Keyword.fetch!(opts, :iiif)
    assert Keyword.fetch!(iiif, :quality) == 90
    assert Keyword.fetch!(iiif, :tile_size) == 512
  end

  test "auto_rotate is now a neutral key (honored, default true)" do
    opts = ImagePipe.Parser.IIIF.validate_options!(iiif: @valid)
    assert Keyword.fetch!(Keyword.fetch!(opts, :iiif), :auto_rotate) == true

    opts2 = ImagePipe.Parser.IIIF.validate_options!(iiif: @valid ++ [auto_rotate: false])
    assert Keyword.fetch!(Keyword.fetch!(opts2, :iiif), :auto_rotate) == false
  end

  test "rejects an unknown dialect key" do
    assert_raise ArgumentError, ~r/unknown keys/, fn ->
      ImagePipe.Parser.IIIF.validate_options!(iiif: @valid ++ [bogus: 1])
    end
  end

  test "raises at init for autoquality :size with no target" do
    assert_raise ArgumentError, ~r/autoquality/, fn ->
      ImagePipe.Parser.IIIF.validate_options!(iiif: @valid ++ [autoquality_method: :size])
    end
  end
end
```

- [ ] **Step 2: Run it to confirm it fails**

Run: `mise exec -- mix test test/parser/iiif_test.exs -v`
Expected: FAIL — neutral keys are rejected by the current fixed schema, and `auto_rotate` is still a dialect key.

- [ ] **Step 3: Rewrite the schema + `validate_options!`**

In `lib/image_pipe/parser/iiif.ex`, replace the `@schema` (lines 21-30) with a dialect-only schema, dialect-key list, and supported-neutral attribute:

```elixir
  @dialect_schema NimbleOptions.new!(
                    resolver: [type: {:custom, __MODULE__, :validate_resolver, []}, required: true],
                    formats: [type: {:list, :atom}, default: [:jpg, :png, :webp, :avif]],
                    qualities: [type: {:list, :atom}, default: [:default, :color, :gray, :bitonal]],
                    tile_size: [type: :pos_integer, default: 512],
                    max_width: [type: :pos_integer],
                    max_height: [type: :pos_integer],
                    max_area: [type: :pos_integer]
                  )

  @dialect_keys [:resolver, :formats, :qualities, :tile_size, :max_width, :max_height, :max_area]

  # The full neutral surface is honored; the reject seam is a no-op today.
  @supported_neutral :all
```

Replace `validate_options!/1` (lines 32-38) with:

```elixir
  @impl true
  def validate_options!(opts) do
    iiif = Keyword.get(opts, :iiif, [])
    {neutral, rest} = Keyword.split(iiif, ImagePipe.Config.keys())
    {dialect, unknown} = Keyword.split(rest, @dialect_keys)

    unless unknown == [] do
      raise ArgumentError, "iiif: unknown keys #{inspect(Keyword.keys(unknown))}"
    end

    dialect = NimbleOptions.validate!(dialect, @dialect_schema)
    validate_max_bounds!(dialect)

    neutral =
      neutral
      |> ImagePipe.Config.reject_unsupported!(@supported_neutral, "IIIF")
      |> ImagePipe.Config.resolve!(iiif_overlay())

    # Config-only dialect: the autoquality search is fully determined here, so
    # surface a bad method/target combination at boot rather than per request.
    case ImagePipe.Plan.Output.QualitySearch.from_config(neutral) do
      {:ok, _} -> :ok
      {:error, reason} -> raise ArgumentError, "iiif: invalid autoquality config: #{inspect(reason)}"
    end

    Keyword.put(opts, :iiif, Keyword.merge(neutral, dialect))
  end

  defp iiif_overlay, do: []
```

`validate_max_bounds!/1` (lines 41-47) is unchanged — it now receives the validated `dialect` keyword, which still carries `max_width`/`max_height`.

- [ ] **Step 4: Run the IIIF parser tests + the existing IIIF wire tests**

Run: `mise exec -- mix test test/parser/iiif_test.exs -v`
Expected: PASS. Then run any IIIF wire test file to confirm nothing regressed (find it: `mise exec -- ls test/image_pipe | grep -i iiif`), e.g. `mise exec -- mix test test/parser/iiif_wire_test.exs`.

- [ ] **Step 5: Commit**

```bash
git add lib/image_pipe/parser/iiif.ex test/parser/iiif_test.exs
git commit -m "feat(iiif): route host config through ImagePipe.Config; drop dialect auto_rotate

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Task 7: IIIF — thread config onto the image plan

**Files:**
- Modify: `lib/image_pipe/parser/iiif/plan_builder.ex:63-92` (`image_plan/3`)
- Test: the IIIF wire test file (real `ImagePipe.call/2`, decode body, compare pixels)

- [ ] **Step 1: Write the failing wire test**

Add to the IIIF wire test file a test that a host `quality` visibly changes the encoded bytes. Use the mount/source pattern already in that file; the assertion shape:

```elixir
test "host-config quality changes the encoded JPEG output" do
  # Build two mounts differing only by iiif quality; request the same image path.
  low = call_iiif(quality: 40, path: "/img-id/full/max/0/default.jpg")
  high = call_iiif(quality: 95, path: "/img-id/full/max/0/default.jpg")

  assert low.status == 200 and high.status == 200
  assert byte_size(low.resp_body) != byte_size(high.resp_body)
end
```

Implement `call_iiif/1` with the file's existing helper for mounting `ImagePipe` with `iiif: [resolver: ..., quality: q]` and issuing a `conn`. (Match the established helper names in that file — do not invent a new harness.)

- [ ] **Step 2: Run it to confirm it fails**

Run: `mise exec -- mix test test/parser/iiif_wire_test.exs -v`
Expected: FAIL — today both responses use the encoder built-in default (identical bytes), so the sizes match.

- [ ] **Step 3: Thread `auto_rotate` + `apply_to_output` into `image_plan`**

In `lib/image_pipe/parser/iiif/plan_builder.ex`, edit `image_plan/3` (lines 63-92). Change the `auto_rotate` source (line 64) and add the `apply_to_output` step to the `with` chain:

```elixir
  def image_plan(source, tokens, opts \\ []) do
    auto_rotate = Keyword.fetch!(opts, :auto_rotate)
    debug? = Keyword.get(opts, :debug?, false)
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
         {:ok, output} <- output_plan(tokens.format),
         {:ok, output} <- ImagePipe.Config.apply_to_output(output, opts) do
      operations = region_ops ++ size_ops ++ rotation_ops ++ quality_ops

      {:ok,
       %Plan{
         source: source,
         auto_rotate: auto_rotate,
         pipelines: [%Pipeline{operations: operations}],
         output: output,
         response: %Response{debug?: debug?}
       }}
    end
  end
```

`opts` here is the IIIF keyword from `parse/2` (`Keyword.put(iiif, :debug?, …)`), which carries the resolved neutral config — so `apply_to_output/2`'s `Keyword.fetch!` calls all succeed. `info_plan/3` is unchanged (it builds no `Output` and keeps `auto_rotate: false`).

- [ ] **Step 4: Fix the direct `image_plan/3` call sites in the unit test**

`test/parser/iiif/plan_builder_test.exs` calls `PlanBuilder.image_plan/3` directly with partial opts (e.g. `auto_rotate: true`, `max_width: 2000`). After Step 3 the builder runs `apply_to_output/2`, which `Keyword.fetch!`es neutral keys — so those calls must now pass a resolved neutral config. Add a helper near the top of the module (after the `@source` definition):

```elixir
  defp opts(extra \\ []), do: Keyword.merge(ImagePipe.Config.resolve!([]), extra)
```

Then wrap the opts argument of **every** `PlanBuilder.image_plan/3` call with it. The `build/1` helper (line ~11) becomes:

```elixir
  defp build(tokens), do: PlanBuilder.image_plan(@source, tokens, opts(auto_rotate: true))
```

And each inline call (the calls at roughly lines 186, 199, 267, 286, 318, 338) changes its final argument the same way — e.g. `auto_rotate: false` → `opts(auto_rotate: false)`, `max_width: 2000` → `opts(max_width: 2000)`, `[max_width: 2000, max_area: 3_000_000]` → `opts(max_width: 2000, max_area: 3_000_000)`. These tests assert on `auto_rotate`, ops, and `out.mode` (field access, not exact-struct equality), so the extra populated `Output` fields don't affect them.

- [ ] **Step 5: Run the wire test + the IIIF parser/unit tests**

Run: `mise exec -- mix test test/parser/iiif_wire_test.exs test/parser/iiif_test.exs test/parser/iiif/plan_builder_test.exs -v`
Expected: PASS — differing quality yields differing bytes; info.json/structure tests unchanged.

- [ ] **Step 6: Commit**

```bash
git add lib/image_pipe/parser/iiif/plan_builder.ex test/parser/iiif_wire_test.exs test/parser/iiif/plan_builder_test.exs
git commit -m "feat(iiif): thread resolved config onto the image-plan Output

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Task 8: TwicPics — route `validate_options!` through Config

**Files:**
- Modify: `lib/image_pipe/parser/twic_pics.ex:18-41` (schema + `validate_options!`)
- Test: `test/parser/twic_pics_test.exs` (confirm path with `mise exec -- ls test/parser | grep -i twic`)

- [ ] **Step 1: Write the failing test**

Add to the TwicPics parser test file:

```elixir
describe "validate_options! neutral config" do
  test "accepts and resolves a neutral quality key" do
    opts = ImagePipe.Parser.TwicPics.validate_options!(twicpics: [quality: 90])
    assert Keyword.fetch!(Keyword.fetch!(opts, :twicpics), :quality) == 90
  end

  test "rejects an unknown key" do
    assert_raise ArgumentError, ~r/unknown keys/, fn ->
      ImagePipe.Parser.TwicPics.validate_options!(twicpics: [bogus: 1])
    end
  end

  test "raises at init for autoquality :size with no target" do
    assert_raise ArgumentError, ~r/autoquality|invalid twicpics/, fn ->
      ImagePipe.Parser.TwicPics.validate_options!(twicpics: [autoquality_method: :size])
    end
  end
end
```

- [ ] **Step 2: Run it to confirm it fails**

Run: `mise exec -- mix test test/parser/twic_pics_test.exs -v`
Expected: FAIL — the current empty NimbleOptions schema rejects `quality` as unknown, and there is no autoquality boot check.

- [ ] **Step 3: Rewrite `validate_options!`**

In `lib/image_pipe/parser/twic_pics.ex`, remove the `@schema` (line 18) and the `validate_twicpics_options!/1` clauses (lines 30-41), and replace `validate_options!/1` (lines 20-28) with:

```elixir
  # TwicPics has no host-level dialect options today; the full neutral surface is
  # honored, so the reject seam is a no-op.
  @supported_neutral :all

  @impl ImagePipe.Parser
  def validate_options!(opts) when is_list(opts) do
    twicpics = Keyword.get(opts, :twicpics, [])

    unless is_list(twicpics) do
      raise ArgumentError, "invalid twicpics options: expected a keyword list"
    end

    {neutral, unknown} = Keyword.split(twicpics, ImagePipe.Config.keys())

    unless unknown == [] do
      raise ArgumentError, "invalid twicpics config: unknown keys #{inspect(Keyword.keys(unknown))}"
    end

    neutral =
      neutral
      |> ImagePipe.Config.reject_unsupported!(@supported_neutral, "TwicPics")
      |> ImagePipe.Config.resolve!(twicpics_overlay())

    case ImagePipe.Plan.Output.QualitySearch.from_config(neutral) do
      {:ok, _} -> :ok
      {:error, reason} -> raise ArgumentError, "invalid twicpics config: #{inspect(reason)}"
    end

    Keyword.put(opts, :twicpics, neutral)
  end

  defp twicpics_overlay, do: []
```

- [ ] **Step 4: Run the TwicPics parser tests**

Run: `mise exec -- mix test test/parser/twic_pics_test.exs -v`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add lib/image_pipe/parser/twic_pics.ex test/parser/twic_pics_test.exs
git commit -m "feat(twicpics): route host config through ImagePipe.Config

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Task 9: TwicPics — thread config onto the plan

**Files:**
- Modify: `lib/image_pipe/parser/twic_pics.ex:43-49` (`parse/2`)
- Modify: `lib/image_pipe/parser/twic_pics/plan_builder.ex:14-27` (`to_plan/2` → `to_plan/3`)
- Test: the TwicPics wire test file (real `ImagePipe.call/2`)

- [ ] **Step 1: Write the failing wire test**

Add to the TwicPics wire test file:

```elixir
test "URL quality wins over config; config default applies when URL omits quality" do
  # Same image, both mounts configured quality: 30.
  with_url_q = call_twic(quality: 30, twic: "v1/output=jpeg/quality=90")
  config_only = call_twic(quality: 30, twic: "v1/output=jpeg")

  assert with_url_q.status == 200 and config_only.status == 200
  # URL quality=90 produces larger bytes than the config default quality=30.
  assert byte_size(with_url_q.resp_body) > byte_size(config_only.resp_body)
end
```

Implement `call_twic/1` with the file's existing mount/request helper (host `twicpics: [quality: q]`, request path `?twic=<spec>`). Match established helper names in that file.

- [ ] **Step 2: Run it to confirm it fails**

Run: `mise exec -- mix test test/image_pipe/twic_pics_wire_conformance_test.exs -v`
Expected: FAIL — `to_plan/3` does not exist yet and config quality is not threaded (both bodies use encoder defaults).

- [ ] **Step 3: Pass config through `parse/2`**

In `lib/image_pipe/parser/twic_pics.ex`, change `parse/2` (lines 43-49) to read the resolved config and pass it to the builder:

```elixir
  @impl ImagePipe.Parser
  def parse(%Plug.Conn{} = conn, opts) do
    config = Keyword.fetch!(opts, :twicpics)

    with {:ok, source, manipulation} <- Path.extract(conn),
         {:ok, chain} <- Manipulation.parse(manipulation) do
      PlanBuilder.to_plan(source, chain, config)
    end
  end
```

- [ ] **Step 4: Make `to_plan/3` source auto_rotate + apply config**

In `lib/image_pipe/parser/twic_pics/plan_builder.ex`, change `to_plan/2` (lines 14-27) to `to_plan/3` (the `/2` arity is removed — all callers move to `/3`):

```elixir
  @spec to_plan(Source.t(), [{String.t(), String.t()}], keyword()) ::
          {:ok, Plan.t()} | {:error, term()}
  def to_plan(source, chain, config) when is_list(chain) do
    with {:ok, acc} <- fold(chain),
         {:ok, output} <- Output.build(%{format: acc.format, quality: acc.quality}),
         {:ok, output} <- ImagePipe.Config.apply_to_output(output, config) do
      {:ok,
       %Plan{
         source: source,
         pipelines: [%Pipeline{operations: Enum.reverse(acc.ops)}],
         output: output,
         auto_rotate: Keyword.fetch!(config, :auto_rotate),
         response: %Response{debug?: acc.debug?}
       }}
    end
  end
```

- [ ] **Step 5: Fix the direct `to_plan/2` call sites (three files)**

Three tests call the old `to_plan/2` to build a plan for an unrelated assertion. Pass `ImagePipe.Config.resolve!([])` as the third argument (the resolved neutral defaults) in each:

- `test/parser/twic_pics/plan_builder_test.exs:11`:
  ```elixir
  defp build(chain),
    do: PlanBuilder.to_plan(%Source.Path{segments: ["x.jpg"]}, chain, ImagePipe.Config.resolve!([]))
  ```
- `test/image_pipe/cache/key_test.exs:1362`:
  ```elixir
      {:ok, plan} =
        PlanBuilder.to_plan(%Source.Path{segments: ["images", "cat.jpg"]}, chain, ImagePipe.Config.resolve!([]))
  ```
- `test/image_pipe/transform/focus_test.exs:166`:
  ```elixir
    {:ok, plan} = PlanBuilder.to_plan(%Source.Path{segments: ["x.png"]}, chain, ImagePipe.Config.resolve!([]))
  ```

(These assert on operations / cache keys / focus geometry, not output quality, so the extra populated `Output` fields don't affect them.)

- [ ] **Step 6: Run the wire test + the existing TwicPics/cache/focus tests**

Run: `mise exec -- mix test test/image_pipe/twic_pics_wire_conformance_test.exs test/parser/twic_pics_test.exs test/parser/twic_pics/plan_builder_test.exs test/image_pipe/cache/key_test.exs test/image_pipe/transform/focus_test.exs -v`
Expected: PASS — URL quality outweighs the config default; existing TwicPics/cache/focus behavior intact.

- [ ] **Step 7: Commit**

```bash
git add lib/image_pipe/parser/twic_pics.ex lib/image_pipe/parser/twic_pics/plan_builder.ex \
  test/image_pipe/twic_pics_wire_conformance_test.exs test/parser/twic_pics/plan_builder_test.exs \
  test/image_pipe/cache/key_test.exs test/image_pipe/transform/focus_test.exs
git commit -m "feat(twicpics): thread resolved config onto the plan Output

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Task 10: Update the conformance matrices

**Files:**
- Modify: `docs/imgproxy_support_matrix.md` (~line 666)
- Modify: `docs/iiif_3_support_matrix.md`
- Modify: `docs/twicpics_support_matrix.md`

- [ ] **Step 1: Update the imgproxy matrix (stage/internal-resolution)**

In `docs/imgproxy_support_matrix.md` line ~666, the autoquality note names `@default_butteraugli_target 1.0`. Reword so it no longer references the deleted constant; the value is unchanged. For example, change the `:butteraugli` clause to read "`:butteraugli` → `1.0` (a butteraugli distance ≈ visually lossless; …)" and add: "Per-metric fallbacks now live in `ImagePipe.Config`'s seeded `autoquality_target`/`autoquality_allowed_error` map defaults rather than imgproxy-private constants."

- [ ] **Step 2: Update the IIIF matrix (surface + behavioral)**

In `docs/iiif_3_support_matrix.md`, add a "Host config" note (near the existing `tile_size` Config note): the neutral `ImagePipe.Config` tunables (`quality`, `format_quality`, `strip_metadata`/`keep_copyright`, color-profile/HDR policy, `jxl_effort`, `autoquality_*`) are honored, and `auto_rotate` is now a neutral key. Note the behavioral default: absent host config, output now uses the neutral default quality (global `80`; per-format `webp 79 / avif 63 / jpeg_xl 77`) instead of the encoder built-in.

- [ ] **Step 3: Update the TwicPics matrix (surface + behavioral)**

In `docs/twicpics_support_matrix.md` near line 139 (`quality=1..100`), note that the host-config neutral quality default now applies as the base, with the URL `quality=N` still winning; and that the other neutral tunables are honored. State the same default-quality behavioral change as IIIF.

- [ ] **Step 4: Commit**

```bash
git add docs/imgproxy_support_matrix.md docs/iiif_3_support_matrix.md docs/twicpics_support_matrix.md
git commit -m "docs: record config threading + autoquality neutralization in support matrices

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Final gate

- [ ] **Run the full Elixir gate**

Run: `mise run precommit`
Expected: PASS — `mix format --check-formatted`, `mix compile --warnings-as-errors`, `mix credo --strict`, `mix test` all green.

If formatting fails, run `mise exec -- mix format` and amend the relevant commit. If a wire-test helper name guessed above does not match the real file, adjust the test to the file's established harness (the helper *names* are illustrative; the *assertions* — status, differing byte sizes, URL-wins — are the contract).

---

## Self-review notes (traceability to spec)

- Spec §1a → Task 1. §1b → Task 2 (incl. the `Plan` export + architecture-test edit the boundary reviewer flagged). imgproxy switchover §1b/§3 → Task 3.
- Spec §2 (`apply_to_output`) → Task 4. §3 (`reject_unsupported!` + eager `from_config` boot check) → Tasks 5/6/8.
- Spec §4 (IIIF) → Tasks 6-7. §5 (TwicPics) → Tasks 8-9. §6 (one `Plan` export; no dep/cache changes) → Task 2.
- Observable changes + conformance docs → Task 10.
- Out-of-scope (`autoquality_max_iterations`, imgproxy field-mapping, new URL surface, overlay content) → untouched, as specified.
