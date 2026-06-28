# Config Boundary Split Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Lift ImagePipe's product-neutral plan/output config into a new neutral `ImagePipe.Config` boundary with dialect parity overlays, and add a `jxl_effort` encode tunable — without touching IIIF/TwicPics and with zero behavior change today.

**Architecture:** `ImagePipe.Config` (deps `[Format, Plan]`) owns the neutral NimbleOptions schema (types only, no `default:`), the neutral default values, the shared range checks (using `Plan.Output.QualitySearch.Metric.target_range/1`), and a three-layer `resolve!/2` (`defaults ← overlay ← host`, presence-based scalars + `Map.merge` maps). The imgproxy adapter keeps only dialect keys + an (empty) overlay and reaches `Config` via its `Parser` ancestor dep. `jxl_effort` rides on `Plan.Output` as an optional field; `Output.Policy` fills its default from `Config.default/1`, threading it to the JXL encode suffix.

**Tech Stack:** Elixir, NimbleOptions, Boundary 0.10, ExUnit + StreamData, Vix/libvips (`jxlsave`).

**Spec:** `docs/superpowers/specs/2026-06-27-config-boundary-split-design.md`

**Conventions:**
- Run everything through `mise exec -- ...` (correct toolchain versions).
- TDD: failing test first, minimal impl, green, commit.
- Each task ends green. Commit messages use the repo's conventional style.

---

## File structure

- **Create:** `lib/image_pipe/config.ex` — neutral schema, defaults, range checks, `resolve!/2`, `keys/0`, `schema/0`, `default/1`.
- **Create:** `test/image_pipe/config_test.exs` — Config unit + property tests.
- **Modify:** `lib/image_pipe/parser/imgproxy.ex` — delete lifted neutral config; route neutral through `Config`; dialect-only schema + overlay.
- **Modify:** `lib/image_pipe/parser.ex` — add `ImagePipe.Config` to deps.
- **Modify:** `lib/image_pipe/plan/output.ex` — add `jxl_effort` field.
- **Modify:** `lib/image_pipe/output/resolved.ex` — add `jxl_effort` field.
- **Modify:** `lib/image_pipe/output/policy.ex` — carry + default-resolve `jxl_effort`.
- **Modify:** `lib/image_pipe/output.ex` — add `ImagePipe.Config` to deps.
- **Modify:** `lib/image_pipe/output/encoder.ex` — thread `jxl_effort` into the JXL suffix builders.
- **Modify:** `lib/image_pipe/output/native_jxl_search.ex` — carry `jxl_effort` to `encode_jxl_distance`.
- **Modify:** `lib/image_pipe/parser/imgproxy/parsed_request.ex` — add `jxl_effort` to the output request.
- **Modify:** `lib/image_pipe/parser/imgproxy/options.ex` — fold host `jxl_effort` into the output request.
- **Modify:** `lib/image_pipe/parser/imgproxy/plan_builder.ex` — map `jxl_effort` into `Plan.Output`.
- **Modify:** `lib/image_pipe/cache/key.ex` — add `jxl_effort` to the canonical output key data.
- **Modify:** `lib/image_pipe/request.ex` — add `ImagePipe.Config` to deps (permitted seam).
- **Modify:** `test/image_pipe/architecture_boundary_test.exs` — register Config; update Parser/Output/Request dep assertions.
- **Modify:** `test/image_pipe/cache/key_test.exs` — `jxl_effort` key sensitivity + `Plan.Output` field drift guard.
- **Modify:** `docs/imgproxy_support_matrix.md` — config-surface + behavioral divergence.

---

## Task 1: Create the `ImagePipe.Config` boundary

This task is purely additive — the imgproxy adapter still has its own copy of these values until Task 2, so behavior is unchanged. `Config` references `Plan.Output.QualitySearch.Metric` (exported by `Plan`).

**Files:**
- Create: `lib/image_pipe/config.ex`
- Create: `test/image_pipe/config_test.exs`
- Modify: `test/image_pipe/architecture_boundary_test.exs`

- [ ] **Step 1: Write the failing test**

Create `test/image_pipe/config_test.exs`:

```elixir
defmodule ImagePipe.ConfigTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias ImagePipe.Config

  describe "resolve!/2 layering" do
    test "applies neutral defaults when host and overlay are empty" do
      resolved = Config.resolve!([], [])
      assert resolved[:quality] == 80
      assert resolved[:auto_rotate] == true
      assert resolved[:preserve_hdr] == false
      assert resolved[:format_quality] == %{webp: 79, avif: 63, jpeg_xl: 77}
      assert resolved[:autoquality_method] == :none
      assert resolved[:autoquality_format_min_quality] == %{avif: 60, jpeg_xl: 45}
    end

    test "host overrides win over overlay which wins over defaults" do
      resolved = Config.resolve!([quality: 90], autoquality_method: :ssimulacra2, quality: 50)
      assert resolved[:quality] == 90
      assert resolved[:autoquality_method] == :ssimulacra2
    end

    test "a host-set boolean false survives (presence-based, not ||)" do
      resolved = Config.resolve!(strip_metadata: false, preserve_hdr: true)
      assert resolved[:strip_metadata] == false
      assert resolved[:preserve_hdr] == true
    end

    test "map keys merge across layers, keeping untouched formats" do
      resolved = Config.resolve!([format_quality: %{webp: 50}], format_quality: %{avif: 40})
      assert resolved[:format_quality] == %{webp: 50, avif: 40, jpeg_xl: 77}
    end

    test "jxl_effort is validated-if-present but not defaulted" do
      refute Keyword.has_key?(Config.resolve!([], []), :jxl_effort)
      assert Config.resolve!(jxl_effort: 4)[:jxl_effort] == 4
    end

    test "resolve! is idempotent" do
      once = Config.resolve!(quality: 90, format_quality: %{webp: 50}, jxl_effort: 4)
      assert Config.resolve!(once) == once
    end
  end

  describe "resolve!/2 range checks" do
    test "rejects out-of-range quality" do
      assert_raise ArgumentError, fn -> Config.resolve!(quality: 0) end
      assert_raise ArgumentError, fn -> Config.resolve!(quality: 101) end
    end

    test "rejects inverted effective autoquality bracket" do
      assert_raise ArgumentError, fn ->
        Config.resolve!(autoquality_min_quality: 80, autoquality_max_quality: 70)
      end
    end

    test "rejects an out-of-band ssimulacra2 target via Metric range" do
      assert_raise ArgumentError, fn ->
        Config.resolve!(autoquality_target: %{ssimulacra2: 150})
      end
    end

    test "rejects negative allowed_error and unsupported metric" do
      assert_raise ArgumentError, fn ->
        Config.resolve!(autoquality_allowed_error: %{ssimulacra2: -1})
      end

      assert_raise ArgumentError, fn ->
        Config.resolve!(autoquality_allowed_error: %{size: 1})
      end
    end

    test "rejects out-of-range jxl_effort" do
      assert_raise ArgumentError, fn -> Config.resolve!(jxl_effort: 0) end
      assert_raise ArgumentError, fn -> Config.resolve!(jxl_effort: 10) end
    end

    test "rejects unknown neutral keys" do
      assert_raise ArgumentError, fn -> Config.resolve!(bogus: 1) end
    end
  end

  describe "introspection" do
    test "keys/0 lists the neutral keys" do
      assert :quality in Config.keys()
      assert :jxl_effort in Config.keys()
      refute :signature in Config.keys()
    end

    test "default/1 exposes neutral defaults including jxl_effort" do
      assert Config.default(:jxl_effort) == 7
      assert Config.default(:quality) == 80
    end
  end

  property "scalar defaults survive when host omits them" do
    check all q <- integer(1..100) do
      resolved = Config.resolve!(quality: q)
      assert resolved[:quality] == q
      assert resolved[:auto_rotate] == true
    end
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mise exec -- mix test test/image_pipe/config_test.exs`
Expected: FAIL — `ImagePipe.Config` is undefined.

- [ ] **Step 3: Write the Config module**

Create `lib/image_pipe/config.ex`:

```elixir
defmodule ImagePipe.Config do
  @moduledoc """
  Product-neutral plan/output configuration: the schema, ImagePipe's default
  values, and the shared range checks for every tunable that is not specific to
  a dialect (imgproxy/IIIF/TwicPics). Dialect adapters validate their own keys and
  delegate the neutral keys here, so the whole plan/output layer is host-tunable
  from one schema and a drop-in provider inherits sensible defaults.

  The schema carries types only — **no `default:`**. Defaults live in
  `@scalar_defaults`/`@map_defaults`/`@default_jxl_effort` and are applied by
  `resolve!/2`, so a key can be validated without being force-defaulted
  (`jxl_effort`, whose default `Output` applies via `default/1`).
  """

  use Boundary, deps: [ImagePipe.Format, ImagePipe.Plan], exports: []

  alias ImagePipe.Plan.Output.QualitySearch.Metric

  @neutral_schema_kw [
    auto_rotate: [type: :boolean],
    strip_metadata: [type: :boolean],
    keep_copyright: [type: :boolean],
    quality: [type: :pos_integer],
    format_quality: [type: {:map, :atom, :pos_integer}],
    strip_color_profile: [type: :boolean],
    preserve_hdr: [type: :boolean],
    smart_crop_face_detection: [type: :boolean],
    autoquality_method: [type: {:in, [:none, :size, :ssimulacra2, :butteraugli]}],
    autoquality_target: [type: {:map, :atom, {:or, [:integer, :float]}}],
    autoquality_min_quality: [type: :pos_integer],
    autoquality_max_quality: [type: :pos_integer],
    autoquality_allowed_error: [type: {:map, :atom, {:or, [:integer, :float]}}],
    autoquality_format_min_quality: [type: {:map, :atom, :pos_integer}],
    autoquality_format_max_quality: [type: {:map, :atom, :pos_integer}],
    autoquality_max_resolution: [type: :non_neg_integer],
    autoquality_max_iterations: [type: :pos_integer],
    jxl_effort: [type: {:in, 1..9}]
  ]

  @schema NimbleOptions.new!(@neutral_schema_kw)
  @keys Keyword.keys(@neutral_schema_kw)

  # Defaults applied by resolve! (the parser bakes these into the Plan).
  @scalar_defaults [
    auto_rotate: true,
    strip_metadata: true,
    keep_copyright: true,
    strip_color_profile: true,
    preserve_hdr: false,
    smart_crop_face_detection: false,
    quality: 80,
    autoquality_method: :none,
    autoquality_min_quality: 70,
    autoquality_max_quality: 80,
    autoquality_max_resolution: 0,
    autoquality_max_iterations: 6
  ]

  @map_defaults [
    format_quality: %{webp: 79, avif: 63, jpeg_xl: 77},
    autoquality_target: %{},
    autoquality_allowed_error: %{},
    autoquality_format_min_quality: %{avif: 60, jpeg_xl: 45},
    autoquality_format_max_quality: %{avif: 65, jpeg_xl: 80}
  ]

  # jxl_effort is NOT applied by resolve! (Output resolves it from default/1); 7 is
  # libvips jxlsave's own default, so seeding 7 is byte-neutral vs emitting no effort.
  @default_jxl_effort 7

  @all_defaults @scalar_defaults ++ @map_defaults ++ [jxl_effort: @default_jxl_effort]
  @map_keys Keyword.keys(@map_defaults)

  @doc "The neutral schema (types only)."
  @spec schema() :: NimbleOptions.t()
  def schema, do: @schema

  @doc "The neutral config keys (adapters split neutral vs dialect opts with this)."
  @spec keys() :: [atom()]
  def keys, do: @keys

  @doc "ImagePipe's neutral default for a key."
  @spec default(atom()) :: term()
  def default(key), do: Keyword.fetch!(@all_defaults, key)

  @doc """
  Validate + resolve a host's neutral config against the three-layer chain
  (`defaults ← overlay ← host`). Returns a keyword of concrete neutral values,
  range-checked. `jxl_effort` is validated-if-present but not defaulted here.
  Raises `ArgumentError` on invalid input.
  """
  @spec resolve!(keyword(), keyword()) :: keyword()
  def resolve!(host_opts, overlay \\ []) when is_list(host_opts) and is_list(overlay) do
    host = validate_input!(host_opts)
    ov = validate_input!(overlay)

    resolved =
      (@scalar_defaults ++ @map_defaults)
      |> layer(ov)
      |> layer(host)

    range_check!(resolved)
    resolved
  end

  defp validate_input!(opts) do
    case NimbleOptions.validate(opts, @schema) do
      {:ok, validated} -> validated
      {:error, %NimbleOptions.ValidationError{} = error} ->
        raise ArgumentError, "invalid config: #{Exception.message(error)}"
    end
  end

  # Presence-based last-writer-wins for scalars; Map.merge for map-valued keys so a
  # sparse override keeps the other entries. Only keys PRESENT in `override` apply,
  # so a host-set `false` is honored (never collapses to a default).
  defp layer(base, override) do
    Enum.reduce(override, base, fn {key, value}, acc ->
      if key in @map_keys do
        Keyword.update(acc, key, value, &Map.merge(&1, value))
      else
        Keyword.put(acc, key, value)
      end
    end)
  end

  @quality_value_keys [:quality, :autoquality_min_quality, :autoquality_max_quality]
  @quality_map_keys [
    :format_quality,
    :autoquality_format_min_quality,
    :autoquality_format_max_quality
  ]

  defp range_check!(resolved) do
    Enum.each(@quality_value_keys, &validate_quality_value!(&1, Keyword.fetch!(resolved, &1)))
    Enum.each(@quality_map_keys, &validate_quality_map!(&1, Keyword.fetch!(resolved, &1)))
    validate_target!(Keyword.fetch!(resolved, :autoquality_target))
    validate_allowed_error!(Keyword.fetch!(resolved, :autoquality_allowed_error))
    validate_brackets!(resolved)
    :ok
  end

  defp validate_quality_value!(key, value) do
    unless value in 1..100 do
      raise ArgumentError, "invalid config: #{key} (#{value}) must be between 1 and 100"
    end
  end

  defp validate_quality_map!(key, map) do
    Enum.each(map, fn {format, q} ->
      unless q in 1..100 do
        raise ArgumentError,
              "invalid config: #{key} #{inspect(format)} (#{q}) must be between 1 and 100"
      end
    end)
  end

  @perceptual_metrics [:ssimulacra2, :butteraugli]

  defp validate_target!(target_map) do
    Enum.each(target_map, fn {metric, value} ->
      validate_target_metric!(metric, value)
    end)
  end

  defp validate_target_metric!(:size, value) do
    unless is_integer(value) and value > 0 do
      raise ArgumentError, "invalid config: autoquality_target :size (#{inspect(value)}) must be a positive integer"
    end
  end

  defp validate_target_metric!(metric, value) when metric in @perceptual_metrics do
    {lo, hi} = Metric.target_range(metric)

    unless is_number(value) and value >= lo and value <= hi do
      raise ArgumentError,
            "invalid config: autoquality_target #{inspect(metric)} (#{inspect(value)}) is out of range #{inspect({lo, hi})}"
    end
  end

  defp validate_target_metric!(metric, _value) do
    raise ArgumentError, "invalid config: autoquality_target has unknown metric #{inspect(metric)}"
  end

  defp validate_allowed_error!(error_map) do
    Enum.each(error_map, fn {metric, value} ->
      unless metric in @perceptual_metrics do
        raise ArgumentError,
              "invalid config: autoquality_allowed_error has unsupported metric #{inspect(metric)} (only :ssimulacra2/:butteraugli)"
      end

      unless is_number(value) and value >= 0 do
        raise ArgumentError,
              "invalid config: autoquality_allowed_error #{inspect(metric)} (#{inspect(value)}) must be a non-negative number"
      end
    end)
  end

  defp validate_brackets!(resolved) do
    base_min = Keyword.fetch!(resolved, :autoquality_min_quality)
    base_max = Keyword.fetch!(resolved, :autoquality_max_quality)
    format_min = Keyword.fetch!(resolved, :autoquality_format_min_quality)
    format_max = Keyword.fetch!(resolved, :autoquality_format_max_quality)

    if base_min > base_max do
      raise ArgumentError,
            "invalid config: autoquality_min_quality (#{base_min}) exceeds autoquality_max_quality (#{base_max})"
    end

    format_min
    |> Map.keys()
    |> Enum.concat(Map.keys(format_max))
    |> Enum.uniq()
    |> Enum.each(fn format ->
      effective_min = Map.get(format_min, format, base_min)
      effective_max = Map.get(format_max, format, base_max)

      if effective_min > effective_max do
        raise ArgumentError,
              "invalid config: effective autoquality bracket for #{inspect(format)} is inverted " <>
                "(min #{effective_min} > max #{effective_max})"
      end
    end)

    :ok
  end
end
```

- [ ] **Step 4: Run test to verify it passes**

Run: `mise exec -- mix test test/image_pipe/config_test.exs`
Expected: PASS (all cases).

- [ ] **Step 5: Add the Config boundary architecture test**

In `test/image_pipe/architecture_boundary_test.exs`, register Config in the `@boundary_files` map (alongside the other entries):

```elixir
ImagePipe.Config => "lib/image_pipe/config.ex",
```

Add a test asserting Config's exact boundary (follow the existing `assert_boundary_deps`/`assert_boundary_exports` pattern used for `Plan`/`Output`):

```elixir
test "ImagePipe.Config depends only on Format and Plan, exports nothing" do
  declaration = boundary_declaration(ImagePipe.Config)
  assert_boundary_deps(declaration, [ImagePipe.Format, ImagePipe.Plan])
  assert_boundary_exports(declaration, [])
  refute_boundary_deps(declaration, [
    ImagePipe.Parser,
    ImagePipe.Output,
    ImagePipe.Request,
    ImagePipe.Cache
  ])
end
```

- [ ] **Step 6: Run the architecture test**

Run: `mise exec -- mix test test/image_pipe/architecture_boundary_test.exs`
Expected: PASS.

- [ ] **Step 7: Compile with warnings-as-errors + commit**

Run: `mise exec -- mix compile --warnings-as-errors && mise exec -- mix credo --strict`
Expected: clean.

```bash
git add lib/image_pipe/config.ex test/image_pipe/config_test.exs test/image_pipe/architecture_boundary_test.exs
git commit -m "feat(config): add neutral ImagePipe.Config boundary (#418)"
```

---

## Task 2: Route the imgproxy adapter through `Config`

Behavior-preserving lift: delete the neutral config from the adapter, validate dialect keys against a shrunk schema, and delegate neutral keys to `Config.resolve!/2`. The adapter reaches `Config` via the `Parser` ancestor dep, so only the top-level `ImagePipe.Parser` boundary gains the dep — **not** the adapter's own.

**Files:**
- Modify: `lib/image_pipe/parser/imgproxy.ex`
- Modify: `lib/image_pipe/parser.ex`
- Modify: `test/image_pipe/architecture_boundary_test.exs`

- [ ] **Step 1: Run the existing imgproxy config tests to capture the green baseline**

Run: `mise exec -- mix test test/image_pipe/imgproxy_wire_conformance_test.exs`
Expected: PASS. These are the behavior-preserving guard for this task — they must stay green.

- [ ] **Step 2: Add `Config` to the top-level `Parser` boundary deps**

In `lib/image_pipe/parser.ex`, add `ImagePipe.Config` to the `deps:` list (keep the list sorted as the file does):

```elixir
use Boundary,
  deps: [ImagePipe.Config, ImagePipe.Format, ImagePipe.Plan, ImagePipe.Renderer],
  exports: []
```

- [ ] **Step 3: Replace the neutral config in `imgproxy.ex` with dialect-only + Config delegation**

In `lib/image_pipe/parser/imgproxy.ex`:

Delete the neutral default module attributes (`@default_auto_rotate` … `@default_autoquality_format_max`), the `@merged_map_defaults`, **and the three range-check attributes `@quality_value_keys`, `@quality_map_keys`, `@autoquality_metrics`** (they are referenced only by the deleted functions; leaving them orphaned trips Elixir's "unused module attribute" warning → fails `--warnings-as-errors`). Delete the neutral entries of `@imgproxy_schema`, `merge_map_defaults/1`, `merge_map_default/3`, `validate_quality_config!` and all its helpers (`validate_quality_value!`, `validate_quality_map!`, `validate_autoquality_target_config!`, `valid_target_value?`, `validate_autoquality_allowed_error_config!`), and `validate_autoquality_brackets!`.

Replace the schema with a dialect-only schema and add the overlay + key list:

```elixir
@dialect_schema NimbleOptions.new!(
                  signature: [type: :keyword_list, required: false],
                  source_url_encryption_key: [
                    type: {:custom, SourceEncryption, :validate_key, []},
                    required: false
                  ],
                  base64_url_includes_filename: [type: :boolean, default: false],
                  source_schemes: [
                    type: {:custom, __MODULE__, :validate_source_schemes, []},
                    default: %{}
                  ],
                  presets: [type: {:custom, Presets, :validate_config, []}, default: %{}]
                )

@dialect_keys [
  :signature,
  :source_url_encryption_key,
  :base64_url_includes_filename,
  :source_schemes,
  :presets
]

# Sparse parity overrides on top of the neutral defaults. EMPTY today
# ("imgproxy parity == neutral defaults"); `jxl_effort: 4` is the documented future
# byte-parity lever, intentionally not set here.
defp imgproxy_overlay, do: []
```

Rewrite `validate_imgproxy_options!/1`:

```elixir
defp validate_imgproxy_options!(imgproxy_opts) when is_list(imgproxy_opts) do
  {neutral, rest} = Keyword.split(imgproxy_opts, ImagePipe.Config.keys())
  {dialect, unknown} = Keyword.split(rest, @dialect_keys)

  unless unknown == [] do
    raise ArgumentError, "invalid imgproxy config: unknown keys #{inspect(Keyword.keys(unknown))}"
  end

  dialect = validate_dialect!(dialect)
  neutral = ImagePipe.Config.resolve!(neutral, imgproxy_overlay())

  Keyword.merge(neutral, dialect)
end

defp validate_imgproxy_options!(_imgproxy_opts),
  do: raise(ArgumentError, "invalid imgproxy options: expected a keyword list")

defp validate_dialect!(dialect) do
  case NimbleOptions.validate(dialect, @dialect_schema) do
    {:ok, validated} ->
      validated
      |> Keyword.update(:signature, Signature.disabled(), &Signature.normalize_config!/1)
      |> normalize_source_encryption()

    {:error, %NimbleOptions.ValidationError{} = error} ->
      raise ArgumentError, "invalid imgproxy config: #{Exception.message(error)}"
  end
end
```

Rewrite `request_defaults/1` to route the neutral subset through `Config` (covers the direct-parse path; idempotent with `validate_options!`). Keep the `jxl_effort` pass-through (no default applied):

```elixir
defp request_defaults(imgproxy_opts) do
  {neutral, _rest} = Keyword.split(imgproxy_opts, ImagePipe.Config.keys())
  ImagePipe.Config.resolve!(neutral, imgproxy_overlay())
end
```

Leave `source_parsing_config/1`, `signature_config/1`, `preset_config/1`, `normalize_source_encryption/1`, `validate_source_schemes/1`, and the parse paths unchanged.

- [ ] **Step 4: Run the imgproxy + parser tests**

Run: `mise exec -- mix test test/image_pipe/imgproxy_wire_conformance_test.exs test/image_pipe/parser`
Expected: PASS — behavior unchanged. If a test asserts on a private imgproxy error string for a neutral key (e.g. `"invalid imgproxy config: quality ..."`), prefer **loosening** it to assert the raise (`assert_raise ArgumentError, fn -> ... end`) rather than re-pinning the new neutral string — per AGENTS.md "No private-implementation tests." Only update the literal if the test genuinely must pin the message.

- [ ] **Step 5: Update the Parser boundary dep assertions (TWO sites)**

In `test/image_pipe/architecture_boundary_test.exs`, add `ImagePipe.Config` to the `ImagePipe.Parser` deps in **both** assertions (both compare against a sorted list, so Config sorts first):
- `assert_boundary_deps(parser, [...])` (~L107): `[ImagePipe.Format, ImagePipe.Plan, ImagePipe.Renderer]` → `[ImagePipe.Config, ImagePipe.Format, ImagePipe.Plan, ImagePipe.Renderer]`.
- `assert_allowed_deps(parser, [...])` (~L134): same list — add `ImagePipe.Config` here too, or the `unexpected_deps` check fails (Config is now a real Parser dep).

**Do not** change the imgproxy/IIIF/TwicPics adapter dep assertions (~L113-150) — they reach Config via the `ImagePipe.Parser` ancestor and keep their own `deps:` Config-free.

- [ ] **Step 6: Full gate + commit**

Run: `mise exec -- mix compile --warnings-as-errors && mise exec -- mix credo --strict && mise exec -- mix test test/image_pipe/architecture_boundary_test.exs`
Expected: clean / PASS.

```bash
git add lib/image_pipe/parser/imgproxy.ex lib/image_pipe/parser.ex test/image_pipe/architecture_boundary_test.exs
git commit -m "refactor(imgproxy): delegate neutral plan/output config to ImagePipe.Config (#418)"
```

---

## Task 3: Add the optional `jxl_effort` field to `Plan.Output`

**Files:**
- Modify: `lib/image_pipe/plan/output.ex`
- Test: `test/image_pipe/plan/output_test.exs` (or add to the existing Plan.Output test if present)

- [ ] **Step 1: Write the failing test**

Add to `test/image_pipe/plan/output_test.exs` (create the file if it does not exist, with the standard `defmodule ... use ExUnit.Case, async: true`):

```elixir
test "Plan.Output carries an optional jxl_effort (nil = use neutral default)" do
  assert %ImagePipe.Plan.Output{mode: :automatic}.jxl_effort == nil
  assert %ImagePipe.Plan.Output{mode: :automatic, jxl_effort: 4}.jxl_effort == 4
end
```

- [ ] **Step 2: Run to verify it fails**

Run: `mise exec -- mix test test/image_pipe/plan/output_test.exs`
Expected: FAIL — unknown key `:jxl_effort`.

- [ ] **Step 3: Add the field**

In `lib/image_pipe/plan/output.ex`, add `jxl_effort: nil` to the `defstruct` list and `jxl_effort: nil | 1..9` to `@type t`. Add a moduledoc sentence:

```
`jxl_effort` (1–9) is the JPEG XL encode effort. It is optional (`nil` = unset):
unlike `quality`, its neutral default is resolved by `ImagePipe.Output` from
`ImagePipe.Config.default(:jxl_effort)`, so a hand-built plan inherits it.
```

defstruct addition:

```elixir
            max_bytes: nil,
            quality_search_offsets: @default_quality_search_offsets,
            jxl_effort: nil
```

@type addition:

```elixir
          max_bytes: nil | pos_integer(),
          quality_search_offsets: quality_search_offsets(),
          jxl_effort: nil | 1..9
```

- [ ] **Step 4: Run to verify it passes**

Run: `mise exec -- mix test test/image_pipe/plan/output_test.exs`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add lib/image_pipe/plan/output.ex test/image_pipe/plan/output_test.exs
git commit -m "feat(plan): add optional Output.jxl_effort field (#418)"
```

---

## Task 4: Resolve the `jxl_effort` default in `Output.Policy` → `Output.Resolved`

`Output` gains the `Config` dep here (its genuine caller). `Policy` fills `output.jxl_effort || Config.default(:jxl_effort)` (the value is `nil` or a `1..9` integer, so `||` is correct — no boolean/zero trap). `Resolved.jxl_effort` defaults to `nil` so existing `%Resolved{}` test builders don't break; the encoder (Task 5) treats `nil` as "omit effort" (= libvips default 7).

**Files:**
- Modify: `lib/image_pipe/output.ex`
- Modify: `lib/image_pipe/output/policy.ex`
- Modify: `lib/image_pipe/output/resolved.ex`
- Modify: `test/image_pipe/architecture_boundary_test.exs`
- Test: `test/image_pipe/output/policy_test.exs`

- [ ] **Step 1: Write the failing test**

Add to `test/image_pipe/output/policy_test.exs`:

```elixir
test "resolved jxl_effort falls back to the Config default when unset" do
  conn = Plug.Test.conn(:get, "/")
  plan = %ImagePipe.Plan.Output{mode: {:explicit, :jpeg_xl}, jxl_effort: nil}
  policy = ImagePipe.Output.Policy.from_output_plan(conn, plan, [])
  {:ok, resolved} = ImagePipe.Output.Policy.resolve(policy, :jpeg_xl)
  assert resolved.jxl_effort == ImagePipe.Config.default(:jxl_effort)
end

test "an explicit Plan jxl_effort overrides the default" do
  conn = Plug.Test.conn(:get, "/")
  plan = %ImagePipe.Plan.Output{mode: {:explicit, :jpeg_xl}, jxl_effort: 4}
  policy = ImagePipe.Output.Policy.from_output_plan(conn, plan, [])
  {:ok, resolved} = ImagePipe.Output.Policy.resolve(policy, :jpeg_xl)
  assert resolved.jxl_effort == 4
end
```

- [ ] **Step 2: Run to verify it fails**

Run: `mise exec -- mix test test/image_pipe/output/policy_test.exs`
Expected: FAIL — `Resolved` / `Policy` has no `jxl_effort` (KeyError), or `Config` not a dep (boundary error).

- [ ] **Step 3: Add the Config dep to Output**

In `lib/image_pipe/output.ex`, add `ImagePipe.Config` to `deps:` (keep sorted):

```elixir
deps: [ImagePipe.Config, ImagePipe.Format, ImagePipe.Plan, ImagePipe.Telemetry],
```

- [ ] **Step 4: Carry + default-resolve jxl_effort in Policy**

In `lib/image_pipe/output/policy.ex`:

Add `jxl_effort` to the Policy `defstruct` (with the other defaults) and to `@type t`. The struct default is `nil` (not `7`) — `from_output_plan/3` always resolves it to a concrete value via `Config.default/1`, so `7` stays single-sourced in `Config`:

```elixir
                quality_search_offsets: Output.default_quality_search_offsets(),
                jxl_effort: nil
```

```elixir
          quality_search_offsets: Output.quality_search_offsets(),
          jxl_effort: nil | 1..9
```

In **both** `from_output_plan/3` clauses, add (after `quality_search_offsets:`):

```elixir
      jxl_effort: output.jxl_effort || ImagePipe.Config.default(:jxl_effort)
```

In `resolved/2`, add to the `%Resolved{}` (after `max_bytes:`):

```elixir
      max_bytes: policy.max_bytes,
      jxl_effort: policy.jxl_effort
```

- [ ] **Step 5: Add the field to Resolved**

In `lib/image_pipe/output/resolved.ex`, add `jxl_effort: nil` to the `defstruct` extra-keys list and `jxl_effort: nil | 1..9` to `@type t`:

```elixir
  defstruct @enforce_keys ++
              [flatten_background: Color.white(), quality_search: :none, max_bytes: nil, jxl_effort: nil]
```

```elixir
          max_bytes: nil | pos_integer(),
          jxl_effort: nil | 1..9
```

- [ ] **Step 6: Run to verify it passes**

Run: `mise exec -- mix test test/image_pipe/output/policy_test.exs`
Expected: PASS.

- [ ] **Step 7: Update the Output boundary dep assertion**

In `test/image_pipe/architecture_boundary_test.exs`, add `ImagePipe.Config` to the `ImagePipe.Output` `assert_boundary_deps` (~L395): `[ImagePipe.Format, ImagePipe.Plan, ImagePipe.Telemetry]` → `[ImagePipe.Config, ImagePipe.Format, ImagePipe.Plan, ImagePipe.Telemetry]`. The Output `refute_boundary_deps` (~L397) does not list Config and stays unchanged.

- [ ] **Step 8: Gate + commit**

Run: `mise exec -- mix compile --warnings-as-errors && mise exec -- mix credo --strict && mise exec -- mix test test/image_pipe/architecture_boundary_test.exs test/image_pipe/output`
Expected: clean / PASS.

```bash
git add lib/image_pipe/output.ex lib/image_pipe/output/policy.ex lib/image_pipe/output/resolved.ex test/image_pipe/output/policy_test.exs test/image_pipe/architecture_boundary_test.exs
git commit -m "feat(output): resolve jxl_effort from Config default into Resolved (#418)"
```

---

## Task 5: Thread `jxl_effort` into the JXL encode suffixes

Add `effort` args to the leaf suffix builders and carry it through both delivery paths (search-leg `encode_to_buffer/3`, non-search `lazy_output/5`) and the native-distance chain. `nil` effort omits the token (= libvips default 7), so production (always a concrete effort from Policy) emits `effort=`, while `%Resolved{}` builders that omit it stay byte-neutral.

**Files:**
- Modify: `lib/image_pipe/output/encoder.ex`
- Modify: `lib/image_pipe/output/native_jxl_search.ex`
- Test: `test/image_pipe/output/encoder_test.exs`

- [ ] **Step 1: Write the failing test**

Add to `test/image_pipe/output/encoder_test.exs` a suffix-shape test. The suffix builder is private, so assert through the public encode path on a tiny image and compare bytes (effort 4 vs default differ; default == no-effort baseline). Use the project's existing JXL test image helper if one exists; otherwise build a 2×2 image:

```elixir
test "jxl_effort changes encoded bytes; default 7 matches no-effort baseline" do
  {:ok, image} = Vix.Vips.Operation.black(8, 8)

  resolved = fn effort ->
    %ImagePipe.Output.Resolved{
      format: :jpeg_xl,
      quality: {:quality, 80},
      response_headers: [],
      strip_metadata: true,
      keep_copyright: true,
      color_profile: :strip,
      jxl_effort: effort
    }
  end

  {:ok, default_bytes} = ImagePipe.Output.Encoder.encode_to_buffer(image, resolved.(7), 80)
  {:ok, nil_bytes} = ImagePipe.Output.Encoder.encode_to_buffer(image, resolved.(nil), 80)
  {:ok, effort4_bytes} = ImagePipe.Output.Encoder.encode_to_buffer(image, resolved.(4), 80)

  assert default_bytes == nil_bytes
  refute default_bytes == effort4_bytes
end
```

- [ ] **Step 2: Run to verify it fails**

Run: `mise exec -- mix test test/image_pipe/output/encoder_test.exs`
Expected: FAIL — `encode_to_buffer/3` ignores effort, so all three byte blobs are equal.

- [ ] **Step 3: Rewrite the suffix builders to take effort**

In `lib/image_pipe/output/encoder.ex`, replace the four `jxl_vix_suffix/1` clauses (lines ~179-182) with an effort-aware builder:

```elixir
defp jxl_vix_suffix(quality, effort) do
  case Enum.reject([quality_token(quality), effort_token(effort)], &is_nil/1) do
    [] -> ".jxl"
    tokens -> ".jxl[" <> Enum.join(tokens, ",") <> "]"
  end
end

defp quality_token(:default), do: nil
defp quality_token({:quality, value}), do: "Q=#{value}"
defp quality_token({:distance, value}), do: "distance=#{value}"
defp quality_token(value) when is_integer(value), do: "Q=#{value}"

defp effort_token(nil), do: nil
defp effort_token(effort) when is_integer(effort), do: "effort=#{effort}"
```

Update `encode_jxl_buffer/2` → `/3` and `encode_jxl_distance/2` → `/3`:

```elixir
defp encode_jxl_buffer(%VixImage{} = image, quality, effort) do
  case VixImage.write_to_buffer(image, jxl_vix_suffix(quality, effort)) do
    {:ok, binary} -> {:ok, binary}
    {:error, reason} -> {:error, {:encode, encode_error(reason), []}}
  end
rescue
  exception -> {:error, {:encode, exception, __STACKTRACE__}}
end
```

```elixir
@spec encode_jxl_distance(VixImage.t(), number(), nil | 1..9) :: {:ok, binary()} | {:error, term()}
def encode_jxl_distance(%VixImage{} = image, distance, effort) do
  case VixImage.write_to_buffer(image, jxl_vix_suffix({:distance, distance}, effort)) do
    {:ok, binary} -> {:ok, binary}
    {:error, reason} -> {:error, {:encode, encode_error(reason), []}}
  end
rescue
  exception -> {:error, {:encode, exception, __STACKTRACE__}}
end
```

Update the `encode_to_buffer/3` JXL clause (line ~136) to read effort off the resolved:

```elixir
def encode_to_buffer(%VixImage{} = image, %Resolved{format: :jpeg_xl} = resolved, quality),
  do: encode_jxl_buffer(image, quality, resolved.jxl_effort)
```

Update the `lazy_output/5` JXL clause (lines ~67-78) to capture and pass effort:

```elixir
defp lazy_output(
       finalized,
       %Resolved{format: :jpeg_xl, quality: quality, jxl_effort: effort},
       mime_type,
       _suffix,
       _opts
     ) do
  case encode_jxl_buffer(finalized, quality, effort) do
    {:ok, binary} -> {:ok, [binary], mime_type, nil}
    {:error, _reason} = err -> err
  end
end
```

- [ ] **Step 4: Thread effort through the native-distance chain**

In `lib/image_pipe/output/native_jxl_search.ex`, carry `resolved.jxl_effort` from `run/3` down to `encode_jxl_distance/3`. Update the call in `run/3`:

```elixir
native_jxl_butteraugli(image, nqs, resolved.max_bytes, resolved.jxl_effort, telemetry_opts)
```

Update `native_jxl_butteraugli/4` → `/5` to accept `effort` and pass it to `native_encode`; update `native_encode/3` → `/4` and `native_descend/3` → `/4` to accept and forward `effort`:

```elixir
defp native_encode(image, distance, effort, nil) do
  with {:ok, bin} <- Encoder.encode_jxl_distance(image, distance, effort) do
    {:ok, bin, native_meta(bin, :native, nil)}
  end
end

defp native_encode(image, distance, effort, max_bytes) do
  native_descend(image, distance, effort, max_bytes)
end

defp native_descend(image, distance, effort, max_bytes) do
  with {:ok, bin} <- Encoder.encode_jxl_distance(image, distance, effort) do
    cond do
      byte_size(bin) <= max_bytes ->
        {:ok, bin, native_meta(bin, :native, nil)}

      distance >= @native_distance_max ->
        {:ok, bin, native_meta(bin, :best_effort, :max_bytes)}

      true ->
        native_descend(image, min(@native_distance_max, distance * 1.5 + 0.5), effort, max_bytes)
    end
  end
end
```

The **only** changes vs the current file are the new `effort` parameter and passing it to `encode_jxl_distance/3`. The `native_meta(bin, :native, nil)` (success, both branches) and `native_meta(bin, :best_effort, :max_bytes)` (distance-ceiling) calls are the file's existing shapes — do **not** alter the `outcome`/`limiting_factor` atoms (changing them would silently mutate the `[:encode, :search]` telemetry).

- [ ] **Step 5: Run to verify it passes**

Run: `mise exec -- mix test test/image_pipe/output/encoder_test.exs`
Expected: PASS.

- [ ] **Step 6: Audit test call sites for the changed public arities**

`encode_jxl_distance/2` became `/3`. Grep for direct test callers and update them (pass an `effort` arg — `nil` is fine):

Run: `grep -rn "encode_jxl_distance\|encode_jxl_buffer" test/`
Expected: update any direct call to the new arity. (`encode_to_buffer/3` keeps its arity; a `%Resolved{}` test builder that omits `jxl_effort` defaults to `nil` → still valid.)

- [ ] **Step 7: Confirm the native JXL search still works**

Run: `mise exec -- mix test test/image_pipe/output`
Expected: PASS (native butteraugli search path included).

- [ ] **Step 8: Gate + commit**

Run: `mise exec -- mix compile --warnings-as-errors && mise exec -- mix credo --strict`
Expected: clean.

```bash
git add lib/image_pipe/output/encoder.ex lib/image_pipe/output/native_jxl_search.ex test/image_pipe/output/encoder_test.exs
git commit -m "feat(output): thread jxl_effort into JXL encode suffixes (#418)"
```

---

## Task 6: Thread host `jxl_effort` from the imgproxy parser into `Plan.Output`

When a host configures `jxl_effort`, `Config.resolve!` passes it through; the parser must land it on `Plan.Output.jxl_effort`. When unset, it stays `nil` (Output applies the default).

**Files:**
- Modify: `lib/image_pipe/parser/imgproxy/parsed_request.ex`
- Modify: `lib/image_pipe/parser/imgproxy/options.ex`
- Modify: `lib/image_pipe/parser/imgproxy/plan_builder.ex`
- Test: `test/image_pipe/imgproxy_resize_auto_test.exs` (plan-level — **not** the wire-conformance file, which is for user-visible wire contracts only)

- [ ] **Step 1: Write the failing test**

This is a plan-struct assertion, so it belongs in a plan-level parser test, not the wire-level conformance file. `imgproxy_resize_auto_test.exs` already uses the idiomatic path→plan pattern — `ImagePipe.Parser.Imgproxy.parse(conn, opts)` returns `{:ok, %Plan{}}`. Add (use `import Plug.Test` / `alias ImagePipe.Parser.Imgproxy` per the file's existing setup; host config goes under the `:imgproxy` key):

```elixir
test "host jxl_effort lands on Plan.Output.jxl_effort; unset stays nil" do
  conn = conn(:get, "/_/plain/images/cat.jpg@jxl")

  assert {:ok, plan} = Imgproxy.parse(conn, imgproxy: [jxl_effort: 4])
  assert plan.output.jxl_effort == 4

  assert {:ok, plan_default} = Imgproxy.parse(conn(:get, "/_/plain/images/cat.jpg@jxl"), [])
  assert plan_default.output.jxl_effort == nil
end
```

If `imgproxy_resize_auto_test.exs` does not already alias `Imgproxy` / import `Plug.Test`, add those, or mirror its existing `parse_plan!/1`-style helper (`conn(:get, path)` → `Imgproxy.parse(conn, opts)`).

- [ ] **Step 2: Run to verify it fails**

Run: `mise exec -- mix test test/image_pipe/imgproxy_resize_auto_test.exs`
Expected: FAIL — `plan.output.jxl_effort` is always `nil` (parser drops it).

- [ ] **Step 3: Add jxl_effort to the output request**

In `lib/image_pipe/parser/imgproxy/parsed_request.ex`, add `jxl_effort: nil` to `@default_output` and `required(:jxl_effort) => 1..9 | nil` to the `output_request()` type.

- [ ] **Step 4: Fold the host default into the output request**

In `lib/image_pipe/parser/imgproxy/options.ex`, inside `apply_request_defaults/2`, add a fold for `jxl_effort` in the output pipeline (after `resolve_quality_search_defaults`):

```elixir
    with {:ok, output} <-
           output
           |> resolve_metadata_defaults(defaults)
           |> Map.put(:strip_color_profile, strip_color_profile?)
           |> Map.put(:color_profile, color_profile)
           |> resolve_quality_defaults(defaults)
           |> resolve_quality_search_defaults(defaults) do
      output = Map.put(output, :jxl_effort, Keyword.get(defaults, :jxl_effort))

      options =
        options
        |> Map.put(:auto_rotate, auto_rotate?)
        |> Map.merge(%{pipelines: pipelines, output: output})

      {:ok, options}
    end
```

(`Keyword.get(defaults, :jxl_effort)` is `nil` when the host did not set it — exactly the unset sentinel.)

- [ ] **Step 5: Map it into Plan.Output**

In `lib/image_pipe/parser/imgproxy/plan_builder.ex`, add `jxl_effort: request.jxl_effort` to **both** `output_plan/1` clauses (`%{format: nil}` and `%{format: format}`):

```elixir
       color_profile: color_profile_policy(request.color_profile, request.strip_color_profile),
       hdr: hdr_policy(request.preserve_hdr),
       jxl_effort: request.jxl_effort
```

- [ ] **Step 6: Run to verify it passes**

Run: `mise exec -- mix test test/image_pipe/imgproxy_resize_auto_test.exs`
Expected: PASS.

- [ ] **Step 7: Gate + commit**

Run: `mise exec -- mix compile --warnings-as-errors && mise exec -- mix credo --strict`
Expected: clean.

```bash
git add lib/image_pipe/parser/imgproxy/parsed_request.ex lib/image_pipe/parser/imgproxy/options.ex lib/image_pipe/parser/imgproxy/plan_builder.ex test/image_pipe/imgproxy_resize_auto_test.exs
git commit -m "feat(imgproxy): thread host jxl_effort into Plan.Output (#418)"
```

---

## Task 7: Add `jxl_effort` to the canonical cache-key output data

`jxl_effort` changes stored bytes, so it is storage identity — it must enter the key (and ETag) per the `max_resolution` precedent (`cache/key.ex:152-157`), or a host `7→4` change could serve stale bytes via a cache hit/`304`.

**Files:**
- Modify: `lib/image_pipe/cache/key.ex`
- Test: `test/image_pipe/cache/key_test.exs`

- [ ] **Step 1: Write the failing test**

Add to `test/image_pipe/cache/key_test.exs` (mirror the existing `"different output metadata flags change cache key"` test at line ~1140):

```elixir
test "different jxl_effort changes the cache key" do
  conn = conn(:get, "/_/f:jxl/plain/images/cat.jpg")

  key_a =
    build_key!(conn, plan(output: %Output{mode: {:explicit, :jpeg_xl}, jxl_effort: 7}), source_identity())

  key_b =
    build_key!(conn, plan(output: %Output{mode: {:explicit, :jpeg_xl}, jxl_effort: 4}), source_identity())

  refute key_a.hash == key_b.hash, "expected differing jxl_effort to change the cache key"
end
```

- [ ] **Step 2: Run to verify it fails**

Run: `mise exec -- mix test test/image_pipe/cache/key_test.exs`
Expected: FAIL — keys equal (jxl_effort not in key data).

- [ ] **Step 3: Add jxl_effort to the output key data**

In `lib/image_pipe/cache/key.ex`, add `jxl_effort: output.jxl_effort` to the keyword in **both** `output_plan_data/2` clauses (`:automatic` and `{:explicit, _}`), after `flatten_background:`:

```elixir
       flatten_background: Color.key_data(output.flatten_background),
       jxl_effort: output.jxl_effort
```

(`output_data/3`'s `:automatic` clause builds its own keyword — add the same line there too; the `nil`/`%Output{}` clauses delegate to `output_plan_data/2` and need no change.)

- [ ] **Step 4: Run to verify it passes**

Run: `mise exec -- mix test test/image_pipe/cache/key_test.exs`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add lib/image_pipe/cache/key.ex test/image_pipe/cache/key_test.exs
git commit -m "feat(cache): include jxl_effort in the canonical output key data (#418)"
```

---

## Task 8: `Plan.Output` cache-key drift guard

A completeness test so the *next* byte-affecting `Plan.Output` field can't silently miss the key. Operations already self-describe via `Plan.KeyData`; this guard is the interim safety net until the deferred `Plan.Output → Plan.KeyData` relocation (separate follow-up).

**Files:**
- Test: `test/image_pipe/cache/key_test.exs`

- [ ] **Step 1: Write the drift guard test**

Add to `test/image_pipe/cache/key_test.exs`:

```elixir
test "every Plan.Output field is accounted for in the cache key (drift guard)" do
  # Fields whose key contribution is carried elsewhere or deliberately excluded,
  # each with a rationale. Adding an Output field forces a decision here.
  excluded = %{
    # `mode` selects the `:automatic`/`:explicit` key shape itself, not a field value.
    mode: "drives key-data clause selection",
    # offsets only bias the search ESTIMATE; the resolved searched quality is what
    # changes bytes and is already keyed via quality_search.
    quality_search_offsets: "subsumed by the resolved quality_search",
    # the global default only seeds quality resolution; its byte effect is carried
    # into the key by the resolved `quality`/`format_qualities`, never independently.
    default_quality: "subsumed by resolved quality/format_qualities"
  }

  conn = conn(:get, "/_/f:webp/plain/images/cat.jpg")
  key_data =
    build_key!(conn, plan(output: %Output{mode: {:explicit, :webp}}), source_identity()).data[:output]

  keyed = key_data |> Keyword.keys() |> MapSet.new()

  for {field, _} <- Map.from_struct(%Output{mode: :automatic}), field != :mode do
    assert MapSet.member?(keyed, field) or Map.has_key?(excluded, field),
           "Plan.Output field #{inspect(field)} is neither in the cache key nor in the " <>
             "excluded-with-rationale list. Add it to output_plan_data/2 or document why it " <>
             "does not affect stored bytes."
  end
end
```

The `Plan.Output` field names match their keyed names one-to-one in `output_plan_data/2` (`format_qualities`, `color_profile`, `hdr`, `flatten_background`, `quality_search`, etc.), so no field→key rename mapping is needed. The only fields not directly keyed are `mode`, `quality_search_offsets`, and `default_quality` — all three are in `excluded` above. If the implementer finds `default_quality`'s rationale doesn't hold, add it to `output_plan_data/2` instead; either way the guard forces the decision.

- [ ] **Step 2: Run the guard**

Run: `mise exec -- mix test test/image_pipe/cache/key_test.exs`
Expected: PASS. If it fails, the failure names a `Plan.Output` field with no key decision — either add it to `output_plan_data/2` or to `excluded` with a rationale.

- [ ] **Step 3: Commit**

```bash
git add test/image_pipe/cache/key_test.exs
git commit -m "test(cache): drift guard for Plan.Output cache-key coverage (#418)"
```

---

## Task 9: Declare the `Request → Config` seam dep

`Request` has no `Config` caller in this cut, but the settled architecture declares the permitted seam ahead of the consumer (native request API). Boundary 0.10 does not flag unused `deps:`.

**Files:**
- Modify: `lib/image_pipe/request.ex`
- Modify: `test/image_pipe/architecture_boundary_test.exs`

- [ ] **Step 1: Add the dep**

In `lib/image_pipe/request.ex`, add `ImagePipe.Config` to the `deps:` list (keep the file's ordering).

- [ ] **Step 2: Update the Request boundary dep assertion**

In `test/image_pipe/architecture_boundary_test.exs`, add `ImagePipe.Config` to the `ImagePipe.Request` `assert_boundary_deps` list (~L156): currently `[ImagePipe.Cache, ImagePipe.Debug, ImagePipe.Error, ImagePipe.Format, ImagePipe.MaterialDigest, ImagePipe.Output, ImagePipe.Plan, ImagePipe.Renderer, ImagePipe.Response, ImagePipe.Source, ImagePipe.Telemetry, ImagePipe.Transform]` → add `ImagePipe.Config` (sorts first).

- [ ] **Step 3: Compile + run the architecture test**

Run: `mise exec -- mix compile --warnings-as-errors && mise exec -- mix test test/image_pipe/architecture_boundary_test.exs`
Expected: clean / PASS (no unused-dep error).

- [ ] **Step 4: Commit**

```bash
git add lib/image_pipe/request.ex test/image_pipe/architecture_boundary_test.exs
git commit -m "chore(request): declare Request -> Config seam dep (#418)"
```

---

## Task 10: Update the imgproxy support matrix

**Files:**
- Modify: `docs/imgproxy_support_matrix.md`

- [ ] **Step 1: Surface axis — Configuration options section**

In the Configuration options section, add a note that the neutral plan/output tunables now live in `ImagePipe.Config` with **"imgproxy parity == neutral defaults today"** (empty overlay), and add a `jxl_effort` row: host config, range 1–9, no URL form.

- [ ] **Step 2: Behavioral axis — Save/encode row (line ~149)**

Replace the stale "effort still has no ImagePipe knob" note with: the new `jxl_effort` knob exists; ImagePipe's neutral default is **7** (attributed to libvips' current `jxlsave` default, so the byte-neutral claim is re-checkable across libvips upgrades) vs imgproxy's **4** (`IMGPROXY_JXL_EFFORT`, `vips/config.go`); the imgproxy overlay is empty today, and `jxl_effort: 4` is the documented byte-parity lever. State plainly that once wired, ImagePipe (7) and imgproxy (4) produce different JXL bytes — "empty overlay" is not "matches imgproxy today."

- [ ] **Step 3: Commit (docs-only, no code gate)**

```bash
git add docs/imgproxy_support_matrix.md
git commit -m "docs(imgproxy): record Config split + jxl_effort divergence (#418)"
```

---

## Task 11: Full-suite gate + no-op surface confirmation

- [ ] **Step 1: Confirm fiddle + telemetry need no change**

`jxl_effort` has no URL token and adds no telemetry event, so the fiddle Svelte app and the default Logger / OTel exporter need no change. Confirm by grep that no URL grammar token or telemetry event was added:

Run: `grep -rn "jxl_effort" lib/image_pipe/parser/imgproxy/option_grammar* lib/image_pipe/telemetry 2>/dev/null`
Expected: no matches.

- [ ] **Step 2: Run the full Elixir gate**

Run: `mise run precommit`
Expected: `mix format --check-formatted`, `mix compile --warnings-as-errors`, `mix credo --strict`, and `mix test` all green — including the imgproxy differential suite (no re-bake; JXL bytes unchanged at effort 7).

- [ ] **Step 3: Final review handoff**

No commit. Hand off to the final parallel review of the complete diff (per the spec's execution recommendation), with at least one reviewer on observable imgproxy compatibility.

---

## Self-review notes

- **Spec coverage:** Config module (T1), adapter delegation + overlay + Parser dep (T2), `jxl_effort` Plan field (T3), Output default-resolution + Output dep (T4), encoder threading incl. `lazy_output/5` + native chain (T5), parser threading (T6), cache key (T7), drift guard (T8), Request seam dep (T9), docs both axes (T10), fiddle/telemetry no-op + full gate (T11). All spec components mapped.
- **Type consistency:** `jxl_effort :: nil | 1..9` on `Plan.Output`/`Resolved`/output-request; concrete `1..9` on `Policy` (defaulted) and at the encoder (or `nil` → omit). `Config.default(:jxl_effort) == 7`. `keys/0`/`@dialect_keys` partition the imgproxy option space.
- **Behavior-neutrality:** every neutral default seeded to today's value; `jxl_effort` default 7 == libvips default; overlay empty → differential green, no re-bake.
