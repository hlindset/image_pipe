# Codec-Specific Encoder Options Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add per-format encoder tuning (JPEG/PNG/WebP/AVIF/JXL) as a product-neutral, libvips-vocabulary config surface threaded into the encoder, with the imgproxy parser translating its `jpgo`/`pngo`/`webpo`/`avifo` URL tokens onto it.

**Architecture:** Five typed `Plan.Output.*Options` structs (libvips field names/values) carried in a new `Plan.Output.encoder_options :: %{format => struct}` map, resolved to a single negotiated struct on `Output.Resolved`, emitted as a libvips bracketed-suffix encode via Vix-direct (gated: only when options are set, else the existing `Image` path is untouched → byte-neutral). The existing flat `jxl_effort` migrates into `JxlOptions{effort}`. Host config flows through `ImagePipe.Config`; imgproxy URL tokens layer per-field overrides via the parser.

**Tech Stack:** Elixir, `NimbleOptions`, `Boundary`, Vix/libvips 8.18.2, ExUnit, Svelte (fiddle).

**Reference spec:** `docs/superpowers/specs/2026-06-28-codec-encoder-options-design.md`

**Verified environment facts (do not re-derive):**
- `Image.stream!`/`Image.write` **reject** bracketed suffixes and **do not** forward arbitrary save opts.
- `Vix.Vips.Image.write_to_buffer(img, ".jpg[Q=70,interlace=true,trellis-quant=true]")` and `write_to_stream/2` **work** (the JXL path already uses `write_to_buffer`). libvips param names use **dashes** in the suffix (`trellis-quant`, `subsample-mode`, `overshoot-deringing`, `optimize-scans`, `quant-table`, `smart-subsample`, `near-lossless`).
- libvips pngsave has **no `colours`** param; palette size is `bitdepth ∈ {1,2,4,8,16}`. heifsave has **no `speed`**; only `effort` (default 4).

**Commands (this repo):** prefix Elixir with the toolchain shim per the project memory:
`PATH="$(mise where elixir)/bin:$PATH" mise exec -- mix test <file>`
Final gates: `mise run precommit` (Elixir) and `mise run precommit:fiddle` (when fiddle touched; needs `pnpm -C fiddle/assets run build` first).

---

## File Structure

**Create:**
- `lib/image_pipe/plan/output/jpeg_options.ex` — `Plan.Output.JpegOptions` struct + `merge/2`.
- `lib/image_pipe/plan/output/png_options.ex` — `Plan.Output.PngOptions`.
- `lib/image_pipe/plan/output/webp_options.ex` — `Plan.Output.WebpOptions`.
- `lib/image_pipe/plan/output/avif_options.ex` — `Plan.Output.AvifOptions`.
- `lib/image_pipe/plan/output/jxl_options.ex` — `Plan.Output.JxlOptions`.
- `test/image_pipe/plan/output/encoder_options_test.exs` — struct + merge unit tests.

**Modify:**
- `lib/image_pipe/plan.ex` — add 5 exports.
- `lib/image_pipe/config.ex` — 5 schema keys, validation, unset defaults, `apply_to_output`.
- `lib/image_pipe/plan/output.ex` — add `encoder_options`, remove `jxl_effort`.
- `lib/image_pipe/output/policy.ex` — carry map, resolve to negotiated struct.
- `lib/image_pipe/output/resolved.ex` — replace `jxl_effort` with `encoder_options`.
- `lib/image_pipe/output/encoder.ex` — token builder + Vix-direct gated encode + jxl read.
- `lib/image_pipe/output/native_jxl_search.ex` — jxl effort read.
- `lib/image_pipe/cache/key.ex` — 3 sites: `jxl_effort` → `encoder_options`.
- `lib/image_pipe/parser/imgproxy/option_grammar.ex` — tokens + codec-option parser + translation.
- `lib/image_pipe/parser/imgproxy/options.ex` — `update_output` + `apply_request_defaults` folding.
- `lib/image_pipe/parser/imgproxy/parsed_request.ex` — `@default_output` + type.
- `lib/image_pipe/parser/imgproxy/plan_builder.ex` — both `output_plan` clauses.
- `fiddle/assets/ImgproxyControls.svelte`, `fiddle/assets/processing-path.ts`, `fiddle/assets/fiddle-url-state.ts` — controls + URL state.
- `docs/imgproxy_support_matrix.md` — surface rows + Diverges note.

**Migration note:** Tasks 5–10 form a coordinated type migration — once `jxl_effort` is removed from `Plan.Output` (Task 5), the project does not compile until `Resolved`, `Policy`, `Encoder`, `native_jxl_search`, and `Cache.Key` are updated (through Task 10). Write each task's focused test first, but expect full compile + green only at the end of Task 10. Commit per task where it compiles; otherwise commit the 5–10 span together.

---

## Task 1: The five neutral option structs

**Files:**
- Create: `lib/image_pipe/plan/output/jpeg_options.ex`, `png_options.ex`, `webp_options.ex`, `avif_options.ex`, `jxl_options.ex`
- Test: `test/image_pipe/plan/output/encoder_options_test.exs`

- [ ] **Step 1: Write the failing test**

```elixir
# test/image_pipe/plan/output/encoder_options_test.exs
defmodule ImagePipe.Plan.Output.EncoderOptionsTest do
  use ExUnit.Case, async: true

  alias ImagePipe.Plan.Output.{AvifOptions, JpegOptions, JxlOptions, PngOptions, WebpOptions}

  test "structs default every field to nil" do
    assert %JpegOptions{interlace: nil, subsample_mode: nil, trellis_quant: nil,
                        overshoot_deringing: nil, optimize_scans: nil, quant_table: nil} =
             %JpegOptions{}

    assert %PngOptions{interlace: nil, palette: nil, bitdepth: nil, filter: nil} = %PngOptions{}

    assert %WebpOptions{lossless: nil, near_lossless: nil, smart_subsample: nil,
                        preset: nil, effort: nil} = %WebpOptions{}

    assert %AvifOptions{subsample_mode: nil, effort: nil} = %AvifOptions{}
    assert %JxlOptions{effort: nil} = %JxlOptions{}
  end

  test "merge/2 lets non-nil override fields win, nil keeps base" do
    base = %JpegOptions{interlace: true, quant_table: 3}
    over = %JpegOptions{quant_table: 5, trellis_quant: true}

    assert JpegOptions.merge(base, over) ==
             %JpegOptions{interlace: true, quant_table: 5, trellis_quant: true}
  end

  test "merge/2 with all-nil override is a no-op" do
    base = %WebpOptions{preset: :photo, effort: 6}
    assert WebpOptions.merge(base, %WebpOptions{}) == base
  end

  test "all_nil?/1 reports whether any field is set" do
    assert JpegOptions.all_nil?(%JpegOptions{})
    refute JpegOptions.all_nil?(%JpegOptions{interlace: true})
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `PATH="$(mise where elixir)/bin:$PATH" mise exec -- mix test test/image_pipe/plan/output/encoder_options_test.exs`
Expected: FAIL — modules not defined.

- [ ] **Step 3: Create the five struct modules**

Each module is a typed `defstruct` (all fields default `nil`) plus identical `merge/2` and `all_nil?/1` helpers. `merge/2`: for each field, override value wins unless `nil`. Write each in its own file (no nested modules — see Elixir guidelines).

```elixir
# lib/image_pipe/plan/output/jpeg_options.ex
defmodule ImagePipe.Plan.Output.JpegOptions do
  @moduledoc """
  libvips `jpegsave` encoder options (product-neutral; the imgproxy parser
  translates `jpgo` into this). Every field is optional (`nil` ⇒ emit no token,
  leaving libvips' default).
  """
  defstruct [:interlace, :subsample_mode, :trellis_quant, :overshoot_deringing,
             :optimize_scans, :quant_table]

  @type t :: %__MODULE__{
          interlace: nil | boolean(),
          subsample_mode: nil | :auto | :on | :off,
          trellis_quant: nil | boolean(),
          overshoot_deringing: nil | boolean(),
          optimize_scans: nil | boolean(),
          quant_table: nil | 0..8
        }

  @doc "Sparse override: non-nil fields of `over` win; nil keeps `base`."
  @spec merge(t(), t()) :: t()
  def merge(%__MODULE__{} = base, %__MODULE__{} = over) do
    Map.merge(base, Map.from_struct(over), fn _k, b, o -> if is_nil(o), do: b, else: o end)
  end

  @doc "True when no field is set."
  @spec all_nil?(t()) :: boolean()
  def all_nil?(%__MODULE__{} = o), do: o |> Map.from_struct() |> Map.values() |> Enum.all?(&is_nil/1)
end
```

```elixir
# lib/image_pipe/plan/output/png_options.ex
defmodule ImagePipe.Plan.Output.PngOptions do
  @moduledoc "libvips `pngsave` encoder options (neutral; imgproxy `pngo` translates here)."
  defstruct [:interlace, :palette, :bitdepth, :filter]

  @type t :: %__MODULE__{
          interlace: nil | boolean(),
          palette: nil | boolean(),
          bitdepth: nil | 1 | 2 | 4 | 8 | 16,
          filter: nil | :none | :sub | :up | :avg | :paeth | :all
        }

  @spec merge(t(), t()) :: t()
  def merge(%__MODULE__{} = base, %__MODULE__{} = over),
    do: Map.merge(base, Map.from_struct(over), fn _k, b, o -> if is_nil(o), do: b, else: o end)

  @spec all_nil?(t()) :: boolean()
  def all_nil?(%__MODULE__{} = o), do: o |> Map.from_struct() |> Map.values() |> Enum.all?(&is_nil/1)
end
```

```elixir
# lib/image_pipe/plan/output/webp_options.ex
defmodule ImagePipe.Plan.Output.WebpOptions do
  @moduledoc "libvips `webpsave` encoder options (neutral; imgproxy `webpo` translates here)."
  defstruct [:lossless, :near_lossless, :smart_subsample, :preset, :effort]

  @type t :: %__MODULE__{
          lossless: nil | boolean(),
          near_lossless: nil | boolean(),
          smart_subsample: nil | boolean(),
          preset: nil | :default | :photo | :picture | :drawing | :icon | :text,
          effort: nil | 0..6
        }

  @spec merge(t(), t()) :: t()
  def merge(%__MODULE__{} = base, %__MODULE__{} = over),
    do: Map.merge(base, Map.from_struct(over), fn _k, b, o -> if is_nil(o), do: b, else: o end)

  @spec all_nil?(t()) :: boolean()
  def all_nil?(%__MODULE__{} = o), do: o |> Map.from_struct() |> Map.values() |> Enum.all?(&is_nil/1)
end
```

```elixir
# lib/image_pipe/plan/output/avif_options.ex
defmodule ImagePipe.Plan.Output.AvifOptions do
  @moduledoc "libvips `heifsave` (AVIF) encoder options (neutral; imgproxy `avifo`/`AVIF_SPEED` translate here)."
  defstruct [:subsample_mode, :effort]

  @type t :: %__MODULE__{
          subsample_mode: nil | :auto | :on | :off,
          effort: nil | 0..9
        }

  @spec merge(t(), t()) :: t()
  def merge(%__MODULE__{} = base, %__MODULE__{} = over),
    do: Map.merge(base, Map.from_struct(over), fn _k, b, o -> if is_nil(o), do: b, else: o end)

  @spec all_nil?(t()) :: boolean()
  def all_nil?(%__MODULE__{} = o), do: o |> Map.from_struct() |> Map.values() |> Enum.all?(&is_nil/1)
end
```

```elixir
# lib/image_pipe/plan/output/jxl_options.ex
defmodule ImagePipe.Plan.Output.JxlOptions do
  @moduledoc """
  libvips `jxlsave` encoder options (neutral). `effort` is optional; when unset
  the encoder applies libvips' default (7) — see `ImagePipe.Output.Encoder`.
  """
  defstruct [:effort]

  @type t :: %__MODULE__{effort: nil | 1..9}

  @spec merge(t(), t()) :: t()
  def merge(%__MODULE__{} = base, %__MODULE__{} = over),
    do: Map.merge(base, Map.from_struct(over), fn _k, b, o -> if is_nil(o), do: b, else: o end)

  @spec all_nil?(t()) :: boolean()
  def all_nil?(%__MODULE__{} = o), do: is_nil(o.effort)
end
```

- [ ] **Step 4: Run test to verify it passes**

Run: `PATH="$(mise where elixir)/bin:$PATH" mise exec -- mix test test/image_pipe/plan/output/encoder_options_test.exs`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add lib/image_pipe/plan/output/*_options.ex test/image_pipe/plan/output/encoder_options_test.exs
git commit -m "feat(plan): neutral per-format encoder option structs"
```

---

## Task 2: Export the structs from the `plan` boundary

**Files:**
- Modify: `lib/image_pipe/plan.ex:9-16`

- [ ] **Step 1: Add the five exports**

In the `exports:` list, after `Output.QualitySearch.Butteraugli,` add:

```elixir
      Output.JpegOptions,
      Output.PngOptions,
      Output.WebpOptions,
      Output.AvifOptions,
      Output.JxlOptions,
```

- [ ] **Step 2: Verify it compiles (Boundary check runs at compile)**

Run: `PATH="$(mise where elixir)/bin:$PATH" mise exec -- mix compile --warnings-as-errors`
Expected: compiles clean (no Boundary export error).

- [ ] **Step 3: Commit**

```bash
git add lib/image_pipe/plan.ex
git commit -m "chore(plan): export encoder option structs"
```

---

## Task 3: Config schema keys, validation, unset defaults, `apply_to_output`

**Files:**
- Modify: `lib/image_pipe/config.ex`
- Test: `test/image_pipe/config_test.exs` (add cases; file exists)

- [ ] **Step 1: Write failing tests**

```elixir
# add to test/image_pipe/config_test.exs
alias ImagePipe.Plan.Output.{AvifOptions, JpegOptions, PngOptions, WebpOptions, JxlOptions}

test "resolve! defaults the five encoder-option keys to unset structs" do
  resolved = ImagePipe.Config.resolve!([])
  assert Keyword.fetch!(resolved, :jpeg_options) == %JpegOptions{}
  assert Keyword.fetch!(resolved, :png_options) == %PngOptions{}
  assert Keyword.fetch!(resolved, :webp_options) == %WebpOptions{}
  assert Keyword.fetch!(resolved, :avif_options) == %AvifOptions{}
  assert Keyword.fetch!(resolved, :jxl_options) == %JxlOptions{}
end

test "resolve! merges a host-set encoder option over the unset default" do
  resolved = ImagePipe.Config.resolve!(jpeg_options: %JpegOptions{interlace: true})
  assert Keyword.fetch!(resolved, :jpeg_options) == %JpegOptions{interlace: true}
end

test "resolve! rejects an out-of-range libvips value" do
  assert_raise ArgumentError, ~r/quant_table/, fn ->
    ImagePipe.Config.resolve!(jpeg_options: %JpegOptions{quant_table: 9})
  end

  assert_raise ArgumentError, ~r/bitdepth/, fn ->
    ImagePipe.Config.resolve!(png_options: %PngOptions{bitdepth: 3})
  end
end

test "apply_to_output stamps encoder_options onto Plan.Output" do
  resolved = ImagePipe.Config.resolve!(webp_options: %WebpOptions{preset: :photo})
  {:ok, out} = ImagePipe.Config.apply_to_output(%ImagePipe.Plan.Output{mode: :automatic}, resolved)
  assert out.encoder_options == %{webp: %WebpOptions{preset: :photo}}
end
```

- [ ] **Step 2: Run to verify failure**

Run: `PATH="$(mise where elixir)/bin:$PATH" mise exec -- mix test test/image_pipe/config_test.exs`
Expected: FAIL — keys unknown.

- [ ] **Step 3: Add schema keys + struct validation**

In `@neutral_schema_kw`, **remove** `jxl_effort: [type: {:in, 1..9}]` and add (use a custom `:struct` type so NimbleOptions accepts the struct; field-level checks live in `range_check!`):

```elixir
    jpeg_options: [type: {:struct, ImagePipe.Plan.Output.JpegOptions}],
    png_options: [type: {:struct, ImagePipe.Plan.Output.PngOptions}],
    webp_options: [type: {:struct, ImagePipe.Plan.Output.WebpOptions}],
    avif_options: [type: {:struct, ImagePipe.Plan.Output.AvifOptions}],
    jxl_options: [type: {:struct, ImagePipe.Plan.Output.JxlOptions}]
```

Add the alias near the others: `alias ImagePipe.Plan.Output.{AvifOptions, JpegOptions, JxlOptions, PngOptions, WebpOptions}`.

- [ ] **Step 4: Seed unset defaults and merge semantics**

In `@map_defaults` add the five unset structs:

```elixir
    jpeg_options: %JpegOptions{},
    png_options: %PngOptions{},
    webp_options: %WebpOptions{},
    avif_options: %AvifOptions{},
    jxl_options: %JxlOptions{}
```

Remove the `@default_jxl_effort`/`jxl_effort` handling: delete `@default_jxl_effort 7`, drop `jxl_effort: @default_jxl_effort` from `@all_defaults` (now `@all_defaults @scalar_defaults ++ @map_defaults`). The five keys are already in `@map_keys` (derived from `@map_defaults`), so `layer/2` will `Map.merge` them — **but** struct `Map.merge` merges raw fields including `nil`, clobbering set base fields. Change the map-key merge to use the structs' `merge/2` when both values are structs:

In `layer/2`, replace the `Map.merge(&1, value)` branch with a helper:

```elixir
  defp layer(base, override) do
    Enum.reduce(override, base, fn {key, value}, acc ->
      if key in @map_keys do
        Keyword.update(acc, key, value, &merge_map_value(&1, value))
      else
        Keyword.put(acc, key, value)
      end
    end)
  end

  defp merge_map_value(%mod{} = base, %mod{} = over), do: mod.merge(base, over)
  defp merge_map_value(base, over) when is_map(base) and is_map(over), do: Map.merge(base, over)
```

- [ ] **Step 5: Validate libvips ranges in `range_check!`**

Add encoder-option validation. Append a call `validate_encoder_options!(resolved)` inside `range_check!/1` and define:

```elixir
  defp validate_encoder_options!(resolved) do
    j = Keyword.fetch!(resolved, :jpeg_options)
    in_enum!(:jpeg_options, :subsample_mode, j.subsample_mode, [:auto, :on, :off])
    in_range!(:jpeg_options, :quant_table, j.quant_table, 0..8)

    p = Keyword.fetch!(resolved, :png_options)
    in_enum!(:png_options, :bitdepth, p.bitdepth, [1, 2, 4, 8, 16])
    in_enum!(:png_options, :filter, p.filter, [:none, :sub, :up, :avg, :paeth, :all])

    w = Keyword.fetch!(resolved, :webp_options)
    in_enum!(:webp_options, :preset, w.preset, [:default, :photo, :picture, :drawing, :icon, :text])
    in_range!(:webp_options, :effort, w.effort, 0..6)

    a = Keyword.fetch!(resolved, :avif_options)
    in_enum!(:avif_options, :subsample_mode, a.subsample_mode, [:auto, :on, :off])
    in_range!(:avif_options, :effort, a.effort, 0..9)

    in_range!(:jxl_options, :effort, Keyword.fetch!(resolved, :jxl_options).effort, 1..9)
    :ok
  end

  defp in_range!(_key, _field, nil, _range), do: :ok
  defp in_range!(key, field, value, lo..hi//_) do
    unless is_integer(value) and value >= lo and value <= hi do
      raise ArgumentError, "invalid config: #{key} #{field} (#{inspect(value)}) must be in #{lo}..#{hi}"
    end
  end

  defp in_enum!(_key, _field, nil, _allowed), do: :ok
  defp in_enum!(key, field, value, allowed) do
    unless value in allowed do
      raise ArgumentError,
            "invalid config: #{key} #{field} (#{inspect(value)}) must be one of #{inspect(allowed)}"
    end
  end
```

- [ ] **Step 6: Stamp into `apply_to_output`**

In `apply_to_output/2`, **remove** `jxl_effort: Keyword.get(resolved, :jxl_effort),` and add `encoder_options: encoder_options_from_config(resolved),` to the struct update. Define the helper (prunes all-nil structs so the no-config map is `%{}`):

```elixir
  @encoder_option_config %{
    jpeg: :jpeg_options, png: :png_options, webp: :webp_options,
    avif: :avif_options, jpeg_xl: :jxl_options
  }

  @doc false
  @spec encoder_options_from_config(keyword()) :: %{optional(atom()) => struct()}
  def encoder_options_from_config(resolved) do
    for {format, key} <- @encoder_option_config,
        struct = Keyword.fetch!(resolved, key),
        not struct.__struct__.all_nil?(struct),
        into: %{},
        do: {format, struct}
  end
```

(`@encoder_option_config` maps the `Format` atom — note `:jpeg_xl` — to the config key. Reused by the imgproxy parser in Task 9; keep `encoder_options_from_config/1` public-in-module / documented for that caller.)

- [ ] **Step 7: Run config tests**

Run: `PATH="$(mise where elixir)/bin:$PATH" mise exec -- mix test test/image_pipe/config_test.exs`
Expected: PASS.

- [ ] **Step 8: Commit**

```bash
git add lib/image_pipe/config.ex test/image_pipe/config_test.exs
git commit -m "feat(config): libvips-native encoder option keys + validation"
```

---

## Task 4: `Plan.Output` field — add `encoder_options`, remove `jxl_effort`

**Files:**
- Modify: `lib/image_pipe/plan/output.ex`

- [ ] **Step 1: Edit the struct + types**

In `defstruct`, remove `jxl_effort: nil` and add `encoder_options: %{}`. In `@type t`, remove the `jxl_effort:` line and add:

```elixir
          encoder_options: %{optional(format()) => struct()},
```

Update the `@moduledoc` paragraph that documents `jxl_effort` (the one beginning "`jxl_effort` (1–9) is the JPEG XL encode effort…") to describe `encoder_options` instead:

```
`encoder_options` maps an output `format()` to its libvips-native encoder
option struct (`JpegOptions`/`PngOptions`/`WebpOptions`/`AvifOptions`/`JxlOptions`).
Absent format ⇒ no options ⇒ libvips defaults. A parser resolves host config
(and, for imgproxy, URL tokens) into this map before building the plan.
```

- [ ] **Step 2: Compile (expected to break downstream — that is fine)**

Run: `PATH="$(mise where elixir)/bin:$PATH" mise exec -- mix compile 2>&1 | head -30`
Expected: errors in `policy.ex`, `resolved.ex`, `encoder.ex`, `native_jxl_search.ex`, `cache/key.ex`, `plan_builder.ex` referencing `jxl_effort`. These are fixed in Tasks 5–10. **Do not commit yet** — commit at the end of Task 10.

---

## Task 5: `Output.Resolved` — carry the negotiated struct

**Files:**
- Modify: `lib/image_pipe/output/resolved.ex`

- [ ] **Step 1: Replace `jxl_effort` with `encoder_options`**

In `defstruct @enforce_keys ++ [...]`, replace `jxl_effort: nil` with `encoder_options: nil`. In `@type t`, replace the `jxl_effort:` line with:

```elixir
          encoder_options:
            nil
            | ImagePipe.Plan.Output.JpegOptions.t()
            | ImagePipe.Plan.Output.PngOptions.t()
            | ImagePipe.Plan.Output.WebpOptions.t()
            | ImagePipe.Plan.Output.AvifOptions.t()
            | ImagePipe.Plan.Output.JxlOptions.t()
```

(`encoder_options` on `Resolved` is the **single** struct for the negotiated `format`, or `nil`.)

---

## Task 6: `Output.Policy` — thread map, resolve to negotiated struct

**Files:**
- Modify: `lib/image_pipe/output/policy.ex`

- [ ] **Step 1: Carry `encoder_options` on the policy struct**

In `defstruct @enforce_keys ++ [...]`, replace `jxl_effort: nil` with `encoder_options: %{}`. In `@type t`, replace the `jxl_effort:` line with `encoder_options: %{optional(format()) => struct()},`.

- [ ] **Step 2: Populate from the output plan**

In **both** `from_output_plan/3` clauses, replace
`jxl_effort: output.jxl_effort || ImagePipe.Config.default(:jxl_effort)`
with
`encoder_options: output.encoder_options`.

- [ ] **Step 3: Resolve to the negotiated struct**

In `resolved/2`, replace `jxl_effort: policy.jxl_effort` with:

```elixir
      encoder_options: Map.get(policy.encoder_options, format)
```

- [ ] **Step 4: Compile-check this module in isolation later (full green at Task 10).**

---

## Task 7: `Encoder` — token builder, gated Vix-direct encode, jxl read

**Files:**
- Modify: `lib/image_pipe/output/encoder.ex`
- Test: `test/image_pipe/output/encoder_options_encode_test.exs` (create)

- [ ] **Step 1: Write the failing encode test**

```elixir
# test/image_pipe/output/encoder_options_encode_test.exs
defmodule ImagePipe.Output.EncoderOptionsEncodeTest do
  use ExUnit.Case, async: true

  alias ImagePipe.Output.{Encoder, Resolved}
  alias ImagePipe.Plan.Output.{JpegOptions, PngOptions}

  defp finalized(w \\ 64, h \\ 64) do
    {:ok, img} = Image.new(w, h, color: [120, 30, 30])
    img
  end

  defp resolved(format, encoder_options) do
    %Resolved{
      format: format, quality: {:quality, 75},
      response_headers: [], strip_metadata: true, keep_copyright: false,
      color_profile: :strip, encoder_options: encoder_options
    }
  end

  test "encode_to_buffer with no encoder options produces a decodable image" do
    {:ok, bin} = Encoder.encode_to_buffer(finalized(), resolved(:jpeg, nil), 75)
    {:ok, decoded} = Image.from_binary(bin)
    assert Image.width(decoded) == 64
  end

  test "progressive jpeg via encoder options is interlaced and decodable" do
    opts = %JpegOptions{interlace: true, trellis_quant: true, quant_table: 3}
    {:ok, bin} = Encoder.encode_to_buffer(finalized(), resolved(:jpeg, opts), 75)
    {:ok, decoded} = Image.from_binary(bin)
    assert Image.width(decoded) == 64
    # progressive marker SOF2 (0xFFC2) present in a progressive JPEG
    assert :binary.match(bin, <<0xFF, 0xC2>>) != :nomatch
  end

  test "palette png via encoder options is decodable" do
    opts = %PngOptions{palette: true, bitdepth: 4, filter: :none}
    {:ok, bin} = Encoder.encode_to_buffer(finalized(), resolved(:png, opts), 75)
    {:ok, decoded} = Image.from_binary(bin)
    assert Image.width(decoded) == 64
  end

  test "webp + avif options encode via the Vix path and decode" do
    alias ImagePipe.Plan.Output.{AvifOptions, WebpOptions}

    {:ok, wbin} =
      Encoder.encode_to_buffer(finalized(), resolved(:webp, %WebpOptions{preset: :photo, smart_subsample: true}), 75)

    assert {:ok, wimg} = Image.from_binary(wbin)
    assert Image.width(wimg) == 64

    {:ok, abin} =
      Encoder.encode_to_buffer(finalized(), resolved(:avif, %AvifOptions{subsample_mode: :off, effort: 0}), 75)

    assert {:ok, aimg} = Image.from_binary(abin)
    assert Image.width(aimg) == 64
  end

  test "byte-neutral: empty options == nil options for the same source/quality" do
    a = Encoder.encode_to_buffer(finalized(), resolved(:jpeg, nil), 75)
    b = Encoder.encode_to_buffer(finalized(), resolved(:jpeg, %JpegOptions{}), 75)
    assert a == b
  end
end
```

- [ ] **Step 2: Run to verify failure**

Run: `PATH="$(mise where elixir)/bin:$PATH" mise exec -- mix test test/image_pipe/output/encoder_options_encode_test.exs`
Expected: FAIL — `Resolved` has no `encoder_options` yet / encoder ignores it (after Task 5 it compiles but tokens not applied).

- [ ] **Step 3: Add the token builder**

Add private helpers. The builder turns a per-format struct into libvips suffix tokens (dash-named params). All-nil / `nil` ⇒ `[]`.

```elixir
  # libvips suffix tokens (k=v, dash-named) from the negotiated encoder-option struct.
  defp encoder_tokens(nil), do: []

  defp encoder_tokens(%ImagePipe.Plan.Output.JpegOptions{} = o) do
    tokens(
      interlace: o.interlace,
      "subsample-mode": o.subsample_mode,
      "trellis-quant": o.trellis_quant,
      "overshoot-deringing": o.overshoot_deringing,
      "optimize-scans": o.optimize_scans,
      "quant-table": o.quant_table
    )
  end

  defp encoder_tokens(%ImagePipe.Plan.Output.PngOptions{} = o) do
    tokens(interlace: o.interlace, palette: o.palette, bitdepth: o.bitdepth, filter: o.filter)
  end

  defp encoder_tokens(%ImagePipe.Plan.Output.WebpOptions{} = o) do
    tokens(
      lossless: o.lossless,
      "near-lossless": o.near_lossless,
      "smart-subsample": o.smart_subsample,
      preset: o.preset,
      effort: o.effort
    )
  end

  defp encoder_tokens(%ImagePipe.Plan.Output.AvifOptions{} = o) do
    tokens("subsample-mode": o.subsample_mode, effort: o.effort)
  end

  defp encoder_tokens(%ImagePipe.Plan.Output.JxlOptions{}), do: []

  defp tokens(pairs) do
    for {k, v} <- pairs, not is_nil(v), do: "#{k}=#{token_value(v)}"
  end

  defp token_value(true), do: "true"
  defp token_value(false), do: "false"
  defp token_value(v) when is_atom(v), do: Atom.to_string(v)
  defp token_value(v), do: to_string(v)
```

- [ ] **Step 4: Build a bracketed suffix and gate the Vix-direct path**

Add a suffix assembler that combines the format suffix, the `Q` token, and the encoder tokens:

```elixir
  # ".jpg" + Q + option tokens -> ".jpg[Q=75,interlace=true,...]". Q omitted for :default.
  defp vix_suffix(suffix, quality, tokens) do
    parts = Enum.reject([quality_token(quality) | tokens], &is_nil/1)
    if parts == [], do: suffix, else: "#{suffix}[#{Enum.join(parts, ",")}]"
  end
```

Now gate the non-JXL streamed path (`lazy_output/5`, the generic clause) — when tokens are present, encode via Vix `write_to_stream`, else keep the existing `Image.stream!` path **unchanged** (byte-neutral):

```elixir
  defp lazy_output(finalized, resolved_output, mime_type, suffix, opts) do
    case encoder_tokens(resolved_output.encoder_options) do
      [] ->
        image_module = Keyword.get(opts, :image_module, Image)
        stream = image_module.stream!(finalized, output_options(suffix, resolved_output))
        {:ok, stream, mime_type, nil}

      tokens ->
        vsuffix = vix_suffix(suffix, resolved_output.quality, tokens)
        stream = VixImage.write_to_stream(finalized, vsuffix)
        {:ok, stream, mime_type, nil}
    end
  end
```

And gate `encode_to_buffer/3` (the non-JXL clause):

```elixir
  def encode_to_buffer(%VixImage{} = image, %Resolved{} = resolved_output, quality) do
    with {:ok, _mime_type, suffix} <- output_format(resolved_output) do
      case encoder_tokens(resolved_output.encoder_options) do
        [] ->
          case Image.write(image, :memory, suffix: suffix, quality: quality) do
            {:ok, binary} -> {:ok, binary}
            {:error, {:encode, _, _} = tagged} -> {:error, tagged}
            {:error, reason} -> {:error, {:encode, encode_error(reason), []}}
          end

        tokens ->
          vsuffix = vix_suffix(suffix, {:quality, quality}, tokens)
          case VixImage.write_to_buffer(image, vsuffix) do
            {:ok, binary} -> {:ok, binary}
            {:error, reason} -> {:error, {:encode, encode_error(reason), []}}
          end
      end
    end
  rescue
    exception -> {:error, {:encode, exception, __STACKTRACE__}}
  end
```

- [ ] **Step 5: Migrate the JXL reads (effort now comes from `JxlOptions`)**

Add a helper and use it in all three JXL sites:

```elixir
  # JXL effort: the negotiated JxlOptions.effort, defaulting to libvips' 7 when unset.
  defp jxl_effort(%Resolved{encoder_options: %ImagePipe.Plan.Output.JxlOptions{effort: e}}), do: e || 7
  defp jxl_effort(%Resolved{}), do: 7
```

- In `lazy_output/5` JXL clause: change the head to match the whole resolved and read effort via the helper:

```elixir
  defp lazy_output(finalized, %Resolved{format: :jpeg_xl, quality: quality} = resolved, mime_type, _suffix, _opts) do
    case encode_jxl_buffer(finalized, quality, jxl_effort(resolved)) do
      {:ok, binary} -> {:ok, [binary], mime_type, nil}
      {:error, _reason} = err -> err
    end
  end
```

- In `encode_to_buffer/3` JXL clause: replace `resolved.jxl_effort` with `jxl_effort(resolved)`:

```elixir
  def encode_to_buffer(%VixImage{} = image, %Resolved{format: :jpeg_xl} = resolved, quality),
    do: encode_jxl_buffer(image, quality, jxl_effort(resolved))
```

- [ ] **Step 6: Run the encode test**

Run: `PATH="$(mise where elixir)/bin:$PATH" mise exec -- mix test test/image_pipe/output/encoder_options_encode_test.exs`
Expected: PASS.

---

## Task 8: `native_jxl_search` — read effort from the struct

**Files:**
- Modify: `lib/image_pipe/output/native_jxl_search.ex:37`

- [ ] **Step 1: Replace the read**

Change line 37 from `resolved.jxl_effort` to read the struct effort (default 7). Add a small private helper mirroring the encoder's (this module also has `Resolved`):

```elixir
  defp jxl_effort(%Resolved{encoder_options: %ImagePipe.Plan.Output.JxlOptions{effort: e}}), do: e || 7
  defp jxl_effort(%Resolved{}), do: 7
```

and change the call to `native_jxl_butteraugli(image, nqs, resolved.max_bytes, jxl_effort(resolved), telemetry_opts)`.

---

## Task 9: `Cache.Key` — `jxl_effort` → `encoder_options` (3 sites)

**Files:**
- Modify: `lib/image_pipe/cache/key.ex` (lines ~104, ~122, ~147)

- [ ] **Step 1: Replace all three `jxl_effort:` entries**

In `output_plan_data/2` (both `:automatic` and `:explicit` clauses) and in `output_data/3` (the `:automatic` clause), replace the line
`jxl_effort: output.jxl_effort`
with
`encoder_options: output.encoder_options`.

(The whole pre-negotiation map enters the key; `MaterialDigest.canonicalize/1` hashes the structs. The ETag inherits via `plan_material/2` — no separate edit.)

- [ ] **Step 2: Compile the whole project**

Run: `PATH="$(mise where elixir)/bin:$PATH" mise exec -- mix compile --warnings-as-errors`
Expected: clean compile (the Task 4 migration is now complete).

---

## Task 10: Migration green checkpoint + commit

- [ ] **Step 1: Run the output/cache/policy test suites**

Run:
```bash
PATH="$(mise where elixir)/bin:$PATH" mise exec -- mix test test/image_pipe/output test/image_pipe/cache test/image_pipe/plan
```
Expected: PASS. If a pre-existing test built `%Resolved{jxl_effort: ...}` or `%Plan.Output{jxl_effort: ...}`, update it to `encoder_options:` form.

- [ ] **Step 2: Add a cache-key inclusion test**

```elixir
# add to test/image_pipe/cache/key_test.exs
alias ImagePipe.Plan.Output.JpegOptions

test "encoder_options change the cache key but not when identical" do
  base = %ImagePipe.Plan.Output{mode: {:explicit, :jpeg}}
  k1 = key_for(%{base | encoder_options: %{}})
  k2 = key_for(%{base | encoder_options: %{jpeg: %JpegOptions{interlace: true}}})
  k3 = key_for(%{base | encoder_options: %{jpeg: %JpegOptions{interlace: true}}})
  assert k1 != k2
  assert k2 == k3
end
```

(Use the file's existing key-building helper for `key_for/1`; mirror an existing key test's setup.)

- [ ] **Step 3: Run + commit the whole migration**

Run: `PATH="$(mise where elixir)/bin:$PATH" mise exec -- mix test test/image_pipe/cache/key_test.exs`
Expected: PASS.

```bash
git add lib/image_pipe/plan/output.ex lib/image_pipe/output/resolved.ex \
        lib/image_pipe/output/policy.ex lib/image_pipe/output/encoder.ex \
        lib/image_pipe/output/native_jxl_search.ex lib/image_pipe/cache/key.ex \
        test/image_pipe/output/encoder_options_encode_test.exs test/image_pipe/cache/key_test.exs
git commit -m "feat(output): thread encoder_options; migrate jxl_effort into JxlOptions"
```

---

## Task 11: imgproxy grammar — tokens, codec-option parser, translation

**Files:**
- Modify: `lib/image_pipe/parser/imgproxy/option_grammar.ex`
- Test: `test/image_pipe/parser/imgproxy/option_grammar_test.exs` (file exists; add cases)

- [ ] **Step 1: Write failing grammar tests**

```elixir
# add to option_grammar_test.exs
alias ImagePipe.Plan.Output.{AvifOptions, JpegOptions, PngOptions, WebpOptions}

test "jpgo translates imgproxy names to libvips fields" do
  assert {:ok, [encoder_options: %{jpeg: %JpegOptions{interlace: true, subsample_mode: :off}}]} =
           OptionGrammar.parse("jpgo:1:1")
end

test "jpgo omitted leading positions stay nil (omit-vs-false)" do
  assert {:ok, [encoder_options: %{jpeg: %JpegOptions{optimize_scans: true}}]} =
           OptionGrammar.parse("jpgo:::true")
  refute match?({:ok, [encoder_options: %{jpeg: %JpegOptions{interlace: false}}]}, OptionGrammar.parse("jpgo:::true"))
end

test "pngo quantization_colors buckets to bitdepth and sets filter/palette" do
  assert {:ok, [encoder_options: %{png: %PngOptions{palette: true, bitdepth: 8, filter: :none}}]} =
           OptionGrammar.parse("pngo::1:128")
end

test "webpo compression near_lossless -> near_lossless bool" do
  assert {:ok, [encoder_options: %{webp: %WebpOptions{near_lossless: true, preset: :photo}}]} =
           OptionGrammar.parse("webpo:near_lossless::photo")
end

test "avifo subsample -> subsample_mode" do
  assert {:ok, [encoder_options: %{avif: %AvifOptions{subsample_mode: :off}}]} =
           OptionGrammar.parse("avifo:off")
end

test "alias full names parse identically" do
  assert OptionGrammar.parse("jpeg_options:1") == OptionGrammar.parse("jpgo:1")
end
```

- [ ] **Step 2: Run to verify failure**

Run: `PATH="$(mise where elixir)/bin:$PATH" mise exec -- mix test test/image_pipe/parser/imgproxy/option_grammar_test.exs`
Expected: FAIL — unknown option.

- [ ] **Step 3: Register the tokens in `@option_specs`**

Add (the field list is informational; the codec parser reads raw args):

```elixir
    "jpeg_options" => {:jpeg_options, []},
    "jpgo" => {:jpeg_options, []},
    "png_options" => {:png_options, []},
    "pngo" => {:png_options, []},
    "webp_options" => {:webp_options, []},
    "webpo" => {:webp_options, []},
    "avif_options" => {:avif_options, []},
    "avifo" => {:avif_options, []},
```

**Route the assignments to the output scope.** Dispatch is: `@option_specs` lookup → `parse_known_option(kind, fields, args, segment)` → `scoped_assignments(kind, assignments)`. The catch-all `scoped_assignments(_kind, …)` returns `{:pipeline, …}`, so codec options would wrongly land in the pipeline. Add the four kinds to the `:output` clause of `scoped_assignments/2`:

```elixir
  defp scoped_assignments(kind, assignments)
       when kind in [
              :format, :quality, :format_quality, :max_bytes, :autoquality,
              :strip_metadata, :keep_copyright, :preserve_hdr,
              :jpeg_options, :png_options, :webp_options, :avif_options
            ],
       do: {:output, assignments}
```

- [ ] **Step 4: Add the codec-option parser + per-format translation**

Add an alias `alias ImagePipe.Plan.Output.{AvifOptions, JpegOptions, PngOptions, WebpOptions}`, then a generic positional decoder and four `parse_known_option` clauses. The decoder walks `{position_name, raw_value}` pairs; empty/absent ⇒ skip (field stays nil); present ⇒ run the per-format translator which returns `{:ok, [field: value]}` libvips assignments.

```elixir
  defp parse_known_option(:jpeg_options, _spec, args, segment),
    do: codec_options(:jpeg, JpegOptions, args,
          [:progressive, :no_subsample, :trellis_quant, :overshoot_deringing, :optimize_scans, :quant_table],
          &jpeg_arg/2, segment)

  defp parse_known_option(:png_options, _spec, args, segment),
    do: codec_options(:png, PngOptions, args, [:interlaced, :quantize, :quantization_colors], &png_arg/2, segment)

  defp parse_known_option(:webp_options, _spec, args, segment),
    do: codec_options(:webp, WebpOptions, args, [:compression, :smart_subsample, :preset], &webp_arg/2, segment)

  defp parse_known_option(:avif_options, _spec, args, segment),
    do: codec_options(:avif, AvifOptions, args, [:subsample], &avif_arg/2, segment)

  # Walk positional args; empty string ⇒ no override; otherwise translate to
  # libvips field assignments and build the struct. Too many args ⇒ invalid.
  defp codec_options(format_key, mod, args, positions, translator, segment) do
    if length(args) > length(positions) do
      {:error, {:invalid_option_segment, segment}}
    else
      result =
        positions
        |> Enum.zip(args ++ List.duplicate("", length(positions) - length(args)))
        |> Enum.reduce_while({:ok, []}, fn
          {_pos, ""}, {:ok, acc} -> {:cont, {:ok, acc}}
          {pos, raw}, {:ok, acc} ->
            case translator.(pos, raw) do
              {:ok, assigns} -> {:cont, {:ok, acc ++ assigns}}
              :error -> {:halt, {:error, {:invalid_option_segment, segment}}}
            end
        end)

      case result do
        {:ok, assigns} -> {:ok, [encoder_options: %{format_key => struct(mod, assigns)}]}
        {:error, _} = err -> err
      end
    end
  end

  defp jpeg_arg(:progressive, v), do: bool_assign(:interlace, v)
  defp jpeg_arg(:no_subsample, v), do: with({:ok, b} <- boolish(v), do: {:ok, [subsample_mode: if(b, do: :off, else: :on)]})
  defp jpeg_arg(:trellis_quant, v), do: bool_assign(:trellis_quant, v)
  defp jpeg_arg(:overshoot_deringing, v), do: bool_assign(:overshoot_deringing, v)
  defp jpeg_arg(:optimize_scans, v), do: bool_assign(:optimize_scans, v)
  defp jpeg_arg(:quant_table, v), do: int_assign(:quant_table, v, 0..8)

  defp png_arg(:interlaced, v), do: bool_assign(:interlace, v)
  defp png_arg(:quantize, v), do: with({:ok, b} <- boolish(v), do: {:ok, if(b, do: [palette: true, filter: :none], else: [palette: false])})
  defp png_arg(:quantization_colors, v) do
    case Integer.parse(v) do
      {n, ""} when n >= 2 and n <= 256 -> {:ok, [bitdepth: png_bitdepth(n)]}
      _ -> :error
    end
  end

  defp webp_arg(:compression, "lossy"), do: {:ok, []}
  defp webp_arg(:compression, "lossless"), do: {:ok, [lossless: true]}
  defp webp_arg(:compression, "near_lossless"), do: {:ok, [near_lossless: true]}
  defp webp_arg(:compression, _), do: :error
  defp webp_arg(:smart_subsample, v), do: bool_assign(:smart_subsample, v)
  defp webp_arg(:preset, v) when v in ~w(default photo picture drawing icon text), do: {:ok, [preset: String.to_existing_atom(v)]}
  defp webp_arg(:preset, _), do: :error

  defp avif_arg(:subsample, v) when v in ~w(auto on off), do: {:ok, [subsample_mode: String.to_existing_atom(v)]}
  defp avif_arg(:subsample, _), do: :error

  # imgproxy's quantization_colors -> libvips bitdepth bucket (vips_pngsave_go).
  defp png_bitdepth(n) when n > 16, do: 8
  defp png_bitdepth(n) when n > 4, do: 4
  defp png_bitdepth(n) when n > 2, do: 2
  defp png_bitdepth(_), do: 1

  defp bool_assign(field, v), do: with({:ok, b} <- boolish(v), do: {:ok, [{field, b}]})
  defp int_assign(field, v, lo..hi//_) do
    case Integer.parse(v) do
      {n, ""} when n >= lo and n <= hi -> {:ok, [{field, n}]}
      _ -> :error
    end
  end

  defp boolish(v) do
    case parse_boolean(v) do
      {:ok, b} -> {:ok, b}
      {:error, _} -> :error
    end
  end
```

(`parse_boolean/1` already exists at line 553 and accepts `1`/`t`/`true`/`0`/`f`/`false`. `String.to_existing_atom/1` is safe here — the atoms are compiled into the struct types.)

- [ ] **Step 5: Run grammar tests**

Run: `PATH="$(mise where elixir)/bin:$PATH" mise exec -- mix test test/image_pipe/parser/imgproxy/option_grammar_test.exs`
Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add lib/image_pipe/parser/imgproxy/option_grammar.ex test/image_pipe/parser/imgproxy/option_grammar_test.exs
git commit -m "feat(imgproxy): parse jpgo/pngo/webpo/avifo into neutral encoder options"
```

---

## Task 12: imgproxy wiring — fold assignments, config defaults, plan

**Files:**
- Modify: `lib/image_pipe/parser/imgproxy/parsed_request.ex`, `options.ex`, `plan_builder.ex`

- [ ] **Step 1: Add `encoder_options` to the parsed-request output shape**

In `parsed_request.ex`: in `@default_output`, replace `jxl_effort: nil` with `encoder_options: %{}`. In the `output_request()` type, replace the `required(:jxl_effort) => 1..9 | nil` line with:

```elixir
          required(:encoder_options) => %{optional(ImagePipe.Format.output_format()) => struct()},
```

- [ ] **Step 2: Accumulate per-token structs in `update_output`**

In `options.ex` `update_output/2`, add an `:encoder_options` clause to the reduce (before the catch-all), merging each token's `%{format => struct}` and combining same-format structs via the struct's `merge/2`:

```elixir
        {:encoder_options, new}, output ->
          merged =
            Map.merge(output.encoder_options, new, fn _fmt, a, b -> a.__struct__.merge(a, b) end)

          %{output | encoder_options: merged}
```

- [ ] **Step 3: Fold config defaults + URL overrides in `apply_request_defaults`**

In `options.ex` `apply_request_defaults/2`, replace
`output = Map.put(output, :jxl_effort, Keyword.get(defaults, :jxl_effort))`
with a merge of config-default structs (from `defaults`) under the URL structs (`output.encoder_options`):

```elixir
      output = Map.put(output, :encoder_options, merge_encoder_options(defaults, output.encoder_options))
```

and add (reusing `Config`'s format↔key mapping by calling its config builder, then overlaying URL):

```elixir
  alias ImagePipe.Config

  # Config-default structs (pruned of all-nil) under the URL override structs,
  # per-field via each struct's merge/2. Prune all-nil results so an unused
  # feature yields %{} (byte- and cache-key-neutral).
  defp merge_encoder_options(defaults, url_map) do
    base = Config.encoder_options_from_config(defaults)

    Map.keys(base) ++ Map.keys(url_map)
    |> Enum.uniq()
    |> Enum.reduce(%{}, fn fmt, acc ->
      merged = merge_format_struct(Map.get(base, fmt), Map.get(url_map, fmt))
      if merged && not merged.__struct__.all_nil?(merged), do: Map.put(acc, fmt, merged), else: acc
    end)
  end

  defp merge_format_struct(nil, over), do: over
  defp merge_format_struct(base, nil), do: base
  defp merge_format_struct(base, over), do: base.__struct__.merge(base, over)
```

(`Config.encoder_options_from_config/1` was added in Task 3, Step 6.)

- [ ] **Step 4: Map into `Plan.Output` in `plan_builder`**

In `plan_builder.ex`, in **both** `output_plan/1` clauses (`:automatic` and `{:explicit, format}`), replace `jxl_effort: request.jxl_effort` with `encoder_options: request.encoder_options`.

- [ ] **Step 5: Reconcile the `imgproxy_overlay/0` comment**

In `lib/image_pipe/parser/imgproxy.ex` (around line 60–61), the comment cites `jxl_effort: 4` as a future byte-parity lever. If `imgproxy_overlay/0` actually sets `jxl_effort: 4`, change it to `jxl_options: %ImagePipe.Plan.Output.JxlOptions{effort: 4}` (and update the comment); if it's comment-only, update the comment to name `jxl_options`. Verify with: `grep -n "jxl_effort\|jxl_options\|imgproxy_overlay" lib/image_pipe/parser/imgproxy.ex`.

- [ ] **Step 6: Compile + run parser tests**

Run:
```bash
PATH="$(mise where elixir)/bin:$PATH" mise exec -- mix compile --warnings-as-errors && \
PATH="$(mise where elixir)/bin:$PATH" mise exec -- mix test test/image_pipe/parser/imgproxy
```
Expected: PASS. Fix any test that constructed `output_request(jxl_effort: ...)` → `encoder_options:`.

- [ ] **Step 7: Commit**

```bash
git add lib/image_pipe/parser/imgproxy/parsed_request.ex lib/image_pipe/parser/imgproxy/options.ex \
        lib/image_pipe/parser/imgproxy/plan_builder.ex lib/image_pipe/parser/imgproxy.ex
git commit -m "feat(imgproxy): wire encoder options through defaults + plan build"
```

---

## Task 13: Wire-level conformance tests

**Files:**
- Test: `test/image_pipe/imgproxy_wire_conformance_test.exs` (file exists; add a describe block)

- [ ] **Step 1: Add wire tests (real `ImagePipe.call/2`)**

Add representative tests asserting user-visible contracts. Mirror the file's existing request helpers (`build_conn`, mount opts). Cover: progressive jpeg via `jpgo`, palette png via `pngo`, cross-dialect inheritance (host config `jpeg_options` on a non-imgproxy request), and the omit-vs-false merge.

```elixir
describe "codec encoder options" do
  test "jpgo:1 yields a progressive (decodable) JPEG", %{conn: conn} do
    conn = get_imgproxy(conn, "rs:fit:32:32/jpgo:1/plain/#{sample_url()}@jpg")
    assert conn.status == 200
    assert content_type(conn) == "image/jpeg"
    assert :binary.match(conn.resp_body, <<0xFF, 0xC2>>) != :nomatch
  end

  test "host jpeg_options config applies to an IIIF request" do
    # Mount with config jpeg_options: %JpegOptions{interlace: true}; issue an IIIF
    # request that outputs JPEG; assert the SOF2 progressive marker is present.
  end

  test "jpgo:::1 keeps a config-set interlace true (omit-vs-false)" do
    # Mount config jpeg_options interlace: true; request jpgo:::1 (sets only
    # optimize_scans); assert output is still progressive (interlace survived).
  end
end
```

(Fill in `get_imgproxy`/`sample_url`/`content_type` from the existing helpers in that file. For the IIIF test, use the IIIF wire test mount pattern from `test/image_pipe/iiif_*` if present, else a `ImagePipe.call/2` with IIIF mount opts.)

- [ ] **Step 2: Run**

Run: `PATH="$(mise where elixir)/bin:$PATH" mise exec -- mix test test/image_pipe/imgproxy_wire_conformance_test.exs`
Expected: PASS.

- [ ] **Step 3: Commit**

```bash
git add test/image_pipe/imgproxy_wire_conformance_test.exs
git commit -m "test(imgproxy): wire-level codec encoder option conformance"
```

---

## Task 14: Fiddle controls + URL state

**Files:**
- Modify: `fiddle/assets/ImgproxyControls.svelte`, `fiddle/assets/processing-path.ts`, `fiddle/assets/fiddle-url-state.ts`
- Test: `fiddle/assets/processing-path.test.ts`

> Note (project memory): do **not** self-preview the fiddle UI; gate + commit and let the user verify the look in a real browser.

- [ ] **Step 1: Add URL-state fields**

In `fiddle-url-state.ts`, extend the imgproxy state with the URL-token flags (use imgproxy vocabulary): `jpgo` `{progressive?: bool, no_subsample?: bool, trellis_quant?: bool, overshoot_deringing?: bool, optimize_scans?: bool, quant_table?: number}`, `pngo` `{interlaced?, quantize?, quantization_colors?}`, `webpo` `{compression?: 'lossy'|'near_lossless'|'lossless', smart_subsample?, preset?}`, `avifo` `{subsample?: 'auto'|'on'|'off'}`. Default all unset.

- [ ] **Step 2: Emit the tokens in `processing-path.ts`**

When any sub-flag is set, append the colon-positional token with empty positions for unset fields (matching imgproxy omit semantics), e.g. `jpgo:${progressive??''}:${no_subsample??''}:...` then trim trailing empty positions.

- [ ] **Step 3: Add a path test**

```ts
// processing-path.test.ts
it("emits jpgo with omitted positions", () => {
  expect(buildImgproxyPath({ jpgo: { optimize_scans: true } })).toContain("jpgo:::true");
});
```

- [ ] **Step 4: Add controls in `ImgproxyControls.svelte`**

Checkboxes for the bools; selects for `compression`/`preset`/`subsample`; number inputs for `quant_table` (0–8) and `quantization_colors` (2–256). Follow the existing control grouping in the file. No control for the effort knobs.

- [ ] **Step 5: Build + run fiddle JS tests**

Run:
```bash
pnpm -C fiddle/assets run build && pnpm -C fiddle/assets test
```
Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add fiddle/assets/ImgproxyControls.svelte fiddle/assets/processing-path.ts \
        fiddle/assets/fiddle-url-state.ts fiddle/assets/processing-path.test.ts
git commit -m "feat(fiddle): imgproxy codec encoder option controls + URL state"
```

---

## Task 15: Support matrix docs

**Files:**
- Modify: `docs/imgproxy_support_matrix.md`

- [ ] **Step 1: Flip the surface rows**

Find the "Output and encoding" / "Advanced encoder options" rows for `jpeg_options`/`png_options`/`webp_options`/`avif_options` (currently ⭕ Missing) and mark them supported, noting they translate into the libvips-native neutral core. Update the existing `IMGPROXY_JXL_EFFORT ⚠️` bullet and any `IMGPROXY_*` encoder-config stub rows to reflect the `jxl_effort` → `jxl_options` migration.

- [ ] **Step 2: Add the Diverges note**

Add a behavioral "Diverges" note for AVIF default effort (ImagePipe core uses libvips `effort` default 4; imgproxy default speed 8 / effort 1), mirroring the existing `jxl_effort` 7-vs-4 treatment. Note the PNG-quantize libvips-build dependency (Quantizr / libimagequant) and the `quantization_colors → bitdepth` bucketing.

- [ ] **Step 3: Commit**

```bash
git add docs/imgproxy_support_matrix.md
git commit -m "docs(imgproxy): mark codec encoder options supported; note AVIF divergence"
```

---

## Task 16: Full gate

- [ ] **Step 1: Elixir gate**

Run: `mise run precommit`
Expected: format/compile/credo/test all green.

- [ ] **Step 2: Fiddle gate (assets were touched)**

Run: `pnpm -C fiddle/assets run build && mise run precommit:fiddle`
Expected: green.

- [ ] **Step 3: Final review handoff** — run the parallel diff review per the project's review-cycle rule (at least one compatibility lens against imgproxy docs/source), then create the PR.

---

## Self-Review Notes (for the executor)

- **Greenfield:** no cache data-version bump; reshape key data in place.
- **Byte-neutral guard:** the Task 7 "empty == nil" test plus the existing imgproxy differential suite (run by `mix test`) together guard that unset options change nothing. If the differential bake reports drift, an encoder-option leaked into the no-options path — check the `[] -> existing Image path` gate.
- **`String.to_existing_atom`** is safe only because the preset/subsample atoms are compiled into the struct `@type`s and used in `Config` validation; do not switch to `String.to_atom`.
- **Telemetry:** no event metadata changes — do not add encoder_options to any span in this change.
