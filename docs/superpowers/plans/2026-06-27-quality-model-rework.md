# Quality-Model Rework Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add host-config default output quality (imgproxy-parity values), flip autoquality min/max precedence so URL args win over per-format config, and make the scale-dependent autoquality knobs (`target`, `allowed_error`) per-metric — fixing the shadowed butteraugli defaults (#390) along the way.

**Architecture:** The imgproxy parser resolves its config defaults into the product-neutral `ImagePipe.Plan.Output` (the existing pattern for `strip_metadata`/`color_profile`). `Output.Policy` does per-format resolution after format negotiation. Quality resolution gains config levels below the existing URL levels; autoquality structs carry URL/base/per-format bracket sources separately so `resolve_search/2` can apply URL-wins precedence.

**Tech Stack:** Elixir, NimbleOptions (schema validation), ExUnit, libvips (via `image`/`vix`).

**Spec:** [docs/superpowers/specs/2026-06-27-quality-model-rework-design.md](../specs/2026-06-27-quality-model-rework-design.md)

**Ground-truth references:**
- imgproxy quality resolution: `/Users/hlindset/src/imgproxy/processing/options.go:264` (`Quality(format)`), defaults `processing/config.go:60`.
- Run tests with `mise exec -- mix test <path>`. If a run crashes in `rustler_precompiled`/`validate_quote`, prepend the correct Elixir to PATH: `PATH="$(mise where elixir)/bin:$PATH" mise exec -- mix test <path>`.

---

## File Structure

**Modify:**
- `lib/image_pipe/plan/output.ex` — add `default_quality` field + `:jpeg_xl` to `@type format`.
- `lib/image_pipe/parser/imgproxy/parsed_request.ex` — add `default_quality` to `@default_output` map + the `output_request()` typespec (the parser's mutable output is this **plain map**, not `%Output{}`).
- `lib/image_pipe/parser/imgproxy/plan_builder.ex` — copy `default_quality` into both `output_plan/1` `%Output{}` constructions (without this, the resolved value never reaches production).
- `lib/image_pipe/plan/output/quality_search/{size,ssimulacra2,butteraugli}.ex` — add `url_min_quality`/`url_max_quality`.
- `lib/image_pipe/output/policy.ex` — `default_quality` on the Policy struct (**non-enforced, default `:default`**) + both `from_output_plan/3` clauses; `effective_quality/2` lossless gate; URL-wins in all four `resolve_search/2` clauses.
- `lib/image_pipe/cache/key.ex` — fold `url_min_quality`/`url_max_quality` into `quality_search_key/1` (Size clause + `quality_metric_key/2`); the URL bracket now changes output bytes, so it must be in the storage-identity key.
- `lib/image_pipe/parser/imgproxy.ex` — schema (`quality`, `format_quality`, `autoquality_target`→map, `autoquality_allowed_error`→map), `request_defaults/1`, config-boundary validation.
- `lib/image_pipe/parser/imgproxy/options.ex` — `resolve_quality_defaults/2` (new); `build_quality_search`/`build_quality_metric`/`resolve_quality_search_target`; new `default_allowed_error/1`.
- `docs/imgproxy_support_matrix.md` — surface + behavioral axes.

**Test (modify/extend):**
- `test/image_pipe/plan/output_test.exs`, `test/image_pipe/output_policy_test.exs`, `test/parser/imgproxy/options_test.exs`, `test/parser/imgproxy_test.exs`, `test/image_pipe/imgproxy_wire_conformance_test.exs`.

**Unchanged (confirm, do not touch):** `lib/image_pipe/output/encoder.ex` (`output_options/2` already maps `{:quality,n}`→apply, `:default`→omit), the `ResolvedQualitySearch.*` structs (carry final resolved values), `lib/image_pipe/parser/imgproxy/option_grammar.ex` (already normalizes URL `target_*`→`:target` and rejects an inverted URL `min>max` pair at `option_grammar.ex:347`).

---

# Part 1 — Default output quality (#389-a)

### Task 1: Thread `default_quality` end-to-end (struct + ParsedRequest map + PlanBuilder)

**Files:**
- Modify: `lib/image_pipe/plan/output.ex`, `lib/image_pipe/parser/imgproxy/parsed_request.ex`, `lib/image_pipe/parser/imgproxy/plan_builder.ex`
- Test: `test/image_pipe/plan/output_test.exs`

**Why three files:** the imgproxy parser's mutable output is the **plain `@default_output` map** in `parsed_request.ex` (not a `%Output{}` struct), and `PlanBuilder.output_plan/1` converts that map into the production `%Output{}`. Adding the field only to `Plan.Output` would make `%{output | default_quality: …}` (Task 3) raise `KeyError` and would drop the value before it reaches production. All three must carry it.

- [ ] **Step 1: Write the failing test**

Add to `test/image_pipe/plan/output_test.exs`:

```elixir
test "default_quality defaults to :default and is settable" do
  assert %ImagePipe.Plan.Output{mode: :automatic}.default_quality == :default

  out = %ImagePipe.Plan.Output{mode: :automatic, default_quality: {:quality, 80}}
  assert out.default_quality == {:quality, 80}
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mise exec -- mix test test/image_pipe/plan/output_test.exs`
Expected: FAIL — `key :default_quality not found` (struct has no such field).

- [ ] **Step 3: Add the field and type**

In `lib/image_pipe/plan/output.ex`, add `default_quality: :default` to the `defstruct` keyword list (place it right after `format_qualities: %{},`):

```elixir
  defstruct mode: :automatic,
            quality: :default,
            format_qualities: %{},
            default_quality: :default,
            strip_metadata: true,
```

Add `:jpeg_xl` to the `@type format` (it is in the runtime `Format.output_format()` but missing here, and the new config maps are `:jpeg_xl`-keyed):

```elixir
  @type format :: :avif | :webp | :jpeg | :png | :jpeg_xl
```

Add `default_quality` to the `@type t` map, right after the `format_qualities:` line:

```elixir
          format_qualities: %{optional(format()) => quality()},
          default_quality: quality(),
```

- [ ] **Step 4: Add the key to the ParsedRequest map + typespec**

In `lib/image_pipe/parser/imgproxy/parsed_request.ex`, add `default_quality: :default` to the `@default_output` map (after `format_qualities: %{},`):

```elixir
  @default_output %{
    format: nil,
    quality: :default,
    format_qualities: %{},
    default_quality: :default,
    max_bytes: nil,
```

And add the field to the `output_request()` typespec (after the `format_qualities` line):

```elixir
          required(:format_qualities) => %{optional(output_format()) => quality()},
          required(:default_quality) => quality(),
```

- [ ] **Step 5: Copy it through PlanBuilder**

In `lib/image_pipe/parser/imgproxy/plan_builder.ex`, add `default_quality: request.default_quality,` to **both** `output_plan/1` `%Output{}` constructions (the `%{format: nil}` clause ~line 121 and the `%{format: format}` clause ~line 141), right after the `format_qualities: request.format_qualities,` line in each.

- [ ] **Step 6: Run test to verify it passes; compile**

Run: `mise exec -- mix test test/image_pipe/plan/output_test.exs`
Run: `mise exec -- mix compile --warnings-as-errors`
Expected: PASS / clean compile.

- [ ] **Step 7: Commit**

```bash
git add lib/image_pipe/plan/output.ex lib/image_pipe/parser/imgproxy/parsed_request.ex lib/image_pipe/parser/imgproxy/plan_builder.ex test/image_pipe/plan/output_test.exs
git commit -m "feat(output): thread Plan.Output.default_quality through parser"
```

---

### Task 2: imgproxy config — `quality` + `format_quality` (schema, defaults, validation)

**Files:**
- Modify: `lib/image_pipe/parser/imgproxy.ex`
- Test: `test/parser/imgproxy_test.exs`

- [ ] **Step 1: Write the failing tests**

Add to `test/parser/imgproxy_test.exs` (inside the config-validation area; this file already exercises `validate_options!`):

```elixir
describe "quality config" do
  test "defaults: quality 80, format_quality webp/avif/jxl" do
    [imgproxy: opts] = ImagePipe.Parser.Imgproxy.validate_options!(imgproxy: [])
    assert opts[:quality] == 80
    assert opts[:format_quality] == %{webp: 79, avif: 63, jpeg_xl: 77}
  end

  test "rejects quality outside 1..100" do
    assert_raise ArgumentError, ~r/quality/, fn ->
      ImagePipe.Parser.Imgproxy.validate_options!(imgproxy: [quality: 0])
    end
  end

  test "rejects a format_quality value outside 1..100" do
    assert_raise ArgumentError, ~r/format_quality/, fn ->
      ImagePipe.Parser.Imgproxy.validate_options!(imgproxy: [format_quality: %{webp: 0}])
    end
  end
end
```

- [ ] **Step 2: Run to verify failure**

Run: `mise exec -- mix test test/parser/imgproxy_test.exs`
Expected: FAIL — `quality`/`format_quality` are unknown options (NimbleOptions rejects them).

- [ ] **Step 3: Add schema options**

In `lib/image_pipe/parser/imgproxy.ex`, inside the `@imgproxy_schema NimbleOptions.new!(...)` keyword list, add after `keep_copyright:` (around line 50):

```elixir
                     quality: [type: :pos_integer, default: 80],
                     format_quality: [
                       type: {:map, :atom, :pos_integer},
                       default: %{webp: 79, avif: 63, jpeg_xl: 77}
                     ],
```

- [ ] **Step 4: Pass both through `request_defaults/1`**

In `request_defaults/1` (around line 320), add these two entries to the returned keyword list:

```elixir
      quality: Keyword.get(imgproxy_opts, :quality, 80),
      format_quality:
        Keyword.get(imgproxy_opts, :format_quality, %{webp: 79, avif: 63, jpeg_xl: 77}),
```

- [ ] **Step 5: Add range validation at the config boundary**

In `validate_imgproxy_options!/1`, the `{:ok, validated}` branch currently calls `validate_autoquality_brackets!(validated)`. Add a call right before it:

```elixir
      {:ok, validated} ->
        validate_quality_config!(validated)
        validate_autoquality_brackets!(validated)
```

Add the new private function (place it directly above `validate_autoquality_brackets!/1`):

```elixir
  # Range-check the host-config default quality knobs. NimbleOptions enforces
  # pos_integer / map shape but not the 1..100 ceiling, so assert it here at the
  # config boundary before the value can reach the encoder.
  defp validate_quality_config!(validated) do
    quality = Keyword.fetch!(validated, :quality)

    unless quality in 1..100 do
      raise ArgumentError,
            "invalid imgproxy config: quality (#{quality}) must be between 1 and 100"
    end

    Enum.each(Keyword.fetch!(validated, :format_quality), fn {format, q} ->
      unless q in 1..100 do
        raise ArgumentError,
              "invalid imgproxy config: format_quality #{inspect(format)} (#{q}) " <>
                "must be between 1 and 100"
      end
    end)

    :ok
  end
```

- [ ] **Step 6: Run to verify pass**

Run: `mise exec -- mix test test/parser/imgproxy_test.exs`
Expected: PASS.

- [ ] **Step 7: Commit**

```bash
git add lib/image_pipe/parser/imgproxy.ex test/parser/imgproxy_test.exs
git commit -m "feat(imgproxy): add quality/format_quality host config (imgproxy defaults)"
```

---

### Task 3: Parser resolution — fold config quality into `Plan.Output`

**Files:**
- Modify: `lib/image_pipe/parser/imgproxy/options.ex`
- Test: `test/parser/imgproxy/options_test.exs`

**Context:** by the time defaults are applied, `update_output/2` ([options.ex:264](../../../lib/image_pipe/parser/imgproxy/options.ex#L264)) has already merged URL `fq` into `output.format_qualities` (values are `:default | {:quality, n}`; `:default` comes from `fq:x:0`). Config `format_quality` values are bare ints. imgproxy treats `fq:x:0`/`q:0` as *unset* (`q > 0` checks), so a URL `:default` entry must **not** override the config per-format value.

- [ ] **Step 1: Write the failing tests**

Add to `test/parser/imgproxy/options_test.exs`:

```elixir
describe "default quality resolution" do
  @q_defaults [quality: 80, format_quality: %{webp: 79, avif: 63, jpeg_xl: 77}]

  test "config format_quality folds into format_qualities; default_quality from global" do
    assert {:ok, request} = Options.parse([], Presets.empty(), @q_defaults)
    assert request.output.default_quality == {:quality, 80}

    assert request.output.format_qualities == %{
             webp: {:quality, 79},
             avif: {:quality, 63},
             jpeg_xl: {:quality, 77}
           }
  end

  test "URL fq overrides config format_quality for that format" do
    assert {:ok, request} = Options.parse(~w(fq:avif:70), Presets.empty(), @q_defaults)
    assert request.output.format_qualities[:avif] == {:quality, 70}
    assert request.output.format_qualities[:webp] == {:quality, 79}
  end

  test "URL fq:fmt:0 (unset) does not erase the config per-format value" do
    assert {:ok, request} = Options.parse(~w(fq:avif:0), Presets.empty(), @q_defaults)
    assert request.output.format_qualities[:avif] == {:quality, 63}
  end

  test "no config defaults: default_quality stays :default, no synthetic format_qualities" do
    assert {:ok, request} = Options.parse([], Presets.empty(), [])
    assert request.output.default_quality == :default
    assert request.output.format_qualities == %{}
  end
end
```

- [ ] **Step 2: Run to verify failure**

Run: `mise exec -- mix test test/parser/imgproxy/options_test.exs`
Expected: FAIL — `default_quality` is `:default` and `format_qualities` is `%{}` (config not folded yet).

- [ ] **Step 3: Add `resolve_quality_defaults/2` and wire it into the pipe**

In `lib/image_pipe/parser/imgproxy/options.ex`, in `apply_request_defaults/2`, insert `resolve_quality_defaults/2` into the `with` pipe (between the `Map.put(:color_profile, ...)` and `resolve_quality_search_defaults/2` lines):

```elixir
    with {:ok, output} <-
           output
           |> resolve_metadata_defaults(defaults)
           |> Map.put(:strip_color_profile, strip_color_profile?)
           |> Map.put(:color_profile, color_profile)
           |> resolve_quality_defaults(defaults)
           |> resolve_quality_search_defaults(defaults) do
```

Add the function (place it directly above `resolve_quality_search_defaults/2`):

```elixir
  # Fold host-config default quality into the product-neutral output. Config
  # `format_quality` (bare ints) is normalized to the `quality()` shape and used
  # as the base under the already-merged URL `fq` (`output.format_qualities`).
  # A URL `:default` entry (`fq:fmt:0`) means "unset" — imgproxy treats `0` as
  # unset — so it must not erase the config per-format value; reject those before
  # merging. `default_quality` carries the configured global default.
  defp resolve_quality_defaults(output, defaults) do
    config_fq =
      defaults
      |> Keyword.get(:format_quality, %{})
      |> Map.new(fn {format, q} -> {format, {:quality, q}} end)

    url_fq =
      output.format_qualities
      |> Enum.reject(fn {_format, quality} -> quality == :default end)
      |> Map.new()

    default_quality =
      case Keyword.get(defaults, :quality) do
        nil -> :default
        value -> {:quality, value}
      end

    %{
      output
      | format_qualities: Map.merge(config_fq, url_fq),
        default_quality: default_quality
    }
  end
```

- [ ] **Step 4: Run to verify pass**

Run: `mise exec -- mix test test/parser/imgproxy/options_test.exs`
Expected: PASS for the new `describe`. (Other tests in this file are addressed in Task 10.)

- [ ] **Step 5: Commit**

```bash
git add lib/image_pipe/parser/imgproxy/options.ex test/parser/imgproxy/options_test.exs
git commit -m "feat(imgproxy): resolve config quality defaults into Plan.Output"
```

---

### Task 4: `Output.Policy` — carry `default_quality`, gate the lossless default

**Files:**
- Modify: `lib/image_pipe/output/policy.ex`
- Test: `test/image_pipe/output_policy_test.exs`

**Context:** existing tests assert full `%Policy{}` literals. To avoid a compile break across ~13 construction sites (and equality-assertion churn), add `default_quality` as a **non-enforced** Policy field defaulting to `:default` — *not* in `@enforce_keys`. Existing literals then keep compiling and still match (both sides default to `:default`); only the new tests below set it.

- [ ] **Step 1: Write the failing tests**

Add to `test/image_pipe/output_policy_test.exs` (these use `{:explicit, fmt}` so resolution needs no negotiation):

```elixir
describe "effective_quality default resolution" do
  defp policy_for(format, opts) do
    output = struct(%Output{mode: {:explicit, format}}, opts)
    Policy.from_output_plan(%Plug.Conn{}, output, [])
  end

  test "format in format_qualities wins" do
    policy = policy_for(:avif, format_qualities: %{avif: {:quality, 63}}, default_quality: {:quality, 80})
    assert {:ok, %{quality: {:quality, 63}}} = Policy.resolve(policy, nil)
  end

  test "format absent from map falls to the global default" do
    policy = policy_for(:jpeg, format_qualities: %{avif: {:quality, 63}}, default_quality: {:quality, 80})
    assert {:ok, %{quality: {:quality, 80}}} = Policy.resolve(policy, nil)
  end

  test "png is gated off the global default (stays lossless)" do
    policy = policy_for(:png, default_quality: {:quality, 80})
    assert {:ok, %{quality: :default}} = Policy.resolve(policy, nil)
  end

  test "explicit URL q wins for all formats incl png" do
    policy = policy_for(:png, quality: {:quality, 50}, default_quality: {:quality, 80})
    assert {:ok, %{quality: {:quality, 50}}} = Policy.resolve(policy, nil)
  end
end
```

Add the alias if missing at the top of the test module: `alias ImagePipe.Plan.Output`.

- [ ] **Step 2: Run to verify failure**

Run: `mise exec -- mix test test/image_pipe/output_policy_test.exs`
Expected: FAIL — the old 2-clause `effective_quality/2` ignores `default_quality` (returns `Map.get(format_qualities, format, :default)`), so the global-default test expects `{:quality, 80}` but gets `:default`, and the png-gate test likewise. A **value mismatch**, not a KeyError.

- [ ] **Step 3: Add `default_quality` to the Policy struct (non-enforced)**

In `lib/image_pipe/output/policy.ex`, add `default_quality: :default` to the `defstruct` defaults keyword list (the part after `@enforce_keys ++`) — **do not** add it to `@enforce_keys`, so existing `%Policy{}` literals keep compiling:

```elixir
  defstruct @enforce_keys ++
              [
                flatten_background: Color.white(),
                default_quality: :default,
                quality_search: :none,
                max_bytes: nil,
                quality_search_offsets: Output.default_quality_search_offsets()
              ]
```

Add it to `@type t` after the `format_qualities:` line:

```elixir
          format_qualities: %{optional(format()) => quality()},
          default_quality: quality(),
```

- [ ] **Step 4: Copy it in both `from_output_plan/3` clauses**

In each of the two `from_output_plan/3` clauses, add (right after the `format_qualities: output.format_qualities,` line):

```elixir
      format_qualities: output.format_qualities,
      default_quality: output.default_quality,
```

- [ ] **Step 5: Rewrite `effective_quality/2` with the lossless gate**

Add a module attribute near the top (after `@passthrough_source_formats`):

```elixir
  # Lossless output formats do not take the configured numeric default quality
  # (a numeric Q would trigger PNG quantization). An explicit URL q/fq still
  # applies; only the implicit global default is gated.
  @lossless_default_formats [:png]
```

Replace the two `effective_quality/2` clauses (currently [policy.ex:241-248](../../../lib/image_pipe/output/policy.ex#L241)) with:

```elixir
  defp effective_quality(%__MODULE__{quality: {:quality, _value} = quality}, _format),
    do: quality

  defp effective_quality(
         %__MODULE__{quality: :default, format_qualities: format_qualities} = policy,
         format
       ) do
    case Map.get(format_qualities, format) do
      {:quality, _value} = quality -> quality
      _other -> default_for(policy, format)
    end
  end

  defp default_for(%__MODULE__{}, format) when format in @lossless_default_formats, do: :default
  defp default_for(%__MODULE__{default_quality: default_quality}, _format), do: default_quality
```

- [ ] **Step 6: Confirm existing literal assertions still pass**

Because `default_quality` is non-enforced and defaults to `:default`, existing full-`%Policy{}` equality assertions need **no edits**: their literal omits the field (→ `:default`), and `from_output_plan` on a `%Output{}` whose `default_quality` is `:default` yields `:default` too — they match. Just run the file; if any pre-existing assertion does fail, it means that test builds an `%Output{}` with a non-`:default` `default_quality` (unlikely) — add the field to that one literal.

- [ ] **Step 7: Run to verify pass**

Run: `mise exec -- mix test test/image_pipe/output_policy_test.exs`
Expected: PASS.

- [ ] **Step 8: Commit**

```bash
git add lib/image_pipe/output/policy.ex test/image_pipe/output_policy_test.exs
git commit -m "feat(output): resolve config default quality with lossless-format gate"
```

---

### Task 5: Wire-level decode-pixel check for the new default output

**Files:**
- Test: `test/image_pipe/imgproxy_wire_conformance_test.exs`

**Context:** with config defaults active, a request omitting `q`/`fq` now encodes at Q63 (avif) / Q79 (webp) / Q80 (jpeg) instead of libvips defaults. This test asserts the encoder receives the configured quality. Match the existing wire-test style in this file (real `ImagePipe.call/2`, decode the body). Read a couple of existing tests in the file first to mirror the mount/opts helper and a source fixture.

- [ ] **Step 1: Write the test**

Add a test that issues an automatic-format request with `Accept: image/avif`, no `q`/`fq`, host config `imgproxy: [quality: 80, format_quality: %{avif: 63}]`, and asserts the response is AVIF and its byte size differs from the same request encoded with an explicit `q:90` (proving the configured default is applied, not libvips' default). Use the file's existing helpers for building the conn and reading the decoded result. Example skeleton (adapt to the file's actual helpers):

```elixir
test "default avif output uses configured format_quality (Q63), overridable by q" do
  opts = imgproxy_opts(quality: 80, format_quality: %{avif: 63})

  default_conn = call(~p"/rs:fit:200:200/plain/#{source_url()}", accept: "image/avif", opts: opts)
  q90_conn = call(~p"/q:90/rs:fit:200:200/plain/#{source_url()}", accept: "image/avif", opts: opts)

  assert content_type(default_conn) == "image/avif"
  assert content_type(q90_conn) == "image/avif"
  # Configured Q63 must produce a smaller file than an explicit Q90.
  assert byte_size(default_conn.resp_body) < byte_size(q90_conn.resp_body)
end
```

- [ ] **Step 2: Run to verify it passes**

Run: `mise exec -- mix test test/image_pipe/imgproxy_wire_conformance_test.exs`
Expected: PASS (if it fails on helper names, align with the file's real helpers; if it fails on the size assertion, the default isn't being applied — debug Task 3/4).

- [ ] **Step 3: Commit**

```bash
git add test/image_pipe/imgproxy_wire_conformance_test.exs
git commit -m "test(imgproxy): wire check for configured default output quality"
```

---

# Part 2 — Autoquality precedence + per-metric knobs + #390 cleanup

### Task 6: Add `url_min_quality`/`url_max_quality` to the QualitySearch structs

**Files:**
- Modify: `lib/image_pipe/plan/output/quality_search/size.ex`, `.../ssimulacra2.ex`, `.../butteraugli.ex`
- Test: `test/image_pipe/plan/output/quality_search_test.exs`

- [ ] **Step 1: Write the failing test**

Add to `test/image_pipe/plan/output/quality_search_test.exs`:

```elixir
test "url_min_quality/url_max_quality default to nil and are non-enforced" do
  for mod <- [
        ImagePipe.Plan.Output.QualitySearch.Size,
        ImagePipe.Plan.Output.QualitySearch.Ssimulacra2,
        ImagePipe.Plan.Output.QualitySearch.Butteraugli
      ] do
    s = struct(mod, target: 1, min_quality: 70, max_quality: 80)
    assert s.url_min_quality == nil
    assert s.url_max_quality == nil

    s2 = struct(mod, target: 1, min_quality: 70, max_quality: 80, url_min_quality: 75)
    assert s2.url_min_quality == 75
  end
end
```

- [ ] **Step 2: Run to verify failure**

Run: `mise exec -- mix test test/image_pipe/plan/output/quality_search_test.exs`
Expected: FAIL — `key :url_min_quality not found`.

- [ ] **Step 3: Add the fields to all three structs**

In each of the three files, add `url_min_quality: nil, url_max_quality: nil` to the `defstruct` non-enforced list (do **not** add to `@enforce_keys`), and to `@type t`.

`size.ex`:
```elixir
  defstruct @enforce_keys ++
              [url_min_quality: nil, url_max_quality: nil, format_min: %{}, format_max: %{}, max_resolution: 0]
```
and in `@type t`, after `max_quality: 1..100,`:
```elixir
          url_min_quality: nil | 1..100,
          url_max_quality: nil | 1..100,
```

`ssimulacra2.ex` and `butteraugli.ex`: same — add `url_min_quality: nil, url_max_quality: nil` into the `defstruct @enforce_keys ++ [...]` list (before `allowed_error: 0`) and the two `@type t` lines after `max_quality: 1..100,`.

- [ ] **Step 4: Run to verify pass**

Run: `mise exec -- mix test test/image_pipe/plan/output/quality_search_test.exs`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add lib/image_pipe/plan/output/quality_search/ test/image_pipe/plan/output/quality_search_test.exs
git commit -m "feat(output): carry URL min/max bracket override on QualitySearch structs"
```

---

### Task 7: `resolve_search/2` URL-wins precedence + cache-key fix (all four clauses)

**Files:**
- Modify: `lib/image_pipe/output/policy.ex`, `lib/image_pipe/cache/key.ex`
- Test: `test/image_pipe/output_policy_test.exs`, `test/image_pipe/cache/key_test.exs`

**Why the cache key too:** before this change a URL `min/max` landed on the base `min_quality`/`max_quality`, which the cache key already composes. After the flip it lands on `url_min_quality`/`url_max_quality` and overrides the resolved bracket → it changes output bytes. If the key doesn't include the URL fields, two requests differing only in URL bracket collapse to one key and serve the wrong variant. So the key must fold them in (same step).

- [ ] **Step 1: Write the failing tests**

Add to `test/image_pipe/output_policy_test.exs`:

```elixir
describe "autoquality bracket precedence (resolve_search)" do
  alias ImagePipe.Plan.Output.QualitySearch
  alias ImagePipe.Output.ResolvedQualitySearch, as: RQS

  defp resolve_search_for(format, search) do
    output = %Output{mode: {:explicit, format}, quality_search: search}
    policy = Policy.from_output_plan(%Plug.Conn{}, output, [])
    {:ok, resolved} = Policy.resolve(policy, nil)
    resolved.quality_search
  end

  test "URL min/max beat per-format config" do
    search = %QualitySearch.Ssimulacra2{
      target: 78, min_quality: 70, max_quality: 80,
      url_min_quality: 75, url_max_quality: 85,
      format_min: %{avif: 60}, format_max: %{avif: 65}
    }

    assert %RQS.Ssimulacra2{min_quality: 75, max_quality: 85} = resolve_search_for(:avif, search)
  end

  test "per-format config beats base when URL omits" do
    search = %QualitySearch.Ssimulacra2{
      target: 78, min_quality: 70, max_quality: 80,
      format_min: %{avif: 60}, format_max: %{avif: 65}
    }

    assert %RQS.Ssimulacra2{min_quality: 60, max_quality: 65} = resolve_search_for(:avif, search)
  end

  test "asymmetric: URL min only, max falls to config base" do
    search = %QualitySearch.Ssimulacra2{
      target: 78, min_quality: 70, max_quality: 80, url_min_quality: 75
    }

    assert %RQS.Ssimulacra2{min_quality: 75, max_quality: 80} = resolve_search_for(:jpeg, search)
  end

  test "jpeg_xl butteraugli native path honors URL override" do
    search = %QualitySearch.Butteraugli{
      target: 1.0, min_quality: 70, max_quality: 80,
      url_min_quality: 50, url_max_quality: 90,
      format_min: %{jpeg_xl: 45}, format_max: %{jpeg_xl: 80}
    }

    assert %RQS.NativeJxlButteraugli{min_quality: 50, max_quality: 90} =
             resolve_search_for(:jpeg_xl, search)
  end
end
```

- [ ] **Step 2: Run to verify failure**

Run: `mise exec -- mix test test/image_pipe/output_policy_test.exs`
Expected: FAIL — the first/asymmetric/jxl tests resolve to config-per-format or base because `resolve_search/2` ignores the URL fields.

- [ ] **Step 3: Apply URL-wins in all four `resolve_search/2` clauses**

In `lib/image_pipe/output/policy.ex`, change each per-format min/max resolution from `Map.get(s.format_x, format, s.x_quality)` to `s.url_x_quality || Map.get(s.format_x, format, s.x_quality)`. The four clauses:

`Size` clause:
```elixir
      min_quality: s.url_min_quality || Map.get(s.format_min, format, s.min_quality),
      max_quality: s.url_max_quality || Map.get(s.format_max, format, s.max_quality),
```

`Ssimulacra2` clause: same two lines.

`Butteraugli` `:jpeg_xl` clause (`%RQS.NativeJxlButteraugli{}`):
```elixir
      min_quality: s.url_min_quality || Map.get(s.format_min, :jpeg_xl, s.min_quality),
      max_quality: s.url_max_quality || Map.get(s.format_max, :jpeg_xl, s.max_quality),
```

`Butteraugli` generic clause: same as Ssimulacra2 (uses `format`).

- [ ] **Step 4: Run to verify pass**

Run: `mise exec -- mix test test/image_pipe/output_policy_test.exs`
Expected: PASS.

- [ ] **Step 5: Write the failing cache-key test**

Add to `test/image_pipe/cache/key_test.exs` (mirror the file's existing key-building helper; this asserts two requests differing only in the URL bracket get distinct keys):

```elixir
test "url_min_quality/url_max_quality are part of the quality_search cache key" do
  base = %ImagePipe.Plan.Output.QualitySearch.Ssimulacra2{
    target: 78, min_quality: 70, max_quality: 80
  }

  k_plain = Key.quality_search_key(base)
  k_url = Key.quality_search_key(%{base | url_min_quality: 80, url_max_quality: 90})

  refute k_plain == k_url
end
```

If `quality_search_key/1` is private, assert through the public key-building entry point the file already uses (build two `%Output{}`/request structs differing only in the URL bracket and assert distinct full keys). Match the file's established pattern.

- [ ] **Step 6: Run to verify failure**

Run: `mise exec -- mix test test/image_pipe/cache/key_test.exs`
Expected: FAIL — keys are equal (URL fields not composed).

- [ ] **Step 7: Fold the URL fields into the key**

In `lib/image_pipe/cache/key.ex`, add `url_min_quality`/`url_max_quality` to both quality key builders. In `quality_search_key(%QualitySearch.Size{} = s)` (~line 160) and `quality_metric_key(metric, s)` (~line 178), add after the `max_quality:` line:

```elixir
      min_quality: s.min_quality,
      max_quality: s.max_quality,
      url_min_quality: s.url_min_quality,
      url_max_quality: s.url_max_quality,
```

- [ ] **Step 8: Run to verify pass**

Run: `mise exec -- mix test test/image_pipe/cache/key_test.exs test/image_pipe/output_policy_test.exs`
Expected: PASS.

- [ ] **Step 9: Commit**

```bash
git add lib/image_pipe/output/policy.ex lib/image_pipe/cache/key.ex test/image_pipe/output_policy_test.exs test/image_pipe/cache/key_test.exs
git commit -m "feat(output): URL autoquality min/max override per-format config + cache key"
```

---

### Task 8: imgproxy config — per-metric `autoquality_target` / `autoquality_allowed_error`

**Files:**
- Modify: `lib/image_pipe/parser/imgproxy.ex`
- Test: `test/parser/imgproxy_test.exs`

- [ ] **Step 1: Write the failing tests**

Add to `test/parser/imgproxy_test.exs`:

```elixir
describe "per-metric autoquality config" do
  test "defaults: target/allowed_error are empty maps" do
    [imgproxy: opts] = ImagePipe.Parser.Imgproxy.validate_options!(imgproxy: [])
    assert opts[:autoquality_target] == %{}
    assert opts[:autoquality_allowed_error] == %{}
  end

  test "accepts per-metric maps" do
    [imgproxy: opts] =
      ImagePipe.Parser.Imgproxy.validate_options!(
        imgproxy: [
          autoquality_target: %{ssimulacra2: 85, butteraugli: 1.0, size: 40_000},
          autoquality_allowed_error: %{ssimulacra2: 0.5, butteraugli: 0.1}
        ]
      )

    assert opts[:autoquality_target][:ssimulacra2] == 85
    assert opts[:autoquality_allowed_error][:butteraugli] == 0.1
  end

  test "rejects target out of the metric's range" do
    assert_raise ArgumentError, ~r/target/, fn ->
      ImagePipe.Parser.Imgproxy.validate_options!(imgproxy: [autoquality_target: %{butteraugli: 78}])
    end
  end

  test "rejects negative allowed_error and the :size key for allowed_error" do
    assert_raise ArgumentError, ~r/allowed_error/, fn ->
      ImagePipe.Parser.Imgproxy.validate_options!(imgproxy: [autoquality_allowed_error: %{ssimulacra2: -1}])
    end

    assert_raise ArgumentError, ~r/allowed_error/, fn ->
      ImagePipe.Parser.Imgproxy.validate_options!(imgproxy: [autoquality_allowed_error: %{size: 1.0}])
    end
  end

  test "rejects an unknown metric key" do
    assert_raise ArgumentError, ~r/autoquality_target/, fn ->
      ImagePipe.Parser.Imgproxy.validate_options!(imgproxy: [autoquality_target: %{bogus: 50}])
    end
  end
end
```

- [ ] **Step 2: Run to verify failure**

Run: `mise exec -- mix test test/parser/imgproxy_test.exs`
Expected: FAIL — current schema types are scalar (`{:or, [:integer, :float]}` for target, custom non-negative for allowed_error), so a map is rejected with the wrong message / accepted scalars no longer match.

- [ ] **Step 3: Change the schema types**

In `@imgproxy_schema`, replace the `autoquality_target:` and `autoquality_allowed_error:` entries with map types and `%{}` defaults (drop the eager scalar defaults — this is what makes the per-metric built-in defaults reachable). Keep the surrounding explanatory comments updated to describe the per-metric map:

```elixir
                     # Per-metric search target on each metric's own scale
                     # (ssimulacra2 score 0–100, butteraugli distance 0–25, size
                     # bytes). A single cross-metric scalar is incoherent, so this
                     # is keyed by metric; built-in per-metric defaults apply where
                     # absent (size has no default — it stays required).
                     autoquality_target: [
                       type: {:map, :atom, {:or, [:integer, :float]}},
                       default: %{}
                     ],
                     # ... (keep min/max/format_* as-is) ...
                     # Per-metric symmetric tolerance band on the metric's own
                     # scale (ssimulacra2 points, butteraugli distance). Per-metric
                     # for the same reason as target; built-in defaults apply where
                     # absent (ssimulacra2 1.0, butteraugli 0.1). :size has no band.
                     autoquality_allowed_error: [
                       type: {:map, :atom, {:or, [:integer, :float]}},
                       default: %{}
                     ],
```

Leave `autoquality_min_quality`/`autoquality_max_quality` and `autoquality_format_min_quality`/`autoquality_format_max_quality` unchanged (single-global guardrail).

- [ ] **Step 4: Update `request_defaults/1`**

Change the two passthrough entries:

```elixir
      autoquality_target: Keyword.get(imgproxy_opts, :autoquality_target, %{}),
      autoquality_allowed_error: Keyword.get(imgproxy_opts, :autoquality_allowed_error, %{}),
```

(Leave `autoquality_min_quality: …, 70` / `autoquality_max_quality: …, 80` and the format maps as-is.)

- [ ] **Step 5: Add per-metric validation**

Extend `validate_quality_config!/1` (from Task 2) to also validate the two maps. Append before its final `:ok`:

```elixir
    validate_autoquality_target_config!(Keyword.fetch!(validated, :autoquality_target))
    validate_autoquality_allowed_error_config!(Keyword.fetch!(validated, :autoquality_allowed_error))
    :ok
  end

  @autoquality_metrics [:size, :ssimulacra2, :butteraugli]

  defp validate_autoquality_target_config!(target_map) do
    Enum.each(target_map, fn {metric, value} ->
      unless metric in @autoquality_metrics do
        raise ArgumentError,
              "invalid imgproxy config: autoquality_target has unknown metric #{inspect(metric)}"
      end

      valid? =
        case metric do
          :size -> is_integer(value) and value > 0
          :ssimulacra2 -> is_number(value) and value >= 0 and value <= 100
          :butteraugli -> is_number(value) and value >= 0 and value <= 25
        end

      unless valid? do
        raise ArgumentError,
              "invalid imgproxy config: autoquality_target #{inspect(metric)} (#{inspect(value)}) " <>
                "is out of range for that metric"
      end
    end)
  end

  defp validate_autoquality_allowed_error_config!(error_map) do
    Enum.each(error_map, fn {metric, value} ->
      unless metric in [:ssimulacra2, :butteraugli] do
        raise ArgumentError,
              "invalid imgproxy config: autoquality_allowed_error has unsupported metric " <>
                "#{inspect(metric)} (only :ssimulacra2/:butteraugli)"
      end

      unless is_number(value) and value >= 0 do
        raise ArgumentError,
              "invalid imgproxy config: autoquality_allowed_error #{inspect(metric)} " <>
                "(#{inspect(value)}) must be a non-negative number"
      end
    end)
  end
```

(Place the `@autoquality_metrics` attribute near the other module attributes if you prefer; inline above the helper is fine.)

Note: `validate_non_negative_number/1` (the old scalar custom validator at [imgproxy.ex:199](../../../lib/image_pipe/parser/imgproxy.ex#L199)) is no longer referenced by the schema after this change. Check for other callers (`grep validate_non_negative_number lib test`); if none, delete it in this step.

- [ ] **Step 6: Run to verify pass**

Run: `mise exec -- mix test test/parser/imgproxy_test.exs`
Expected: PASS for the new `describe`. (Existing autoquality config tests in this file using scalar shapes are fixed in Task 10.)

- [ ] **Step 7: Commit**

```bash
git add lib/image_pipe/parser/imgproxy.ex test/parser/imgproxy_test.exs
git commit -m "feat(imgproxy): per-metric autoquality target/allowed_error config"
```

---

### Task 9: `options.ex` — per-metric resolution, URL fields, #390 cleanup

**Files:**
- Modify: `lib/image_pipe/parser/imgproxy/options.ex`
- Test: `test/parser/imgproxy/options_test.exs`

- [ ] **Step 1: Write the failing tests**

Add to `test/parser/imgproxy/options_test.exs` (the `@map_defaults` use the new per-metric shape):

```elixir
describe "per-metric autoquality resolution" do
  # Pass the new map-shaped autoquality_allowed_error (%{}) so the OLD code reads
  # the map back as the literal allowed_error (red) until Task 9 lands.
  test "butteraugli without config gets base 70/80 guardrail and 0.1 allowed_error (no 1/100)" do
    out =
      resolve_output(
        %{quality_search: {:autoquality, [metric: :butteraugli]}},
        autoquality_min_quality: 70, autoquality_max_quality: 80, autoquality_allowed_error: %{}
      )

    assert %ImagePipe.Plan.Output.QualitySearch.Butteraugli{
             min_quality: 70, max_quality: 80, allowed_error: 0.1, url_min_quality: nil
           } = out.quality_search
  end

  test "ssim2 without config gets 1.0 allowed_error" do
    out =
      resolve_output(
        %{quality_search: {:autoquality, [metric: :ssimulacra2]}},
        autoquality_min_quality: 70, autoquality_max_quality: 80, autoquality_allowed_error: %{}
      )

    assert out.quality_search.allowed_error == 1.0
  end

  test "config target/allowed_error are read per metric and do not bleed across metrics" do
    defaults = [
      autoquality_target: %{ssimulacra2: 85},
      autoquality_allowed_error: %{ssimulacra2: 0.5},
      autoquality_min_quality: 70, autoquality_max_quality: 80
    ]

    # ssim2 reads its own entries
    ssim = resolve_output(%{quality_search: {:autoquality, [metric: :ssimulacra2]}}, defaults)
    assert ssim.quality_search.target == 85
    assert ssim.quality_search.allowed_error == 0.5

    # butteraugli ignores the ssim2-keyed config, falling to its built-ins
    butt = resolve_output(%{quality_search: {:autoquality, [metric: :butteraugli]}}, defaults)
    assert butt.quality_search.target == 1.0
    assert butt.quality_search.allowed_error == 0.1
  end

  test "URL min/max land on url_min_quality/url_max_quality, base stays config global" do
    out =
      resolve_output(
        %{quality_search: {:autoquality, [metric: :ssimulacra2, min_quality: 75, max_quality: 85]}},
        autoquality_min_quality: 70, autoquality_max_quality: 80
      )

    assert out.quality_search.min_quality == 70
    assert out.quality_search.max_quality == 80
    assert out.quality_search.url_min_quality == 75
    assert out.quality_search.url_max_quality == 85
  end
end
```

- [ ] **Step 2: Run to verify failure**

Run: `mise exec -- mix test test/parser/imgproxy/options_test.exs`
Expected: FAIL, each for its own reason: the two `allowed_error` tests get the map `%{}` back (old code reads `Keyword.get(defaults, :autoquality_allowed_error, default_error)` → `%{}`, not `0.1`/`1.0`); the cross-metric test errors (old `resolve_quality_search_target` passes the whole `%{ssimulacra2: 85}` map to `validate_target_range`, which rejects a non-number); the URL-fields test gets `url_min_quality == nil` (old `build_quality_metric` never sets it).

- [ ] **Step 3: Simplify `build_quality_search` dispatch + rewrite `build_quality_metric`**

In `lib/image_pipe/parser/imgproxy/options.ex`:

Replace the two metric dispatch clauses:
```elixir
  defp build_quality_search(:ssimulacra2, fields, defaults),
    do: build_quality_metric(QualitySearch.Ssimulacra2, :ssimulacra2, fields, defaults)

  defp build_quality_search(:butteraugli, fields, defaults),
    do: build_quality_metric(QualitySearch.Butteraugli, :butteraugli, fields, defaults)
```

Replace `build_quality_metric/7` with the 4-arity version (drops `default_min`/`default_max`/`default_error`):
```elixir
  defp build_quality_metric(struct_mod, metric, fields, defaults) do
    with {:ok, target} <- resolve_quality_search_target(metric, fields, defaults) do
      {:ok,
       struct(struct_mod, %{
         target: target,
         min_quality: Keyword.get(defaults, :autoquality_min_quality, 70),
         max_quality: Keyword.get(defaults, :autoquality_max_quality, 80),
         url_min_quality: Keyword.get(fields, :min_quality),
         url_max_quality: Keyword.get(fields, :max_quality),
         allowed_error: resolve_allowed_error(metric, fields, defaults),
         format_min: Keyword.get(defaults, :autoquality_format_min_quality, %{}),
         format_max: Keyword.get(defaults, :autoquality_format_max_quality, %{}),
         max_resolution: Keyword.get(defaults, :autoquality_max_resolution, 0)
       })}
    end
  end

  # URL arg → per-metric config map → built-in per-metric default. All candidates
  # are nil | non-negative number, and 0.0 is truthy, so `||` chaining is safe.
  defp resolve_allowed_error(metric, fields, defaults) do
    Keyword.get(fields, :allowed_error) ||
      Map.get(Keyword.get(defaults, :autoquality_allowed_error, %{}), metric) ||
      default_allowed_error(metric)
  end

  defp default_allowed_error(:ssimulacra2), do: 1.0
  defp default_allowed_error(:butteraugli), do: 0.1
```

- [ ] **Step 4: Add `url_min_quality`/`url_max_quality` to the `:size` builder**

In `build_quality_search(:size, fields, defaults)`, add the two URL fields to the `%QualitySearch.Size{...}`:
```elixir
         url_min_quality: Keyword.get(fields, :min_quality),
         url_max_quality: Keyword.get(fields, :max_quality),
```
(insert after the `max_quality:` line). The `:size` `min_quality`/`max_quality` already read the config global — leave them.

- [ ] **Step 5: Read the per-metric config target map**

Update `resolve_quality_search_target/3` to read the per-metric map instead of a scalar:
```elixir
  defp resolve_quality_search_target(metric, fields, defaults) do
    config_target = Map.get(Keyword.get(defaults, :autoquality_target, %{}), metric)

    case Keyword.get(fields, :target, config_target) do
      nil -> default_target(metric)
      target -> validate_target_range(metric, target)
    end
  end
```
(`validate_target_range/2` and `default_target/1` are unchanged.)

- [ ] **Step 6: Run to verify pass**

Run: `mise exec -- mix test test/parser/imgproxy/options_test.exs -- --only describe:"per-metric autoquality resolution"`

If the selector syntax differs, just run the file: `mise exec -- mix test test/parser/imgproxy/options_test.exs` — the new `describe` passes; pre-existing tests using the old scalar shapes still fail (fixed in Task 10).

- [ ] **Step 7: Commit**

```bash
git add lib/image_pipe/parser/imgproxy/options.ex test/parser/imgproxy/options_test.exs
git commit -m "fix(imgproxy): per-metric autoquality defaults; reachable butteraugli allowed_error (#390)"
```

---

### Task 10: Migrate existing autoquality tests to the new shapes; delete obsolete

**Files:**
- Modify: `test/parser/imgproxy/options_test.exs`, `test/parser/imgproxy_test.exs`

- [ ] **Step 1: Update scalar config-default usages to per-metric maps**

In `test/parser/imgproxy/options_test.exs`, the `autoquality resolution` describe block (~lines 258-368) passes scalar `autoquality_target:` / `autoquality_allowed_error:`. Convert each:
- `autoquality_target: 90.0` → `autoquality_target: %{ssimulacra2: 90.0}`
- `autoquality_target: 88.0` → `autoquality_target: %{ssimulacra2: 88.0}`
- `autoquality_target: 85.0` → `autoquality_target: %{ssimulacra2: 85.0}`
- `autoquality_target: bad` (the size test, ~line 339) → `autoquality_target: %{size: bad}`
- `autoquality_target: 40_000` (size, ~line 349) → `autoquality_target: %{size: 40_000}`
- `autoquality_allowed_error: 1.0` → `autoquality_allowed_error: %{ssimulacra2: 1.0}`

The `autoquality_min_quality: 70`/`autoquality_max_quality: 80` entries stay scalar (unchanged).

- [ ] **Step 2: Fix the bracket assertions that now read base vs URL**

The test at ~line 241 (`autoquality:ssim2:90:70:80:1`) asserts `min_quality: 70, max_quality: 80, allowed_error: 1.0`. With the precedence split, URL `70/80` now land on `url_min_quality`/`url_max_quality`, and `min_quality`/`max_quality` carry the config base (which here, with empty defaults, is the schema default `70/80`). Update the assertion to:

```elixir
    assert %ImagePipe.Plan.Output.QualitySearch.Ssimulacra2{
             target: 90.0,
             min_quality: 70,
             max_quality: 80,
             url_min_quality: 70,
             url_max_quality: 80,
             allowed_error: 1.0
           } = request.output.quality_search
```

(The base `min_quality`/`max_quality` come from `request_defaults`' `70/80`; `Options.parse/3` with no defaults uses the inline `Keyword.get(defaults, :autoquality_min_quality, 70)` fallbacks — verify the value and adjust if your `defaults` arg omits them. The URL `1` for allowed_error lands on `allowed_error: 1.0`.)

- [ ] **Step 3: Update the "bare ssim2 fills …" test (~line 259)**

`allowed_error` now resolves to the ssim2 built-in `1.0` when config omits it. With `autoquality_allowed_error` no longer a scalar default, the assertion `allowed_error == 1.0` still holds (built-in), so keep it — but the defaults list must drop the scalar `autoquality_allowed_error: 1.0` (or convert to `%{ssimulacra2: 1.0}`). Keep `autoquality_target: %{ssimulacra2: 90.0}`.

- [ ] **Step 4: Scope check — what to delete vs migrate (do NOT over-delete)**

Confirmed by review: this file has **no** test asserting butteraugli's old `1/100` bracket, and **no** test calls the private `build_quality_metric` directly — so there is nothing to delete on those grounds. Critically, do **not** grep `min_quality: 1`/`max_quality: 100` across `test/` and delete matches: those literals appear in `test/image_pipe/output/encode_search_test.exs`, `test/image_pipe/output_policy_test.exs`, and `test/image_pipe/plan/output/quality_search_test.exs` as **arbitrary bracket values** exercising the encode-search loop and Policy resolution — they are unique, still-valid coverage; leave them. The obsolete butteraugli-default tests in *this* file (e.g. the `target:`/`allowed_error:`-based ones ~lines 359-367) are **migrated** (scalar→map) in Steps 1-3, not deleted. In `test/parser/imgproxy_test.exs`, convert any scalar `autoquality_target:`/`autoquality_allowed_error:` config tests to the map shape (or drop only if Task 8's `describe` already covers the exact case). Net: Task 10 is migration-only — no behavioral coverage is removed.

- [ ] **Step 5: Run both files to verify pass**

Run: `mise exec -- mix test test/parser/imgproxy/options_test.exs test/parser/imgproxy_test.exs`
Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add test/parser/imgproxy/options_test.exs test/parser/imgproxy_test.exs
git commit -m "test(imgproxy): migrate autoquality config tests to per-metric maps"
```

---

### Task 11: Wire-level autoquality precedence decode check

**Files:**
- Test: `test/image_pipe/imgproxy_wire_conformance_test.exs`

- [ ] **Step 1: Write the test**

Add a wire test (mirroring the file's helpers): host config sets `autoquality_method: :ssimulacra2`, `autoquality_format_min_quality: %{avif: 60}`, `autoquality_format_max_quality: %{avif: 65}`; one request omits URL min/max (resolves to the avif 60–65 config bracket), another supplies `autoquality:ssim2:<target>:80:90` (URL bracket 80–90 wins). Request AVIF via `Accept`. Assert both succeed as AVIF and that the URL-override request produces a larger file (higher Q floor) than the config-bracket request — proving URL min/max won.

```elixir
test "URL autoquality min/max override the per-format config bracket (avif)" do
  opts =
    imgproxy_opts(
      autoquality_method: :ssimulacra2,
      autoquality_target: %{ssimulacra2: 90},
      autoquality_format_min_quality: %{avif: 60},
      autoquality_format_max_quality: %{avif: 65}
    )

  config_conn = call(~p"/rs:fit:300:300/plain/#{source_url()}", accept: "image/avif", opts: opts)
  url_conn = call(~p"/autoquality:ssim2:90:80:90/rs:fit:300:300/plain/#{source_url()}", accept: "image/avif", opts: opts)

  assert content_type(config_conn) == "image/avif"
  assert content_type(url_conn) == "image/avif"
  # URL bracket 80..90 forces a higher quality floor than config 60..65.
  assert byte_size(url_conn.resp_body) > byte_size(config_conn.resp_body)
end
```

- [ ] **Step 2: Run to verify pass**

Run: `mise exec -- mix test test/image_pipe/imgproxy_wire_conformance_test.exs`
Expected: PASS. (If the size assertion is flaky on the chosen source, pick a photographic source where the ssim2 target lands inside both brackets so the bracket floor is the binding constraint.)

- [ ] **Step 3: Commit**

```bash
git add test/image_pipe/imgproxy_wire_conformance_test.exs
git commit -m "test(imgproxy): wire check for URL autoquality bracket override"
```

---

# Part 3 — Docs & full-suite reconciliation

### Task 12: Support matrix + full suite + fixture reconciliation

**Files:**
- Modify: `docs/imgproxy_support_matrix.md`

- [ ] **Step 1: Update the support matrix — surface axis**

In `docs/imgproxy_support_matrix.md`, add to the config/option tables:
- Host config `quality` (global default, 80) and `format_quality` (per-format default; `webp 79 / avif 63 / jpeg_xl 77`) — mirrors `IMGPROXY_QUALITY` / `IMGPROXY_FORMAT_QUALITY`.
- `autoquality_target` / `autoquality_allowed_error` are now per-metric maps.
- The autoquality precedence rule: URL `autoquality:…:min:max` args override per-format config bounds (per-format config remains the default when the URL omits them).

- [ ] **Step 2: Update the support matrix — behavioral/pixel axis**

In the behavioral/divergence section, note that default output quality now matches imgproxy's values (global 80; webp 79 / avif 63 / jxl 77), replacing the previous reliance on libvips' per-format defaults. Note the disclosed PNG divergence (ImagePipe applies an explicit URL `q`/`fq` to PNG; imgproxy ignores quality for PNG entirely — scoped as a follow-up).

- [ ] **Step 3: Run the focused gate**

Run: `mise exec -- mix format --check-formatted`
Run: `mise exec -- mix compile --warnings-as-errors`
Run: `mise exec -- mix credo --strict`
Fix any formatting/credo issues; re-run until clean.

- [ ] **Step 4: Run the full test suite and reconcile fixture drift**

Run: `mise exec -- mix test`

Expected behavioral fallout (assess each):
- **Wire-conformance / cache-key / ETag tests** that assumed libvips default output bytes may now differ because defaults changed. Where the new bytes are correct (config Q applied), update the expected values in place (greenfield; no cache-version bump). Confirm each diff is *explained by the quality change*, not an unrelated regression.
- **Differential conformance:** if `test/.../imgproxy_differential` fixtures shift, follow its README (`bake → diagnose → tolerance → quarantine`). Re-bake **only** via `mise run diff:bake`; do not hand-edit fixtures. Matching imgproxy values should *reduce* skew. No source images change, so `SourceInventory` is unaffected — confirm `git status` shows no `sources/` churn.

This step is a judgment call on measured output and must run inline (not delegated to a subagent).

- [ ] **Step 5: Commit**

```bash
git add docs/imgproxy_support_matrix.md
# plus any fixture/expected-value updates made in Step 4
git commit -m "docs(imgproxy): quality-model rework — surface + behavioral matrix updates"
```

---

## Self-Review

**Spec coverage:**
- #389-a default quality (config + values + resolution order + PNG gate) → Tasks 1–5. ✓
- #389-b URL-wins precedence → Tasks 6, 7 (incl. cache-key fold-in so the URL bracket selects the right stored variant). ✓
- #390 cleanup (delete dead min/max defaults; 70/80 universal) → Task 9 (`build_quality_metric` 4-arity drops `default_min`/`default_max`). ✓
- Per-metric `target`/`allowed_error` (both scale-dependent knobs) → Tasks 8, 9. ✓
- Validation at config boundary → Tasks 2, 8. ✓ (URL-pair inversion already handled in the grammar — confirmed, no task needed.)
- Tests (parser/planner, policy, wire) → Tasks 3, 4, 5, 7, 9, 10, 11. ✓
- Docs + fixture reconciliation → Task 12. ✓
- Fiddle unchanged → no task (host-config only). ✓ (correct per spec)

**Placeholder scan:** No TBD/TODO; every implementation step shows the actual code. The two wire tests (Tasks 5, 11) use `imgproxy_opts`/`call`/`source_url`/`content_type` placeholders that must be aligned to the file's real helpers — flagged explicitly in each step (the engineer reads two existing tests first).

**Type/signature consistency:**
- `default_quality` field name consistent across `Plan.Output` (Task 1), parser resolution (Task 3), Policy struct + `from_output_plan` + `effective_quality` (Task 4). ✓
- `url_min_quality`/`url_max_quality` consistent across structs (Task 6), `resolve_search` (Task 7), `build_quality_metric`/`:size` builder (Task 9). ✓
- `build_quality_metric` changes from 7-arity to 4-arity in Task 9; the two `build_quality_search` dispatch clauses are updated in the same step; obsolete 7-arity test callers deleted in Task 10. ✓
- `resolve_allowed_error/3` + `default_allowed_error/1` defined in Task 9, used only there. ✓
- `validate_quality_config!/1` defined in Task 2, extended in Task 8 (same function) — Task 8 appends the two map validators before the trailing `:ok`. ✓

**Dependency order:** Part 1 (1→2→3→4→5) and Part 2 (6→7→8→9→10→11) each form a clean chain; Task 9 depends on the struct fields (6) and config shape (8); Task 7 depends on the struct fields (6). Order respects this. ✓
