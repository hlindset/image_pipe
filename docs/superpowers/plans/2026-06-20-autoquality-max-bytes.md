# Autoquality + max_bytes Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a best-effort encode-quality search at the output boundary that backs imgproxy `autoquality`/`aq` (#344) and `max_bytes`/`mb` (#83), using SSIMULACRA2 (via the `ssimulacra2` package) for the perceptual method.

**Architecture:** One shared binary search over the encoder quality knob, bypassed entirely when not requested. Declarative knobs live on `ImagePipe.Plan.Output` (product-neutral); the imgproxy parser translates its syntax in. Per-format quality brackets resolve after format negotiation in `Output.Policy`. The loop lives in a new `ImagePipe.Output.EncodeSearch` driven from `ImagePipe.Output.Encoder`; SSIMULACRA2 is isolated behind a thin `ImagePipe.Output.Ssim2Metric` adapter.

**Tech Stack:** Elixir, libvips via `Vix`/`image`, `ssimulacra2` (Rust NIF), `:telemetry`, Plug. Tests are ExUnit + StreamData; wire tests make real `ImagePipe.call/2` requests.

**Spec:** `docs/superpowers/specs/2026-06-20-autoquality-max-bytes-design.md` — read it before starting. Section references (§N) below point into it.

**Conventions for every task:**
- Run everything through `mise exec -- ...`. On a fresh worktree first run `mise trust && mise exec -- mix deps.get` (see the memory notes about worktree mise trust and the dangling `.credo.exs` symlink).
- TDD: failing test first, watch it fail, minimal implementation, watch it pass, commit.
- After a phase that changes behavior, run `mise exec -- mix compile --warnings-as-errors` and the focused test files. Run `mise run precommit` before the final phase; `mise run precommit:fiddle` after the fiddle phase.

---

## File Structure

**Create:**
- `lib/image_pipe/plan/output/quality_search.ex` — `ImagePipe.Plan.Output.QualitySearch` (native declarative descriptor; pre-resolution, carries per-format maps + `max_resolution`).
- `lib/image_pipe/output/resolved_quality_search.ex` — `ImagePipe.Output.ResolvedQualitySearch` (post-negotiation, format-clamped bracket; what the loop consumes).
- `lib/image_pipe/output/ssim2_metric.ex` — `ImagePipe.Output.Ssim2Metric` (thin adapter over the `ssimulacra2` package; the only module that names `Ssimulacra2.*`).
- `lib/image_pipe/output/encode_search.ex` — `ImagePipe.Output.EncodeSearch` (the loop: buffer-encode candidate, measure, binary search, composition, best-effort).
- Test files mirrored under `test/image_pipe/...` as noted per task.

**Modify:**
- `lib/image_pipe/plan/output.ex` — add `quality_search`, `max_bytes` fields + types.
- `lib/image_pipe/output/resolved.ex` — add `quality_search`, `max_bytes` fields + types.
- `lib/image_pipe/parser/imgproxy/option_grammar.ex` — `autoquality`/`aq` bespoke clause; `max_bytes`/`mb` spec.
- `lib/image_pipe/parser/imgproxy/parsed_request.ex` — carry the two fields.
- `lib/image_pipe/parser/imgproxy/options.ex` — merge parsed values into `output`; resolve config defaults.
- `lib/image_pipe/parser/imgproxy.ex` — extend `request_defaults/1` with the `autoquality_*` host opts.
- `lib/image_pipe/parser/imgproxy/plan_builder.ex` — emit `quality_search` + `max_bytes` onto `Plan.Output`.
- `lib/image_pipe/output/policy.ex` — carry fields; resolve per-format bracket + `max_resolution` skip in `resolved/2`.
- `lib/image_pipe/output/encoder.ex` — finalize once; buffer-encode path; dispatch to `EncodeSearch`.
- `lib/image_pipe/output.ex` + `test/image_pipe/architecture_boundary_test.exs` — widen the `output` boundary to depend on `Telemetry` (Task 15a). The `[:encode, :search]` span/probe are emitted **directly** from `EncodeSearch` (output boundary), nested inside the producer's existing `[:encode]` span — matching the `transform` boundary precedent. The producer needs **no** change.
- `lib/image_pipe/format.ex` — add `supports_quality?/1` (Task 14a).
- `lib/image_pipe/telemetry/logger.ex` — subscribe + render + level for the new events.
- `lib/image_pipe/cache/key.ex` — include `quality_search` + `max_bytes` in output key data.
- `mix.exs` — add `ssimulacra2`.
- `mise.toml` — pin Rust.
- `fiddle/assets/...` — controls + URL state.
- `docs/imgproxy_support_matrix.md`, `docs/telemetry.md` — conformance + telemetry docs.

---

## Phase 0 — Dependency & toolchain

### Task 1: Add the `ssimulacra2` dependency and pin Rust

**Files:**
- Modify: `mix.exs` (deps list, around line 132)
- Modify: `mise.toml`

- [ ] **Step 1: Add the dep**

In `mix.exs` `deps/0`, add after the `{:image, ...}` line:

```elixir
{:ssimulacra2, github: "hlindset/ssimulacra2", ref: "25df45cd33a0e3af6435cfc269a5fccfb83d3f0d"},
```

- [ ] **Step 2: Pin Rust in `mise.toml`**

Add a `rust` entry under `[tools]` (match the existing TOML style in the file). Use the current stable, e.g.:

```toml
rust = "1.83"
```

- [ ] **Step 3: Fetch and compile the dep**

Run: `mise exec -- mix deps.get && mise exec -- mix deps.compile ssimulacra2`
Expected: the Rust NIF compiles (first build is slow). If it fails, confirm the Rust toolchain resolved (`mise exec -- rustc --version`).

- [ ] **Step 4: Smoke-check the package API surface**

Run: `mise exec -- iex -S mix` then in the shell:

```elixir
Ssimulacra2.__info__(:functions)
Ssimulacra2.Reference.__info__(:functions)
Ssimulacra2.Vix.__info__(:functions)
```

Record the real function names/arities — Task 12 wires `Ssim2Metric` to them. The spec assumes "precompute a reference once, compare each candidate from in-memory Vix images"; adapt the adapter to the actual spelling.

- [ ] **Step 5: Commit**

```bash
git add mix.exs mix.lock mise.toml
git commit -m "build: add ssimulacra2 dep (git SHA) and pin Rust toolchain"
```

---

## Phase 1 — Native model

### Task 2: `Plan.Output.QualitySearch` struct

**Files:**
- Create: `lib/image_pipe/plan/output/quality_search.ex`
- Test: `test/image_pipe/plan/output/quality_search_test.exs`

- [ ] **Step 1: Write the failing test**

```elixir
defmodule ImagePipe.Plan.Output.QualitySearchTest do
  use ExUnit.Case, async: true
  alias ImagePipe.Plan.Output.QualitySearch

  test "builds a size objective with defaults for optional fields" do
    s = %QualitySearch{objective: :size, target: 10_240, min_quality: 10, max_quality: 80}
    assert s.allowed_error == 0
    assert s.format_min == %{}
    assert s.format_max == %{}
    assert s.max_resolution == 0
  end

  test "builds an ssim2 objective" do
    s = %QualitySearch{
      objective: :ssim2,
      target: 90.0,
      min_quality: 70,
      max_quality: 80,
      allowed_error: 1.0,
      format_min: %{avif: 60},
      format_max: %{avif: 65}
    }

    assert s.objective == :ssim2
    assert s.format_min == %{avif: 60}
  end

  test "enforces required keys" do
    assert_raise ArgumentError, fn ->
      struct!(QualitySearch, objective: :size, target: 1)
    end
  end
end
```

- [ ] **Step 2: Run it, expect failure** — `mise exec -- mix test test/image_pipe/plan/output/quality_search_test.exs` → fails (module undefined).

- [ ] **Step 3: Implement**

```elixir
defmodule ImagePipe.Plan.Output.QualitySearch do
  @moduledoc """
  Declarative encode-quality search objective (imgproxy `autoquality`), before
  format negotiation. `target` is a SSIMULACRA2 score (0–100) for `:ssim2` or a
  byte count for `:size`. The bracket (`min_quality`/`max_quality`) bounds the
  encoder quality knob; `format_min`/`format_max` clamp it per output format and
  are resolved away in `ImagePipe.Output.Policy`. `max_resolution` (megapixels,
  0 = off) skips the search on oversized results. See the design spec §3.
  """

  @enforce_keys [:objective, :target, :min_quality, :max_quality]
  defstruct @enforce_keys ++ [allowed_error: 0, format_min: %{}, format_max: %{}, max_resolution: 0]

  @type objective :: :size | :ssim2
  @type format :: ImagePipe.Format.output_format()
  @type t :: %__MODULE__{
          objective: objective(),
          target: number(),
          min_quality: 1..100,
          max_quality: 1..100,
          allowed_error: number(),
          format_min: %{optional(format()) => 1..100},
          format_max: %{optional(format()) => 1..100},
          max_resolution: non_neg_integer()
        }
end
```

- [ ] **Step 4: Run it, expect pass.**
- [ ] **Step 5: Commit** — `git add lib/image_pipe/plan/output/quality_search.ex test/... && git commit -m "feat(plan): add Output.QualitySearch descriptor"`

### Task 3: `Plan.Output` fields

**Files:**
- Modify: `lib/image_pipe/plan/output.ex`
- Test: `test/image_pipe/plan/output_test.exs` (create if absent)

- [ ] **Step 1: Failing test**

```elixir
defmodule ImagePipe.Plan.OutputTest do
  use ExUnit.Case, async: true
  alias ImagePipe.Plan.Output

  test "defaults quality_search to :none and max_bytes to nil" do
    o = %Output{mode: :automatic}
    assert o.quality_search == :none
    assert o.max_bytes == nil
  end
end
```

- [ ] **Step 2: Run, expect fail** (fields don't exist).
- [ ] **Step 3: Implement** — in `lib/image_pipe/plan/output.ex` add to `defstruct` (after `flatten_background`): `quality_search: :none, max_bytes: nil`. Extend `@type t` with `quality_search: :none | ImagePipe.Plan.Output.QualitySearch.t()` and `max_bytes: nil | pos_integer()`. Add a `@moduledoc` sentence noting both are resolved defaults. (Do **not** add them to `@enforce_keys`; they have struct defaults.)
- [ ] **Step 4: Run, expect pass.**
- [ ] **Step 5: Commit.**

### Task 4: `Output.ResolvedQualitySearch` + `Output.Resolved` fields

**Files:**
- Create: `lib/image_pipe/output/resolved_quality_search.ex`
- Modify: `lib/image_pipe/output/resolved.ex`
- Test: `test/image_pipe/output/resolved_test.exs` (create if absent)

- [ ] **Step 1: Failing test**

```elixir
defmodule ImagePipe.Output.ResolvedTest do
  use ExUnit.Case, async: true
  alias ImagePipe.Output.Resolved
  alias ImagePipe.Output.ResolvedQualitySearch

  test "Resolved carries quality_search and max_bytes, defaulting off" do
    r = %Resolved{
      format: :jpeg,
      quality: :default,
      response_headers: [],
      strip_metadata: true,
      keep_copyright: true,
      color_profile: :strip
    }

    assert r.quality_search == :none
    assert r.max_bytes == nil
  end

  test "ResolvedQualitySearch holds a format-clamped bracket" do
    s = %ResolvedQualitySearch{
      objective: :ssim2,
      target: 90.0,
      min_quality: 60,
      max_quality: 65,
      allowed_error: 1.0
    }

    assert s.min_quality == 60 and s.max_quality == 65
  end
end
```

- [ ] **Step 2: Run, expect fail.**
- [ ] **Step 3: Implement**

`lib/image_pipe/output/resolved_quality_search.ex`:

```elixir
defmodule ImagePipe.Output.ResolvedQualitySearch do
  @moduledoc """
  Encode-quality search objective resolved against the negotiated output format:
  the bracket is already per-format clamped, and the per-format maps /
  `max_resolution` have been consumed. Consumed by `ImagePipe.Output.EncodeSearch`.
  """

  @enforce_keys [:objective, :target, :min_quality, :max_quality]
  defstruct @enforce_keys ++ [allowed_error: 0, max_resolution: 0]

  @type t :: %__MODULE__{
          objective: :size | :ssim2,
          target: number(),
          min_quality: 1..100,
          max_quality: 1..100,
          allowed_error: number(),
          max_resolution: non_neg_integer()
        }
end
```

`max_resolution` rides along (default 0 = off) so `EncodeSearch.skip?/2` can read it from the single resolved descriptor; it is set during Policy resolution (Task 10). Add a matching `max_resolution: 0` assertion to the Task 4 struct test.

In `lib/image_pipe/output/resolved.ex`: add `quality_search: :none` and `max_bytes: nil` to `defstruct` (the `@enforce_keys ++ [...]` tail), and extend `@type t` with `quality_search: :none | ImagePipe.Output.ResolvedQualitySearch.t()` and `max_bytes: nil | pos_integer()`.

- [ ] **Step 4: Run, expect pass.**
- [ ] **Step 5: Commit.**

---

## Phase 2 — imgproxy parser

> Read `lib/image_pipe/parser/imgproxy/option_grammar.ex` (the `@special_specs` map, `parse_special_option/3`, `parse_known_option/4`, `scoped_assignments/2`, and the `resize` bespoke clause as the template for irregular arity) and `parse_field/2` / the `parse_quality` helper before editing.

### Task 5: `max_bytes`/`mb` grammar

**Files:**
- Modify: `lib/image_pipe/parser/imgproxy/option_grammar.ex`
- Modify: `lib/image_pipe/parser/imgproxy/parsed_request.ex` (add `max_bytes: nil` to defstruct + type)
- Modify: `lib/image_pipe/parser/imgproxy/options.ex` (merge `max_bytes` into `output`)
- Test: `test/image_pipe/parser/imgproxy/option_grammar_test.exs`

- [ ] **Step 1: Failing test** (add to the existing grammar test file)

```elixir
test "parses max_bytes and its mb alias into the output scope" do
  assert {:ok, {:output, [max_bytes: 51_200]}} =
           ImagePipe.Parser.Imgproxy.OptionGrammar.parse_segment("max_bytes:51200")

  assert {:ok, {:output, [max_bytes: 51_200]}} =
           ImagePipe.Parser.Imgproxy.OptionGrammar.parse_segment("mb:51200")
end

test "mb:0 disables the ceiling (no-op), matching imgproxy" do
  assert {:ok, {:output, [max_bytes: nil]}} =
           ImagePipe.Parser.Imgproxy.OptionGrammar.parse_segment("mb:0")
end

test "rejects negative or malformed max_bytes" do
  assert {:error, _} = ImagePipe.Parser.Imgproxy.OptionGrammar.parse_segment("mb:-5")
  assert {:error, _} = ImagePipe.Parser.Imgproxy.OptionGrammar.parse_segment("mb:abc")
end
```

> Confirm the actual public entry point name for parsing one segment in that module (it may be `parse_segment/1` or similar); adjust the calls to match. If only a higher-level entry exists, assert through it.

> **imgproxy parity (compat review):** imgproxy parses `max_bytes` with `parsePositiveInt` (guard `i < 0`), and `processing.go` gates on `maxBytes > 0`. So `0` is **valid and disables** the ceiling — not a 4xx. Map `0 -> nil`; reject only negatives / non-numeric.

- [ ] **Step 2: Run, expect fail.**
- [ ] **Step 3: Implement** — add aliases to the option map (near line 49-66): `"max_bytes" => {:max_bytes, [:max_bytes]}, "mb" => {:max_bytes, [:max_bytes]}`. Add a `parse_known_option(:max_bytes, [:max_bytes], [value], segment)` clause that parses a **non-negative** integer; map `0 -> [max_bytes: nil]` (disabled), `n > 0 -> [max_bytes: n]`; reject negatives/non-numeric with the canonical invalid-option tag. Add `:max_bytes` to the `scoped_assignments/2` `:output` group.
- [ ] **Step 4: Run, expect pass.**
- [ ] **Step 5: Commit.**

### Task 6: `autoquality`/`aq` per-method grammar

**Files:**
- Modify: `lib/image_pipe/parser/imgproxy/option_grammar.ex`
- Modify: `lib/image_pipe/parser/imgproxy/parsed_request.ex` (add `quality_search: :none`)
- Test: `test/image_pipe/parser/imgproxy/option_grammar_test.exs`

Behavior to encode (spec §4.1–4.2). The parser emits a partial descriptor — **only the fields present in the URL** — as `{:output, [quality_search: {:autoquality, fields}]}`; missing fields are filled from config defaults in Task 8. Represent it as a tagged keyword (e.g. `{:autoquality, [objective: :ssim2, target: 90.0, ...]}`) or `:none` / `{:autoquality, :disabled}` for `autoquality:none`. Pick one shape and keep it consistent through Tasks 8–9.

- [ ] **Step 1: Failing tests**

```elixir
alias ImagePipe.Parser.Imgproxy.OptionGrammar, as: G

test "autoquality:none disables the search" do
  assert {:ok, {:output, [quality_search: {:autoquality, :disabled}]}} = G.parse_segment("autoquality:none")
  assert {:ok, {:output, [quality_search: {:autoquality, :disabled}]}} = G.parse_segment("aq:none")
end

test "autoquality:size with full args" do
  assert {:ok, {:output, [quality_search: {:autoquality, fields}]}} = G.parse_segment("autoquality:size:10240:10:80")
  assert fields[:objective] == :size
  assert fields[:target] == 10_240
  assert fields[:min_quality] == 10
  assert fields[:max_quality] == 80
  refute Keyword.has_key?(fields, :allowed_error)
end

test "autoquality:ssim2 with full args" do
  assert {:ok, {:output, [quality_search: {:autoquality, fields}]}} = G.parse_segment("autoquality:ssim2:90:70:80:1")
  assert fields[:objective] == :ssim2
  assert fields[:target] == 90.0
  assert fields[:allowed_error] == 1.0
end

test "trailing args are optional (config fills the rest)" do
  assert {:ok, {:output, [quality_search: {:autoquality, fields}]}} = G.parse_segment("autoquality:ssim2:90")
  assert fields[:objective] == :ssim2 and fields[:target] == 90.0
  refute Keyword.has_key?(fields, :min_quality)
end

test "bare dssim is accepted as an ssim2 alias with no inline args" do
  assert {:ok, {:output, [quality_search: {:autoquality, fields}]}} = G.parse_segment("autoquality:dssim")
  assert fields[:objective] == :ssim2
  refute Keyword.has_key?(fields, :target)
end

test "dssim with inline args is rejected" do
  assert {:error, _} = G.parse_segment("autoquality:dssim:0.02:70:80:0.001")
  assert {:error, _} = G.parse_segment("autoquality:dssim:90")
end

test "ml and unknown methods are rejected" do
  assert {:error, _} = G.parse_segment("autoquality:ml:0.02:70:80:0.001")
  assert {:error, _} = G.parse_segment("autoquality:bogus")
end

test "min greater than max is rejected" do
  assert {:error, _} = G.parse_segment("autoquality:size:10240:80:10")
end
```

- [ ] **Step 2: Run, expect fail.**
- [ ] **Step 3: Implement** — add `"autoquality" => ...` / `"aq" => ...` to the option-name map routing to a bespoke `parse_special_option("autoquality", args, segment)` clause (mirror the `resize` irregular-arity clause). In it, switch on the first arg (method):
  - `"none"` → `{:ok, [quality_search: {:autoquality, :disabled}]}`
  - `"size"` → parse up to `[target_bytes, min, max]` (all optional after method): target = positive int; min/max = `1..100`. Emit `objective: :size` + present fields.
  - `"ssim2"` → parse up to `[target, min, max, allowed_error]`: target = float in `0.0..100.0`; min/max = `1..100`; allowed_error = non-negative float. Emit `objective: :ssim2` + present fields.
  - `"dssim"` → if **any** extra args, `{:error, {:invalid_option, :autoquality, segment}}`; else `{:ok, [quality_search: {:autoquality, [objective: :ssim2]}]}`.
  - anything else (incl. `"ml"`) → `{:error, {:invalid_option, :autoquality, segment}}`.
  - When both min and max are present, reject `min > max`.
  Route `:autoquality`/the `quality_search` assignment to the `:output` scope in `scoped_assignments/2`.
- [ ] **Step 4: Run, expect pass.**
- [ ] **Step 5: Commit.**

### Task 7: Carry parsed fields onto `ParsedRequest.output`

**Files:**
- Modify: `lib/image_pipe/parser/imgproxy/options.ex` (the reducer that folds `{:output, assignments}` — see the `format_qualities` merge around line 250)
- Test: extend `test/image_pipe/parser/imgproxy/options_test.exs` (or the relevant options test)

- [ ] **Step 1: Failing test** — assert that folding `{:output, [quality_search: {:autoquality, [...]}]}` and `{:output, [max_bytes: N]}` lands on the accumulated `output` map as `:quality_search` (raw tagged form) and `:max_bytes`.
- [ ] **Step 2: Run, expect fail.**
- [ ] **Step 3: Implement** — add reducer clauses: `{:max_bytes, n}` → `%{output | max_bytes: n}`; `{:quality_search, raw}` → `%{output | quality_search: raw}` (last-wins, consistent with other scalar output options). Keep the raw tagged form here; resolution to a struct happens in Task 8.
- [ ] **Step 4: Run, expect pass.**
- [ ] **Step 5: Commit.**

### Task 8: Config defaults + descriptor resolution

**Files:**
- Modify: `lib/image_pipe/parser/imgproxy.ex` (`request_defaults/1`, ~line 230)
- Modify: `lib/image_pipe/parser/imgproxy/options.ex` (`apply_request_defaults/2` / a new `resolve_quality_search_defaults/2`, ~line 302)
- Test: `test/image_pipe/parser/imgproxy/options_test.exs`

Spec §4.3. Resolve the raw `{:autoquality, fields}` (or `:disabled`/absent) into a concrete `%Plan.Output.QualitySearch{}` or `:none`, merging config defaults for omitted fields.

- [ ] **Step 1: Failing tests**

```elixir
test "bare ssim2 fills target/bracket/allowed_error/per-format from config defaults" do
  defaults = [
    autoquality_target: 90.0,
    autoquality_min_quality: 70,
    autoquality_max_quality: 80,
    autoquality_allowed_error: 1.0,
    autoquality_format_min_quality: %{avif: 60},
    autoquality_format_max_quality: %{avif: 65},
    autoquality_max_resolution: 0
  ]

  out = resolve_output(%{quality_search: {:autoquality, [objective: :ssim2]}}, defaults)
  assert %ImagePipe.Plan.Output.QualitySearch{} = out.quality_search
  assert out.quality_search.objective == :ssim2
  assert out.quality_search.target == 90.0
  assert out.quality_search.min_quality == 70
  assert out.quality_search.max_quality == 80
  assert out.quality_search.allowed_error == 1.0
  assert out.quality_search.format_min == %{avif: 60}
  assert out.quality_search.max_resolution == 0
end

test "autoquality:none resolves to :none regardless of config method" do
  out = resolve_output(%{quality_search: {:autoquality, :disabled}}, [autoquality_method: :ssim2])
  assert out.quality_search == :none
end

test "absent autoquality falls back to the config method (:none default => off)" do
  out = resolve_output(%{quality_search: :none}, [])
  assert out.quality_search == :none
end

test "config method ssim2 with no URL autoquality enables the search from config" do
  defaults = [autoquality_method: :ssim2, autoquality_target: 88.0, autoquality_min_quality: 70, autoquality_max_quality: 80, autoquality_allowed_error: 1.0]
  out = resolve_output(%{quality_search: :none}, defaults)
  assert out.quality_search.objective == :ssim2
  assert out.quality_search.target == 88.0
end

test "size method without a target (URL or config) is an invalid option" do
  assert {:error, _} = resolve_output_result(%{quality_search: {:autoquality, [objective: :size]}}, [autoquality_method: :none])
end
```

> `resolve_output/2` / `resolve_output_result/2` are small test helpers that build the parsed `output` map and run it through the resolution function; write them to match the real function you add.

- [ ] **Step 2: Run, expect fail.**
- [ ] **Step 3: Implement**
  - In `imgproxy.ex` `request_defaults/1`, append the `autoquality_*` host opts with the spec §4.3 imgproxy-adapter defaults:

    ```elixir
    autoquality_method: Keyword.get(imgproxy_opts, :autoquality_method, :none),
    autoquality_target: Keyword.get(imgproxy_opts, :autoquality_target),
    autoquality_min_quality: Keyword.get(imgproxy_opts, :autoquality_min_quality, 70),
    autoquality_max_quality: Keyword.get(imgproxy_opts, :autoquality_max_quality, 80),
    autoquality_allowed_error: Keyword.get(imgproxy_opts, :autoquality_allowed_error, 1.0),
    autoquality_format_min_quality: Keyword.get(imgproxy_opts, :autoquality_format_min_quality, %{avif: 60}),
    autoquality_format_max_quality: Keyword.get(imgproxy_opts, :autoquality_format_max_quality, %{avif: 65}),
    autoquality_max_resolution: Keyword.get(imgproxy_opts, :autoquality_max_resolution, 0)
    ```

  - In `options.ex`, add `resolve_quality_search_defaults(output, defaults)` called from `apply_request_defaults/2` (alongside `resolve_metadata_defaults`). Logic:
    - Determine effective method: URL form wins; `{:autoquality, :disabled}` → `:none`; `{:autoquality, fields}` → `fields[:objective]`; `:none`/absent → `defaults[:autoquality_method]`.
    - If method is `:none` → set `output.quality_search = :none`.
    - Else build `%Plan.Output.QualitySearch{}` filling each field from URL-present value else config default. For `:size`, require a target (URL or `autoquality_target`); if none, return `{:error, {:invalid_option, :autoquality, :missing_target}}`. For `:ssim2`, `allowed_error`/`format_*`/`max_resolution` come from config when absent.
    - This function must thread an error out (the surrounding pipeline already returns tagged errors before side effects — match its shape).
  - `max_bytes` needs no default resolution (per-request only); it stays as parsed (or `nil`).
- [ ] **Step 4: Run, expect pass.**
- [ ] **Step 5: Commit.**

### Task 9: Emit onto `Plan.Output` in the plan builder

**Files:**
- Modify: `lib/image_pipe/parser/imgproxy/plan_builder.ex` (the `Output` construction, ~lines 115-137)
- Test: `test/image_pipe/parser/imgproxy/plan_builder_test.exs` (or the parser-to-plan test)

- [ ] **Step 1: Failing test** — build a plan from a request whose resolved `output` carries a `%QualitySearch{}` + `max_bytes`, assert `plan.output.quality_search` / `plan.output.max_bytes` are populated.
- [ ] **Step 2: Run, expect fail.**
- [ ] **Step 3: Implement** — add `quality_search: request.quality_search` (or `request.output.quality_search`, matching how other output fields are threaded) and `max_bytes: request.max_bytes` to the `%Output{...}` map(s) in both builder branches (line ~117 and ~135).
- [ ] **Step 4: Run, expect pass.**
- [ ] **Step 5: Commit.**

---

## Phase 3 — Resolution (Policy)

### Task 10: Carry fields + per-format bracket clamp + `max_resolution` skip

**Files:**
- Modify: `lib/image_pipe/output/policy.ex` (the struct + `from_output_plan/3` both clauses + `resolved/2`)
- Test: `test/image_pipe/output/policy_test.exs`

Spec §5. `resolved/2` is where the negotiated `format` is known — clamp the bracket there.

- [ ] **Step 1: Failing tests**

```elixir
alias ImagePipe.Output.{Policy, Resolved, ResolvedQualitySearch}
alias ImagePipe.Plan.Output.QualitySearch

defp policy_with(search, opts \\ []) do
  %Policy{
    mode: {:explicit, Keyword.get(opts, :format, :jpeg)},
    modern_candidates: [],
    headers: [],
    quality: :default,
    format_qualities: %{},
    strip_metadata: true,
    keep_copyright: true,
    color_profile: :strip,
    quality_search: search,
    max_bytes: Keyword.get(opts, :max_bytes)
  }
end

test "per-format clamp overrides the global bracket for the negotiated format" do
  search = %QualitySearch{objective: :ssim2, target: 90.0, min_quality: 70, max_quality: 80,
                          allowed_error: 1.0, format_min: %{avif: 60}, format_max: %{avif: 65}}
  {:ok, %Resolved{quality_search: %ResolvedQualitySearch{} = rs}} =
    Policy.resolve(policy_with(search, format: :avif), nil)
  assert rs.min_quality == 60 and rs.max_quality == 65
end

test "unlisted format falls back to the global bracket" do
  search = %QualitySearch{objective: :ssim2, target: 90.0, min_quality: 70, max_quality: 80,
                          allowed_error: 1.0, format_min: %{avif: 60}, format_max: %{avif: 65}}
  {:ok, %Resolved{quality_search: %ResolvedQualitySearch{} = rs}} =
    Policy.resolve(policy_with(search, format: :jpeg), nil)
  assert rs.min_quality == 70 and rs.max_quality == 80
end

test "none stays none" do
  {:ok, %Resolved{quality_search: :none}} = Policy.resolve(policy_with(:none), nil)
end

test "max_bytes is carried through to Resolved" do
  {:ok, %Resolved{max_bytes: 51_200}} = Policy.resolve(policy_with(:none, max_bytes: 51_200), nil)
end
```

> Add a `max_resolution` skip test once result dimensions are available to `resolved/2`. If `Resolved` does not yet know the result pixel count at this stage, evaluate `max_resolution` in `EncodeSearch` (Task 13) against the finalized image instead, and assert it there. Choose one home and note it; the spec allows either as long as it's a single clear place. **Recommendation:** evaluate `max_resolution` in `EncodeSearch` where the finalized image dimensions are in hand, and keep `Policy` purely about the bracket.

- [ ] **Step 2: Run, expect fail.**
- [ ] **Step 3: Implement**
  - Add `quality_search` (default `:none`) and `max_bytes` (default `nil`) to the `Policy` struct + `@type t`, and thread them in both `from_output_plan/3` clauses from `output.quality_search` / `output.max_bytes`.
  - In `resolved/2`, set `quality_search: resolve_search(policy, format)` and `max_bytes: policy.max_bytes`.
  - `resolve_search(%Policy{quality_search: :none}, _), do: :none`. For a `%QualitySearch{}`, compute:

    ```elixir
    min_q = Map.get(search.format_min, format, search.min_quality)
    max_q = Map.get(search.format_max, format, search.max_quality)
    %ResolvedQualitySearch{objective: search.objective, target: search.target,
      min_quality: min_q, max_quality: max_q, allowed_error: search.allowed_error}
    ```

  - Set `max_resolution: search.max_resolution` on the `%ResolvedQualitySearch{}` (the field added in Task 4) so `EncodeSearch.skip?/2` reads it from the resolved descriptor. The skip itself is evaluated in `EncodeSearch` (Task 13b), where the finalized image's pixel count is in hand; `Policy` only forwards the value.
- [ ] **Step 4: Run, expect pass.**
- [ ] **Step 5: Commit.**

---

## Phase 4 — Encoder loop

### Task 11: Buffer-encode path; finalize once

**Files:**
- Modify: `lib/image_pipe/output/encoder.ex`
- Test: `test/image_pipe/output/encoder_test.exs` (create if absent)

Goal: expose a way to encode the **finalized** image to an in-memory buffer at a given quality, and refactor so `finalize/2` runs once. No search yet.

- [ ] **Step 1: Failing test** — using a small fixture image and a `Resolved{format: :jpeg}`, assert a new `Encoder.encode_to_buffer(finalized_image, resolved, quality)` returns `{:ok, binary}` whose byte size shrinks as quality drops (`q=20` bytes < `q=90` bytes). Build the finalized image via the existing finalize path (expose a thin `finalize/2` wrapper or test through `stream_output` for the no-search path to keep finalize covered).
- [ ] **Step 2: Run, expect fail.**
- [ ] **Step 3: Implement**
  - Add `encode_to_buffer(image, %Resolved{} = resolved, quality)` that calls `Image.write_to_buffer(image, suffix, suffix: suffix, quality: quality)` (resolve `suffix` via the existing `output_format/1`). Return `{:ok, binary}` / `{:error, {:encode, ...}}`.
  - Refactor `stream_output/3`: compute `mime_type`/`suffix` and `finalized` once; if `resolved.quality_search == :none and resolved.max_bytes == nil`, keep the current `image_module.stream!/2` lazy path verbatim. (The search branch is wired in Task 13.)
- [ ] **Step 4: Run, expect pass.**
- [ ] **Step 5: Commit.**

### Task 12: `Ssim2Metric` adapter

**Files:**
- Create: `lib/image_pipe/output/ssim2_metric.ex`
- Test: `test/image_pipe/output/ssim2_metric_test.exs`

Isolate all `Ssimulacra2.*` calls here. Use the real API names recorded in Task 1 Step 4.

- [ ] **Step 1: Failing test**

```elixir
defmodule ImagePipe.Output.Ssim2MetricTest do
  use ExUnit.Case, async: true
  alias ImagePipe.Output.Ssim2Metric

  setup do
    {:ok, img} = Image.open("test/support/.../some_fixture.jpg")   # use an existing committed fixture
    {:ok, ref} = Image.thumbnail(img, "256")                       # small & fast
    %{ref: ref}
  end

  test "identical image scores ~100", %{ref: ref} do
    reference = Ssim2Metric.reference(ref)
    {:ok, score} = Ssim2Metric.score(reference, ref)
    assert score > 95.0
  end

  test "a heavily degraded re-encode scores lower than a light one", %{ref: ref} do
    reference = Ssim2Metric.reference(ref)
    {:ok, low} = Image.write_to_buffer(ref, ".jpg", suffix: ".jpg", quality: 15)
    {:ok, high} = Image.write_to_buffer(ref, ".jpg", suffix: ".jpg", quality: 92)
    {:ok, low_img} = Image.from_binary(low)
    {:ok, high_img} = Image.from_binary(high)
    {:ok, low_score} = Ssim2Metric.score(reference, low_img)
    {:ok, high_score} = Ssim2Metric.score(reference, high_img)
    assert high_score > low_score
  end
end
```

> Adjust fixture path + Vix/`image` helper spellings to what exists. This is a behavioral sanity test of the adapter, **not** a metric conformance test (we trust the package).

- [ ] **Step 2: Run, expect fail.**
- [ ] **Step 3: Implement**

```elixir
defmodule ImagePipe.Output.Ssim2Metric do
  @moduledoc """
  Thin adapter over the `ssimulacra2` package. The only module that references
  `Ssimulacra2.*`. `reference/1` precomputes the comparison reference once; the
  loop calls `score/2` per candidate. Scores are SSIMULACRA2-native (0–100,
  100 = identical).
  """

  # Wire these to the real package API recorded in Task 1.
  def reference(%Vix.Vips.Image{} = image), do: Ssimulacra2.Reference.from_vix(image)

  def score(reference, %Vix.Vips.Image{} = candidate) do
    Ssimulacra2.Vix.score(reference, candidate)
  end
end
```

If the package returns a bare float, wrap to `{:ok, float}` here so the loop has a uniform contract. If `Image.t()` wraps `Vix.Vips.Image.t()`, unwrap with `Image.to_vips_image/1` (or the equivalent) before handing to the package.

- [ ] **Step 4: Run, expect pass** (tag `@tag :ssim2` if the NIF is slow; keep it in the default lane though — it is the only correctness signal for the adapter).
- [ ] **Step 5: Commit.**

### Task 13: `EncodeSearch` — predicates, binary search, composition, best-effort

**Files:**
- Create: `lib/image_pipe/output/encode_search.ex`
- Test: `test/image_pipe/output/encode_search_test.exs`

Spec §6. Pure-ish loop: depends on a function that encodes the finalized image to a buffer at a quality, plus (for `:ssim2`) the metric. Inject those so the search is unit-testable without real images.

**Two public functions — keep them distinct (this resolved a review finding):**

```elixir
# Production wrapper: extracts quality_search/max_bytes from the resolved struct,
# builds the real encode/score closures, delegates to search/3.
@type meta :: %{quality: 1..100, bytes: non_neg_integer(), iterations: non_neg_integer(),
                outcome: :hit | :best_effort | :skipped, score: float() | nil}
@spec run(Vix.Vips.Image.t(), ImagePipe.Output.Resolved.t(), keyword()) ::
        {:ok, binary, meta()} | {:error, term()}
def run(finalized_image, %ImagePipe.Output.Resolved{} = resolved, opts)

# Pure core: consumed directly by unit tests.
@spec search(:none | ImagePipe.Output.ResolvedQualitySearch.t(), nil | pos_integer(), keyword()) ::
        {:ok, binary, meta()} | {:error, term()}
def search(quality_search_or_none, max_bytes, opts)
```

`opts` for `search/3` injects:
- `:encode_fun` — `(quality :: 1..100) -> {:ok, binary}` (memoized by the search per distinct quality).
- `:score_fun` — `(candidate_bytes :: binary) -> float` (ssim2 only; **takes the already-encoded buffer**, not the quality, so the search never re-encodes to score; production decodes the buffer + runs the metric, tests derive a score from the buffer's byte size).
- `:base_quality` — resolved base quality int (used as the upper bound for `max_bytes`-alone).
- `:max_iterations` — cap on **distinct** encodes (not predicate evaluations).

`run/3` builds these from the real encoder/metric and calls `search/3`. In production `Encoder` supplies them; the unit tests below supply synthetic curves.

**Monotonicity contract (state this in the moduledoc).** The binary search assumes byte size is non-decreasing in quality and SSIMULACRA2 score is non-decreasing in quality. Real encoders can violate this *locally* (adjacent qualities flat or off by a hair). The consequence is bounded — the returned quality may be a step or two from the theoretical optimum — and is acceptable for a best-effort search: the result is always re-measured and always within `[min, max]`, never wrong in kind. Do **not** "fix" a real-encoder flake by replacing the search; widen tolerances instead.

- [ ] **Step 1: Failing tests** (use a synthetic `encode_fun` returning a deterministic byte size per quality, e.g. `fn q -> {:ok, :binary.copy(<<0>>, q * 1000)} end`, and a synthetic `score_fun` mapping quality→score)

```elixir
alias ImagePipe.Output.EncodeSearch
alias ImagePipe.Output.ResolvedQualitySearch, as: RQS

# size: highest quality whose bytes <= target
test "size picks the highest quality under the byte target" do
  rs = %RQS{objective: :size, target: 50_000, min_quality: 10, max_quality: 80}
  enc = fn q -> {:ok, :binary.copy(<<0>>, q * 1000)} end   # bytes = q*1000
  assert {:ok, _bin, %{quality: 50, outcome: :hit}} =
           EncodeSearch.search(rs, nil, encode_fun: enc, max_iterations: 8)
end

test "size best-effort returns min_quality when even the floor exceeds the budget" do
  rs = %RQS{objective: :size, target: 5_000, min_quality: 10, max_quality: 80}
  enc = fn q -> {:ok, :binary.copy(<<0>>, q * 1000)} end
  assert {:ok, _bin, %{quality: 10, outcome: :best_effort}} =
           EncodeSearch.search(rs, nil, encode_fun: enc, max_iterations: 8)
end

# ssim2: lowest quality whose score >= target - allowed_error.
# score_fun takes the ENCODED BUFFER; here byte_size == q*100, so score == q+20.
test "ssim2 picks the lowest quality clearing the tolerance band" do
  rs = %RQS{objective: :ssim2, target: 90.0, min_quality: 10, max_quality: 80, allowed_error: 0.0}
  enc = fn q -> {:ok, :binary.copy(<<0>>, q * 100)} end
  score = fn bin -> byte_size(bin) / 100 + 20.0 end   # == q+20; >=90 at q>=70
  assert {:ok, _bin, %{quality: 70, outcome: :hit, score: s}} =
           EncodeSearch.search(rs, nil, encode_fun: enc, score_fun: score, max_iterations: 8)
  assert s >= 90.0
end

test "ssim2 reports :hit at the default iteration cap on a realistic bracket" do
  rs = %RQS{objective: :ssim2, target: 90.0, min_quality: 70, max_quality: 80, allowed_error: 0.0}
  enc = fn q -> {:ok, :binary.copy(<<0>>, q * 100)} end
  score = fn bin -> byte_size(bin) / 100 + 20.0 end   # >=90 at q>=70 -> picks 70
  assert {:ok, _bin, %{quality: 70, outcome: :hit}} =
           EncodeSearch.search(rs, nil, encode_fun: enc, score_fun: score, max_iterations: 6)
end

test "ssim2 allowed_error loosens the band downward" do
  rs = %RQS{objective: :ssim2, target: 90.0, min_quality: 10, max_quality: 80, allowed_error: 5.0}
  enc = fn q -> {:ok, :binary.copy(<<0>>, q * 100)} end
  score = fn bin -> byte_size(bin) / 100 + 20.0 end   # accept score >= 85 -> q>=65
  assert {:ok, _bin, %{quality: 65}} =
           EncodeSearch.search(rs, nil, encode_fun: enc, score_fun: score, max_iterations: 8)
end

test "ssim2 best-effort returns max_quality when target unreachable" do
  rs = %RQS{objective: :ssim2, target: 99.0, min_quality: 10, max_quality: 80, allowed_error: 0.0}
  enc = fn q -> {:ok, :binary.copy(<<0>>, q * 100)} end
  score = fn bin -> byte_size(bin) / 100 / 2.0 end    # == q/2; max 40 < 99
  assert {:ok, _bin, %{quality: 80, outcome: :best_effort}} =
           EncodeSearch.search(rs, nil, encode_fun: enc, score_fun: score, max_iterations: 8)
end

# composition: max_bytes caps the objective's pick
test "max_bytes lowers the ssim2 pick when it exceeds the budget" do
  rs = %RQS{objective: :ssim2, target: 80.0, min_quality: 10, max_quality: 90, allowed_error: 0.0}
  enc = fn q -> {:ok, :binary.copy(<<0>>, q * 1000)} end   # bytes = q*1000
  score = fn bin -> byte_size(bin) / 1000 end             # == q; >=80 at q>=80
  # objective picks q=80 (80_000 bytes); max_bytes 60_000 forces down to <=60
  assert {:ok, _bin, %{quality: 60}} =
           EncodeSearch.search(rs, 60_000, encode_fun: enc, score_fun: score, max_iterations: 16)
end

# max_bytes alone (no objective struct)
test "max_bytes alone searches [10, base] for the highest fit" do
  enc = fn q -> {:ok, :binary.copy(<<0>>, q * 1000)} end
  assert {:ok, _bin, %{quality: 40}} =
           EncodeSearch.search(:none, 40_000, encode_fun: enc, base_quality: 90, max_iterations: 8)
end
```

- [ ] **Step 2: Run, expect fail.**
- [ ] **Step 3: Implement** the loop:
  - **Memoization & iteration cap.** Keep a `%{quality => binary}` memo; `encode_fun` is called at most once per distinct quality, and `score_fun` (ssim2) is applied to the memoized buffer at most once per distinct quality. `iterations` counts **distinct encodes only** (memo hits are free). Cap distinct encodes at `max_iterations`; on hitting the cap mid-search, stop and return the **best satisfying candidate already probed** (see per-predicate tie-break) with `outcome: :hit` if one satisfied the predicate, else the boundary with `outcome: :best_effort`.
  - **Objective phase** (when a `%RQS{}` is given):
    - `:size` → binary search `[min,max]` for the **highest** `q` with `byte_size(memo(q)) <= target`. Best-effort = the highest fitting quality probed; if none fit, `min_quality`.
    - `:ssim2` → binary search `[min,max]` for the **lowest** `q` with `score(memo(q)) >= target - allowed_error`. Best-effort = the lowest clearing quality probed; if none clear, `max_quality`.
  - **Cap phase** (when `max_bytes` is set): upper bound = the objective's chosen quality (or `base_quality` when objective is `:none`). If `byte_size(memo(upper)) <= max_bytes`, keep it; else binary search downward in `[floor, upper]` for the **highest** `q` with bytes `<= max_bytes`. `floor = min_quality` when an objective ran, else `10` (spec §6.2/§6.3). Best-effort = `floor` (the lowest quality probed) when even the floor exceeds the budget.
  - **Per-predicate tie-break for a cap-exhausted return** (do not conflate the three): `:size` and `max_bytes` return the *highest fitting* quality probed; `:ssim2` returns the *lowest clearing* quality probed. Never return a quality lower than one already proven to fit (size/max_bytes) or higher than one already proven to clear (ssim2).
  - Track `outcome`: `:hit` when a predicate-satisfying quality was found; `:best_effort` when a boundary/unsatisfied result was returned; `:skipped` is set by the caller (Task 13b), not here.
  - Return the winning quality's already-encoded buffer (from the memo) so the winner is never re-encoded.
  - For `:ssim2`, populate `score` with the winner's measured score (re-read from the per-quality score memo); `nil` otherwise.
- [ ] **Step 4: Run, expect pass.**
- [ ] **Step 5: Commit.**

### Task 13b: `max_resolution` skip

**Files:**
- Modify: `lib/image_pipe/output/encode_search.ex`
- Test: same test file

- [ ] **Step 1: Failing test** — `EncodeSearch.skip?/2` returns true when `max_resolution > 0` and `width*height` (megapixels) exceeds it. (Pass dimensions explicitly to keep it pure: `skip?(%{max_resolution: 2}, _megapixels = 5)` → true; `skip?(%{max_resolution: 0}, 100)` → false.)
- [ ] **Step 2: Run, expect fail.**
- [ ] **Step 3: Implement** the predicate; the `Encoder` (Task 14) calls it with the finalized image's megapixels and, when true, bypasses the search (single-shot encode at base quality, `outcome: :skipped`).
- [ ] **Step 4: Run, expect pass.**
- [ ] **Step 5: Commit.**

### Task 14a: Add `Format.supports_quality?/1`

**Files:**
- Modify: `lib/image_pipe/format.ex`
- Test: `test/image_pipe/format_test.exs`

`Format.supports_quality?/1` does not exist yet (only `supports_color_profile?`/`supports_alpha?`/`supports_hdr?`). The search gates on it, mirroring imgproxy's `SupportsQuality()` capability (not the docs' narrower 4-format list).

- [ ] **Step 1: Failing test**

```elixir
test "supports_quality?/1 is true for lossy-quality formats, false for png" do
  assert ImagePipe.Format.supports_quality?(:jpeg)
  assert ImagePipe.Format.supports_quality?(:webp)
  assert ImagePipe.Format.supports_quality?(:avif)
  refute ImagePipe.Format.supports_quality?(:png)
end
```

- [ ] **Step 2: Run, expect fail.**
- [ ] **Step 3: Implement** — `def supports_quality?(format) when format in [:jpeg, :webp, :avif], do: true` / `def supports_quality?(_), do: false`. Place beside the sibling predicates; export if the boundary requires it (Format already exports its detector — follow the module's export pattern).
- [ ] **Step 4: Run, expect pass.**
- [ ] **Step 5: Commit.**

### Task 14: Wire `EncodeSearch` into `Encoder.stream_output`

**Files:**
- Modify: `lib/image_pipe/output/encoder.ex`
- Test: `test/image_pipe/output/encoder_test.exs`

- [ ] **Step 1: Failing test** — with a real fixture + `Resolved{format: :jpeg, max_bytes: N}`, assert `stream_output/3` returns `{:ok, stream, mime}` whose concatenated bytes are `<= N` (best-effort). With `quality_search: %RQS{objective: :ssim2, ...}`, assert the body decodes and the response is produced (score assertion lives in the wire test, Task 19).
- [ ] **Step 2: Run, expect fail.**
- [ ] **Step 3: Implement** — in `stream_output/3`, after finalizing once, when `(resolved.quality_search != :none or resolved.max_bytes != nil) and Format.supports_quality?(format)`:
  - Build `encode_fun = fn q -> encode_to_buffer(finalized, resolved, q) end`.
  - For `:ssim2`, build `reference = Ssim2Metric.reference(finalized)` and a buffer-based `score_fun = fn candidate_bytes -> {:ok, img} = Image.from_binary(candidate_bytes); {:ok, s} = Ssim2Metric.score(reference, img); s end` (returns a **bare float** to match `search/3`'s `:score_fun` contract; the search applies it to the memoized buffer so each quality is encoded and decoded at most once).
  - **Base quality:** derive it from `resolved.quality` exactly as the single-shot path already does — reuse the value `output_options/2` would pass (`{:quality, v} -> v`; `:default ->` the encoder's existing default, i.e. whatever `image`/libvips uses when no `:quality` is given). Factor that into a small `base_quality(resolved)` helper shared by both paths so there is **no** invented constant. This is only consulted for the `max_bytes`-alone upper bound.
  - Call `EncodeSearch.run(finalized, resolved, telemetry_opts: Telemetry.telemetry_opts(opts), max_iterations: <config or default 6>)`; wrap the winning buffer as a one-element stream `[binary]` so the producer's streaming contract is unchanged; return `{:ok, [binary], mime_type}`.
  - Honor `EncodeSearch.skip?/2` (single-shot at base quality, `outcome: :skipped`) before searching, using the finalized image's megapixels.
  - Formats without quality (`:png`) and the no-search case keep the existing lazy `stream!/2` path.
- [ ] **Step 4: Run, expect pass.**
- [ ] **Step 5: Commit.**

---

## Phase 5 — Telemetry

### Task 15a: Widen the `output` boundary to depend on `Telemetry`

**Files:**
- Modify: `lib/image_pipe/output.ex` (the `use Boundary, deps: [...]` list)
- Modify: `test/image_pipe/architecture_boundary_test.exs` (the "output boundary depends only on format and plan data" test, ~line 364-377)

The `output` boundary currently declares `deps: [ImagePipe.Format, ImagePipe.Plan]`, and `architecture_boundary_test.exs:367` asserts exactly that. Emitting telemetry from `EncodeSearch` (Task 15) adds an `output -> Telemetry` edge. This mirrors the **established precedent**: the `transform` boundary declares `deps: [ImagePipe.Plan, ImagePipe.Telemetry]` and emits `[:transform, :operation]`/`[:transform, :execute]` spans directly. Per AGENTS.md, a boundary-rule change ships with its architecture test in the same change.

- [ ] **Step 1: Update the boundary** — add `ImagePipe.Telemetry` to `lib/image_pipe/output.ex`'s `deps:` list.
- [ ] **Step 2: Update the architecture test** — change the assertion to `assert_boundary_deps(output, [ImagePipe.Format, ImagePipe.Plan, ImagePipe.Telemetry])`. Leave the `refute_boundary_deps` list (Source/Parser/Request/Response/Cache/Transform) unchanged — `Telemetry` is not in it.
- [ ] **Step 3: Compile** — `mise exec -- mix compile --warnings-as-errors` (Boundary runs at compile time; a missing dep edge fails here).
- [ ] **Step 4: Run** — `mise exec -- mix test test/image_pipe/architecture_boundary_test.exs` → pass.
- [ ] **Step 5: Commit.**

### Task 15: Search span + per-probe event

**Files:**
- Modify: `lib/image_pipe/output/encode_search.ex` (emit via `ImagePipe.Telemetry` helpers)
- Test: `test/image_pipe/output/encode_search_telemetry_test.exs`

Spec §7. Use the shared `ImagePipe.Telemetry` span/execute helpers (depends on Task 15a's boundary edge). **Use a unique `telemetry_prefix`** in tests (global-handler hygiene — see the test guidelines). The result-map keys (`quality`/`bytes`/`score`) differ deliberately from the telemetry stop-meta keys (`chosen_quality`/`chosen_bytes`/`final_score`) — map them explicitly, don't assume they match.

- [ ] **Step 1: Failing test** — attach to `[<prefix>, :encode, :search, :stop]` and `[<prefix>, :encode, :search, :probe]`; run a search with a synthetic curve; assert the stop metadata carries `objective`, `iterations`, `chosen_quality`, `chosen_bytes`, `outcome` (and `final_score` for ssim2), and that probe events fired once per distinct quality with `quality`/`bytes`/`index` (+ `score` for ssim2).
- [ ] **Step 2: Run, expect fail.**
- [ ] **Step 3: Implement** — wrap the loop body in `Telemetry.span(telemetry_opts, [:encode, :search], start_meta, fn -> {result, stop_meta} end)`; emit `Telemetry.execute(telemetry_opts, [:encode, :search, :probe], measurements, meta)` per distinct encode. Thread `telemetry_opts` from `opts`. Metadata is product-neutral numbers only — no URLs/secrets.
- [ ] **Step 4: Run, expect pass.**
- [ ] **Step 5: Commit.**

### Task 16: Default Logger + telemetry docs

**Files:**
- Modify: `lib/image_pipe/telemetry/logger.ex`
- Modify: `docs/telemetry.md`
- Test: `test/image_pipe/telemetry/logger_test.exs`

Spec §7 "Default Logger". 

- [ ] **Step 1: Failing test** — drive a request (or emit the events directly with a test prefix) and assert the Logger renders a line surfacing `outcome` + `chosen_quality`/`chosen_bytes`/`final_score`, and that `outcome: :best_effort` logs at `warn`.
- [ ] **Step 2: Run, expect fail.**
- [ ] **Step 3: Implement** — add the search span to `@group_span_events` and the probe to the appropriate one-shot list; add a specific `message/3` clause **before** the generic fallback that still surfaces `:result`/`outcome`; extend `level_for/3` so `outcome: :best_effort` escalates to `:warning`. Update `docs/telemetry.md` to list the new events and what the Logger renders.
- [ ] **Step 4: Run, expect pass.**
- [ ] **Step 5: Commit.**

---

## Phase 6 — Cache key

### Task 17: Include `quality_search` + `max_bytes` in the cache key

**Files:**
- Modify: `lib/image_pipe/cache/key.ex` (`output_plan_data/2`, both `:automatic` and `{:explicit, _}` clauses, ~lines 99-124)
- Test: `test/image_pipe/cache/key_test.exs`

Spec §8.

- [ ] **Step 1: Failing tests**

```elixir
test "different max_bytes targets do not collide" do
  k1 = key_for(output(max_bytes: 50_000))
  k2 = key_for(output(max_bytes: 60_000))
  refute k1 == k2
end

test "different ssim2 targets do not collide" do
  k1 = key_for(output(quality_search: search(target: 90.0)))
  k2 = key_for(output(quality_search: search(target: 85.0)))
  refute k1 == k2
end

test "semantically identical searches reuse the same key" do
  assert key_for(output(quality_search: search(target: 90.0))) ==
           key_for(output(quality_search: search(target: 90.0)))
end

test "max_resolution does not enter the key (it is a generation guard, not stored identity)" do
  assert key_for(output(quality_search: search(max_resolution: 0))) ==
           key_for(output(quality_search: search(max_resolution: 50)))
end

# ETag is derived from the same plan seed (plan_material drops only the cachebuster),
# so distinct byte-changing inputs must also yield distinct ETags.
test "different max_bytes targets yield different ETags" do
  refute etag_for(output(max_bytes: 50_000)) == etag_for(output(max_bytes: 60_000))
end
```

> `etag_for/1` resolves the request's ETag (via the same path `HttpCache.etag_material/2` → `Key.plan_material/2` uses). Locate the existing ETag test helper in the suite and reuse it.

- [ ] **Step 2: Run, expect fail.**
- [ ] **Step 3: Implement** — add `quality_search: quality_search_key(output.quality_search)` and `max_bytes: output.max_bytes` to both `output_plan_data/2` keyword bodies. Add a private `quality_search_key/1` that maps `:none -> :none` and a `%QualitySearch{}` to a stable keyword: `objective`, `target`, `min_quality`, `max_quality`, `allowed_error`, and the per-format maps as sorted lists. **Exclude `max_resolution`** — it is a runtime generation guard (like a safety limit), not stored identity, so it must not enter the key *or* the ETag (AGENTS.md: "Neither the key nor the ETag is a generation gate… keep safety limits out of both"). Keep canonical/ordered. Do **not** bump a key data version (greenfield). The fields flow into the ETag automatically via `plan_material/2`, which is correct — they change the stored bytes, so they are legitimate byte-identity validators (unlike the cachebuster/vary inputs the ETag deliberately excludes).
- [ ] **Step 4: Run, expect pass.**
- [ ] **Step 5: Commit.**

---

## Phase 7 — Fiddle UI

### Task 18: Autoquality + max_bytes controls and URL state

**Files:**
- Modify: `fiddle/assets/src/...` (the Svelte controls + URL-state store — locate the existing `quality`/`format_quality` control as the template)
- Test/verify: `pnpm -C fiddle/assets run check && pnpm -C fiddle/assets run lint`

> Per the no-self-preview memory: gate + commit; let the user verify the look in a real browser. Do not drive the fiddle UI via Preview/browser MCP.

- [ ] **Step 1: Build the controls** — add an `autoquality` method select (`none`/`size`/`ssim2`) with conditionally-shown fields: target, min quality, max quality, allowed_error (ssim2 only); add a `max_bytes` number input. Mirror the existing output-option control component and its URL-state wiring so the options serialize into the imgproxy URL (`autoquality:...`, `max_bytes:...`).
- [ ] **Step 2: Wire URL state** — ensure the controls read/write the shared URL store exactly like the `quality` control does (two-way).
- [ ] **Step 3: Build the assets** — `pnpm -C fiddle/assets install --frozen-lockfile` (if needed) then `pnpm -C fiddle/assets run build` (the Vite manifest is required for the fiddle's mix tests — see the memory note).
- [ ] **Step 4: Lint/check** — `pnpm -C fiddle/assets run check && pnpm -C fiddle/assets run lint && pnpm -C fiddle/assets run format`.
- [ ] **Step 5: Commit** — include built assets if the repo commits them (check `git status fiddle/`).

---

## Phase 8 — Conformance & wire tests

### Task 19: imgproxy wire-level acceptance tests

**Files:**
- Modify: `test/image_pipe/imgproxy_wire_conformance_test.exs` (follow its existing structure + `telemetry_prefix` conventions)

Spec §12. Real `ImagePipe.call/2` requests against a committed source image.

- [ ] **Step 1: Write the tests**
  - `max_bytes`: request `.../mb:N/...` on a JPEG-producing request; decode response, assert `byte_size(body) <= N` (allow a small tolerance only if the encoder overshoots minimally — prefer strict `<=`), status 200, correct content-type.
  - `autoquality:size`: similar byte assertion within the bracket.
  - `autoquality:ssim2`: request `.../autoquality:ssim2:90:70:95/...`; decode body, compute SSIMULACRA2 vs the decoded baseline (full-quality encode of the same pipeline) via `Ssim2Metric`; assert `score >= 90 - allowed_error`.
  - Best-effort: `mb:` smaller than any in-range encode → 200, body is the floor-quality result (no error status).
  - Safety: an invalid `autoquality:ml:...` / `autoquality:dssim:0.02` request returns the parser error **before** source fetch (assert no source access — reuse the suite's source-spy pattern).
  - Use a unique `telemetry_prefix` for any telemetry assertions.
- [ ] **Step 2: Run, expect fail** (features land in prior phases, so these may already pass — if so, tighten until they meaningfully exercise the path, then keep).
- [ ] **Step 3..5:** make pass, commit.

### Task 20: Property tests

**Files:**
- Create: `test/image_pipe/output/encode_search_property_test.exs`

- [ ] **Step 1: Write** StreamData properties. Generate random brackets and random size/score curves — **including non-monotone curves** (don't only test the happy monotone case, or the search's robustness claim is untested). Assert the invariants that hold regardless of monotonicity:
  - `search/3` always returns a quality within `[min, max]`.
  - When `outcome == :hit` for `:size`/`max_bytes`, the returned quality's bytes are `<= target`.
  - When `outcome == :hit` for `:ssim2`, the returned quality's score is `>= target - allowed_error`.
  - The effective bracket from `Policy.resolve/2` always has `min <= max`.
  Do **not** assert optimality (the search may be a step off the true boundary under non-monotone curves — that's the documented, acceptable behavior, not a bug).
- [ ] **Step 2..5:** run, implement any fixes, commit.

### Task 21: Support matrix doc

**Files:**
- Modify: `docs/imgproxy_support_matrix.md`

Spec §11.

- [ ] **Step 1: Update**
  - **Surface axis:** option rows for `autoquality`/`aq` and `max_bytes`/`mb`; the `autoquality_*` config options (§4.3). Note `max_bytes:0` disables (parity), and that the search gates on the libvips quality **capability** (jpeg/webp/avif), not the docs' narrower 4-format list.
  - **Stage axis:** pipeline-stage note for the output re-encode search loop (no option-table knob for the loop mechanics).
  - **Behavioral axis:** the SSIMULACRA2-vs-DSSIM divergence (metric/scale/direction) + bare-`dssim`-only rule + migration table (`dssim:0.02 ≈ ssim2:85`); `ml` unsupported (deliberate divergence); and two one-line behavioral **notes** (not divergences in the testable sense): (a) `max_bytes` uses a binary search selecting the highest quality under budget vs imgproxy's heuristic descent; (b) under `autoquality + max_bytes` composition our floor is the autoquality `min_quality`, whereas imgproxy's `max_bytes` always floors at 10.
  - **Minor grammar divergence:** `autoquality:size` accepts no 5th positional arg, whereas imgproxy's uniform grammar tolerates (and ignores) a trailing `allowed_error` on `size`.
- [ ] **Step 2: Commit.**

---

## Phase 9 — Gate

### Task 22: Full verification

- [ ] **Step 1:** `mise exec -- mix format`
- [ ] **Step 2:** `mise run precommit` (format check, `compile --warnings-as-errors`, `credo --strict`, `mix test`) — green.
- [ ] **Step 3:** `mise run precommit:fiddle` — green (fiddle JS + Elixir gate; build assets first if needed).
- [ ] **Step 4:** Verify issue auto-close wiring is ready for the PR body (plain `Fixes #344` / `Fixes #83`, each its own line) — note for the PR, not committed here.
- [ ] **Step 5:** Final commit / branch rename to a descriptive name (e.g. `feat/imgproxy-autoquality-max-bytes`) before first push (per AGENTS.md).

---

## Notes for the implementer

- **ssimulacra2 API:** the exact `Ssimulacra2.Reference` / `Ssimulacra2.Vix` function spellings must be confirmed in Task 1 Step 4 and wired only in `Ssim2Metric` (Task 12). If the package can't decode-and-score from a buffer directly, decode with `Image.from_binary/1` → unwrap to `Vix.Vips.Image` first.
- **Colorspace:** the finalized reference and decoded candidates should both be 8-bit sRGB-family (the encoder finalize produces sRGB); if the package requires explicit sRGB, do the conversion inside `Ssim2Metric`.
- **Memoize encodes:** never encode the same quality twice across the objective and cap phases, and never re-encode the winner — the search returns the winning buffer it already produced.
- **Boundary check:** nothing in `request`/`source`/`response` names a concrete transform module; the loop lives entirely in `Output.*`. If a new Boundary export is needed for `EncodeSearch`/`ResolvedQualitySearch`, add a narrow one; don't export helpers. Re-run `mise exec -- mix compile` to catch Boundary violations.
- **Comment-only/doc edits** skip the compile/test gate (per the memory note), but every code task here runs its focused tests.
