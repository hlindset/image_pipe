# Butteraugli Metric Provider Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add butteraugli as a second, pluggable autoquality metric alongside ssimulacra2 — measured externally on WebP/AVIF/JPEG, and driven natively via libvips' JXL `distance` knob on JPEG XL.

**Architecture:** Per-provider `Plan.Output.QualitySearch.{Size,Ssimulacra2,Butteraugli}` structs (struct identity carries objective+metric). One `Output.Metric` runtime behaviour per metric (`direction`/`target_range`/`reference`/`score`). `Output.Policy.resolve_search/2` maps `(metric, format)` to a resolved execution-strategy struct; `Output.EncodeSearch` dispatches on it — an external-measure band search (polarity read from `direction`) or a self-contained `NativeJxlButteraugli` strategy that clamps into the Q-bracket via libjxl's Q→distance formula and self-caps for `max_bytes` on the distance axis.

**Tech Stack:** Elixir, Vix/libvips (JXL `jxlsave` exposes `distance`, min 0/max 25), the `ssimulacra2` NIF (existing) and the unpublished `butteraugli` NIF (`github: "hlindset/butteraugli"`), Boundary, ExUnit + StreamData.

**Source spec:** `docs/superpowers/specs/2026-06-24-butteraugli-metric-provider-design.md`. Read it before starting.

**Run tests with:** `mise exec -- mix test <path>`. Gate before finishing a phase: `mise run precommit`.

---

## Conventions & gotchas (read once)

- `RQS` is the existing alias for `ImagePipe.Output.ResolvedQualitySearch` inside `encode_search.ex`. After Task 4 the resolved type is a **union of structs**, so code that wrote `%RQS{objective: :ssim2}` becomes a match on a specific struct (`%RQS.Ssimulacra2{}`).
- Elixir lists have no index access — use `Enum.at`. Predicate fns end in `?` and don't start with `is_`.
- This is greenfield: **do not** bump cache key data-versions; reshape the canonical key data in place (`docs/superpowers/specs/...` + cache guidelines in `AGENTS.md`).
- The Plan-exports arch test (`test/image_pipe/architecture_boundary_test.exs`) uses exact-match `==` — every new exported `Plan.*` module must be added there or the suite goes red.
- Commit after every task. Branch is `feat/butteraugli-metric-provider`.

---

## File Structure

**Phase 1 — provider foundation + external-measure butteraugli**

| File | Responsibility | Action |
|---|---|---|
| `mix.exs` | add `:butteraugli` dep (commit SHA) | Modify |
| `lib/image_pipe/plan/output/quality_search/size.ex` | `:size` byte-budget search shape | Create |
| `lib/image_pipe/plan/output/quality_search/ssimulacra2.ex` | ssim2 quality-target shape | Create |
| `lib/image_pipe/plan/output/quality_search/butteraugli.ex` | butteraugli distance-target shape | Create |
| `lib/image_pipe/plan/output/quality_search.ex` | **delete** the single struct (replaced by the family) | Delete |
| `lib/image_pipe/plan/output.ex` | `quality_search` union typespec | Modify |
| `lib/image_pipe/plan.ex` | export the 3 sub-structs | Modify |
| `test/image_pipe/architecture_boundary_test.exs` | exports mirror | Modify |
| `lib/image_pipe/cache/key.ex` | per-struct `quality_search_key/1` | Modify |
| `lib/image_pipe/output/resolved_quality_search/{size,ssimulacra2,butteraugli}.ex` | resolved per-strategy structs | Create |
| `lib/image_pipe/output/resolved_quality_search.ex` | **delete** single resolved struct | Delete |
| `lib/image_pipe/output/metric.ex` | metric behaviour + `runtime/1` dispatch | Create |
| `lib/image_pipe/output/metric/ssimulacra2.ex` | ssim2 runtime (was `Ssim2Metric`) | Create (rename) |
| `lib/image_pipe/output/metric/butteraugli.ex` | butteraugli runtime (external NIF) | Create |
| `lib/image_pipe/output/ssim2_metric.ex` | **delete** (moved to `metric/ssimulacra2.ex`) | Delete |
| `lib/image_pipe/output/ssim2_metric/crop_score.ex` | move alias to `Metric.Ssimulacra2` | Modify |
| `lib/image_pipe/output/policy.ex` | per-struct `resolve_search/2` + range validation | Modify |
| `lib/image_pipe/output/encode_search.ex` | dispatch on resolved struct; direction-driven polarity | Modify |
| `lib/image_pipe/output/encoder.ex` | `crop?/2` matches Ssimulacra2 resolved struct | Modify |
| `lib/image_pipe/parser/imgproxy/option_grammar.ex` | `aq:butteraugli` clause + `:target_distance` field | Modify |
| `lib/image_pipe/parser/imgproxy/options.ex` | butteraugli defaults + per-objective build | Modify |
| `fiddle/assets/...` | butteraugli option in autoquality control | Modify |
| `docs/imgproxy_support_matrix.md` | conformance sync (surface) | Modify |

**Phase 2 — native JXL strategy**

| File | Responsibility | Action |
|---|---|---|
| `lib/image_pipe/output/jxl_distance.ex` | libjxl Q→distance formula | Create |
| `lib/image_pipe/output/encoder.ex` | `.jxl[distance=…]` suffix | Modify |
| `lib/image_pipe/output/resolved_quality_search/native_jxl_butteraugli.ex` | native strategy resolved struct | Create |
| `lib/image_pipe/output/policy.ex` | select native strategy for `(butteraugli, :jpeg_xl)` | Modify |
| `lib/image_pipe/output/encode_search.ex` | `NativeJxlButteraugli` execution + `:native` outcome | Modify |
| `docs/imgproxy_support_matrix.md` | conformance sync (stage/order, behavioral) | Modify |
| `docs/telemetry.md` + Logger/OTel | `:native` outcome / `:metric` metadata sync | Modify |

---

## Struct-split consumer migration checklist (from plan review)

The struct split (`QualitySearch` → family, `ResolvedQualitySearch` → family, `Ssim2Metric` → `Metric.Ssimulacra2`) breaks consumers across `lib/` and `test/`. **Every file below must be migrated in the task that breaks it.** Migration = replace `%QualitySearch{objective: :ssim2/:size}` / `%RQS{objective: ...}` literals & matches with the concrete struct (`%QualitySearch.Ssimulacra2{}` etc., dropping the `objective:` key), replace `.objective` reads with per-struct dispatch, and repoint `Ssim2Metric` → `Output.Metric.Ssimulacra2`.

**Production (`encode_search.ex`, breaks at Task 7 — add to Task 7):** `search_start_meta/2`, `search_stop_meta/2`, `objective_of/1` (match `%RQS{}` / read `.objective`); `cap_floor/1` (`cap_floor(%RQS{min_quality: ...})`); `base_quality/2` (`%Resolved{quality_search: %RQS{max_quality: ...}}`). Give each per-struct clauses; `objective_of/1` returns `:size | :ssimulacra2 | :butteraugli`.

**Host-config schema (breaks at Task 8 — add to Task 8):** `lib/image_pipe/parser/imgproxy.ex` — `autoquality_method: [type: {:in, [:none, :size, :ssim2]}, ...]` (~line 54) → `{:in, [:none, :size, :ssimulacra2, :butteraugli]}`; update the comment + default plumbing (~line 314). Stale `# See QualitySearch` (~line 65) → `QualitySearch.*`.

**Tests (migrate in the task whose change breaks them):**
- `test/image_pipe/plan/output/quality_search_test.exs` — tests the **deleted** module; delete/rewrite into per-struct tests (Task 2).
- `test/image_pipe/cache/key_test.exs` — `qs_search/1` helper (~1371) `struct!(%QualitySearch{objective: :ssim2,...})` → `%QualitySearch.Ssimulacra2{}` (Task 3).
- `test/image_pipe/output/encode_search_test.exs` — ~15 `%RQS{objective:}` literals → concrete structs (Task 7).
- `test/image_pipe/output/encode_search_property_test.exs` — `%RQS{objective:}` + `%Output.QualitySearch{objective: objective}` generators (Task 7).
- `test/image_pipe/output/encode_search_telemetry_test.exs` — `%RQS{objective: :ssim2}` + `stop_meta.objective == :ssim2` → `:ssimulacra2` (Task 7).
- `test/image_pipe/output_policy_test.exs` — six `%QualitySearch{objective: :ssim2}` blocks + `%ResolvedQualitySearch{}` matches + `rs.objective` read (Task 6).
- `test/image_pipe/output_encoder_test.exs` (~185), `test/image_pipe/output/resolved_test.exs` (~21), `test/image_pipe/output/encoder_crop_scoring_test.exs` (~49) — `%RQS{objective: :ssim2}` (Task 7).
- `test/parser/imgproxy/options_test.exs` (~242-322) — `%QualitySearch{objective: :ssim2}` asserts + `{:autoquality, [objective: :ssim2/:size]}` fixtures → `metric:`/concrete struct; `out.quality_search.objective` reads → struct match (Task 8).
- `test/image_pipe/telemetry/trace/capture_test.exs` (~72,211) & `logger_test.exs` (~76,101,150) — hand-built `%{objective: :ssim2/:size}` metadata maps; the metadata *value* changes `:ssim2` → `:ssimulacra2` (Task 7); **do not rename the key** `:objective`.
- `test/support/mix/tasks/autoquality.bench.ex` — `%RQS{objective:}` literals (~2353, 4326, 4341) **and** heavy `Ssim2Metric.reference/score` usage (alias → `Output.Metric.Ssimulacra2`). Compiled under `MIX_ENV=test` → breaks `mix test`. Structs in Task 7, alias in Task 5.

**Arch-test string traps:** `test/image_pipe/architecture_boundary_test.exs:~352` `refute crop_score.ex =~ "Ssimulacra2"` — Task 5's new alias introduces that literal. Change to `refute ... =~ "Ssimulacra2.Vix"` (and `"Ssimulacra2.Reference"`) — the raw NIF package CropScore must not touch directly. Intent preserved.

**Span/meta naming:** keep `objective_of/1`'s atoms and the telemetry `:objective` metadata **value** as the new metric names (`:ssimulacra2`/`:butteraugli`/`:size`); do **not** rename the metadata *key* `:objective` — that keeps Logger/OTel `@span_stages` + their tests stable (only the value changes).

---

# PHASE 1 — Provider foundation + external-measure butteraugli

End state: `aq:butteraugli:1.0:...` works on WebP/AVIF/JPEG; butteraugli on JXL falls through the external Q-search (correct, just not yet native). All gates green.

## Task 1: Add the butteraugli NIF dependency

**Files:**
- Modify: `mix.exs` (deps list)

- [ ] **Step 1: Add the dep**

In `mix.exs`, in `defp deps do`, next to the `:ssimulacra2` entry, add (SHA pinned to `hlindset/butteraugli` HEAD as of 2026-06-24; bump if a newer commit is needed):

```elixir
{:butteraugli, github: "hlindset/butteraugli", ref: "2e2e054545802f5fd6e0d39d386c0db974fdfd5b"},
```

- [ ] **Step 2: Fetch and compile**

Run: `mise exec -- mix deps.get && mise exec -- mix deps.compile butteraugli`
Expected: butteraugli (and its precompiled NIF) fetch and compile cleanly. If it needs the Rust toolchain, set `BUTTERAUGLI_BUILD=1` only if a precompiled artifact isn't available.

- [ ] **Step 3: Smoke-test the API in IEx**

Run: `mise exec -- iex -S mix`, then verify `Butteraugli.Vix` is loaded:
```elixir
Code.ensure_loaded?(Butteraugli.Vix)   # => true
```
Expected: `true`. (Confirms the `:vix`-optional `Butteraugli.Vix` module compiled.)

- [ ] **Step 4: Commit**

```bash
git add mix.exs mix.lock
git commit -m "build: add butteraugli NIF dependency (pinned commit)"
```

## Task 2: Split `Plan.Output.QualitySearch` into a per-provider struct family

**Files:**
- Create: `lib/image_pipe/plan/output/quality_search/size.ex`
- Create: `lib/image_pipe/plan/output/quality_search/ssimulacra2.ex`
- Create: `lib/image_pipe/plan/output/quality_search/butteraugli.ex`
- Delete: `lib/image_pipe/plan/output/quality_search.ex`
- Modify: `lib/image_pipe/plan/output.ex` (typespec)
- Modify: `lib/image_pipe/plan.ex` (exports)
- Modify: `test/image_pipe/architecture_boundary_test.exs` (exports mirror)

- [ ] **Step 1: Create the three structs**

`lib/image_pipe/plan/output/quality_search/size.ex`:
```elixir
defmodule ImagePipe.Plan.Output.QualitySearch.Size do
  @moduledoc """
  Byte-budget autoquality search (imgproxy `autoquality:size`). `target` is a byte
  count; the search finds the highest quality in `[min_quality, max_quality]` whose
  encode is `<= target`. `format_min`/`format_max` clamp the bracket per output
  format (resolved away in `ImagePipe.Output.Policy`); `max_resolution` (megapixels,
  0 = off) skips the search on oversized results. No perceptual metric, no band.
  """
  @enforce_keys [:target, :min_quality, :max_quality]
  defstruct @enforce_keys ++ [format_min: %{}, format_max: %{}, max_resolution: 0]

  @type format :: ImagePipe.Format.output_format()
  @type t :: %__MODULE__{
          target: pos_integer(),
          min_quality: 1..100,
          max_quality: 1..100,
          format_min: %{optional(format()) => 1..100},
          format_max: %{optional(format()) => 1..100},
          max_resolution: non_neg_integer()
        }
end
```

`lib/image_pipe/plan/output/quality_search/ssimulacra2.ex`:
```elixir
defmodule ImagePipe.Plan.Output.QualitySearch.Ssimulacra2 do
  @moduledoc """
  SSIMULACRA2 quality-target autoquality search. `target` is a SSIMULACRA2 score
  (0–100, higher = better); the search walks the encoder quality knob within
  `[min_quality, max_quality]` to land within `[target − allowed_error, target +
  allowed_error]` (a symmetric band on the 0–100 scale). `format_min`/`format_max`
  clamp the bracket per output format; `max_resolution` skips the search on
  oversized results. See `docs/imgproxy_support_matrix.md` (Autoquality).
  """
  @enforce_keys [:target, :min_quality, :max_quality]
  defstruct @enforce_keys ++
              [allowed_error: 0, format_min: %{}, format_max: %{}, max_resolution: 0]

  @type format :: ImagePipe.Format.output_format()
  @type t :: %__MODULE__{
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

`lib/image_pipe/plan/output/quality_search/butteraugli.ex`:
```elixir
defmodule ImagePipe.Plan.Output.QualitySearch.Butteraugli do
  @moduledoc """
  Butteraugli distance-target autoquality search. `target` is a butteraugli
  distance (lower = better; ~1.0 is visually lossless; valid range 0.0–25.0,
  validated at resolve). On WebP/AVIF/JPEG the search walks the encoder quality
  knob within `[min_quality, max_quality]` to land within `[target − allowed_error,
  target + allowed_error]`. On JPEG XL it drives libvips' native `distance` knob
  directly (resolve picks `Output.ResolvedQualitySearch.NativeJxlButteraugli`),
  where the bracket clamps the target via the libjxl Q→distance mapping.
  `max_resolution` skips the search on oversized results.
  """
  @enforce_keys [:target, :min_quality, :max_quality]
  defstruct @enforce_keys ++
              [allowed_error: 0, format_min: %{}, format_max: %{}, max_resolution: 0]

  @type format :: ImagePipe.Format.output_format()
  @type t :: %__MODULE__{
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

- [ ] **Step 2: Delete the old single struct**

```bash
git rm lib/image_pipe/plan/output/quality_search.ex
```

- [ ] **Step 3: Update the `Plan.Output` typespec**

In `lib/image_pipe/plan/output.ex`, change the `quality_search` field type:
```elixir
quality_search:
  :none
  | ImagePipe.Plan.Output.QualitySearch.Size.t()
  | ImagePipe.Plan.Output.QualitySearch.Ssimulacra2.t()
  | ImagePipe.Plan.Output.QualitySearch.Butteraugli.t(),
```
(The `@moduledoc` line "`quality_search` and `max_bytes` are resolved defaults (`:none`/`nil` = off)." stays accurate.)

- [ ] **Step 4: Update Plan boundary exports**

In `lib/image_pipe/plan.ex`, replace `Output.QualitySearch,` in the `exports:` list with:
```elixir
      Output.QualitySearch.Size,
      Output.QualitySearch.Ssimulacra2,
      Output.QualitySearch.Butteraugli,
```

- [ ] **Step 5: Update the exports arch-test mirror**

In `test/image_pipe/architecture_boundary_test.exs`, in the `assert_boundary_exports(plan, [...])` list, replace `ImagePipe.Plan.Output.QualitySearch,` with:
```elixir
      ImagePipe.Plan.Output.QualitySearch.Size,
      ImagePipe.Plan.Output.QualitySearch.Ssimulacra2,
      ImagePipe.Plan.Output.QualitySearch.Butteraugli,
```

- [ ] **Step 6: Compile — expect downstream breakage**

Run: `mise exec -- mix compile --warnings-as-errors 2>&1 | head -40`
Expected: FAILS — references to `%QualitySearch{}` / `Output.QualitySearch` in `cache/key.ex`, `policy.ex`, `encode_search.ex`, `parser/imgproxy/options.ex` no longer resolve. That's expected; the next tasks fix each. (You can proceed task-by-task; don't try to make everything compile in this task.)

- [ ] **Step 7: Commit (WIP — compile is intentionally red)**

```bash
git add lib/image_pipe/plan/ lib/image_pipe/plan.ex test/image_pipe/architecture_boundary_test.exs
git commit -m "refactor(plan): split QualitySearch into per-provider struct family"
```

## Task 3: Per-struct cache key

**Files:**
- Modify: `lib/image_pipe/cache/key.ex` (around lines 168-181)
- Test: `test/image_pipe/cache/key_test.exs` (find the existing autoquality key test)

- [ ] **Step 1: Write the failing test**

In the cache key test file, add (adjust the module/helper names to the file's existing style — find how it builds an `%Output{}` and calls the key builder):
```elixir
test "ssim2 and butteraugli searches at the same numeric target produce distinct keys" do
  ssim2 = %ImagePipe.Plan.Output.QualitySearch.Ssimulacra2{
    target: 1.0, min_quality: 70, max_quality: 80, allowed_error: 0.1
  }
  butter = %ImagePipe.Plan.Output.QualitySearch.Butteraugli{
    target: 1.0, min_quality: 70, max_quality: 80, allowed_error: 0.1
  }
  refute key_for_quality_search(ssim2) == key_for_quality_search(butter)
end
```
Add a tiny helper in the test that builds a minimal `%Output{}` with the given `quality_search` and extracts its cache key (mirror an existing test's construction).

- [ ] **Step 2: Run it — expect failure**

Run: `mise exec -- mix test test/image_pipe/cache/key_test.exs`
Expected: FAIL (the old `quality_search_key/1` only matches `%QualitySearch{}`, which no longer exists → `FunctionClauseError` / compile error).

- [ ] **Step 3: Replace `quality_search_key/1` with per-struct clauses**

In `lib/image_pipe/cache/key.ex`, replace the single `quality_search_key(%QualitySearch{} = search)` clause (and its `alias`) with:
```elixir
  defp quality_search_key(:none), do: :none

  defp quality_search_key(%QualitySearch.Size{} = s) do
    [
      metric: :size,
      target: s.target,
      min_quality: s.min_quality,
      max_quality: s.max_quality,
      format_min: Enum.sort(Map.to_list(s.format_min)),
      format_max: Enum.sort(Map.to_list(s.format_max))
    ]
  end

  defp quality_search_key(%QualitySearch.Ssimulacra2{} = s), do: quality_metric_key(:ssimulacra2, s)
  defp quality_search_key(%QualitySearch.Butteraugli{} = s), do: quality_metric_key(:butteraugli, s)

  defp quality_metric_key(metric, s) do
    [
      metric: metric,
      target: s.target,
      min_quality: s.min_quality,
      max_quality: s.max_quality,
      allowed_error: s.allowed_error,
      format_min: Enum.sort(Map.to_list(s.format_min)),
      format_max: Enum.sort(Map.to_list(s.format_max))
    ]
  end
```
Update the `alias` at the top of `key.ex`: replace `alias ImagePipe.Plan.Output.QualitySearch` with `alias ImagePipe.Plan.Output.QualitySearch` (still the parent namespace — the per-struct names `QualitySearch.Size` etc. resolve under it). The `metric: metric` tag is what makes ssim2 vs butteraugli keys distinct at the same target.

- [ ] **Step 4: Run the test — expect pass**

Run: `mise exec -- mix test test/image_pipe/cache/key_test.exs`
Expected: PASS. (Existing ssim2/size key tests should also still pass — they now carry `metric: :ssimulacra2`/`:size` instead of `objective:`; update any existing key-equality assertion that hard-codes the old `objective:` shape.)

- [ ] **Step 5: Commit**

```bash
git add lib/image_pipe/cache/key.ex test/image_pipe/cache/key_test.exs
git commit -m "refactor(cache): per-provider quality_search cache key, distinct metric tag"
```

## Task 4: Split `ResolvedQualitySearch` into per-strategy structs

**Files:**
- Create: `lib/image_pipe/output/resolved_quality_search/size.ex`
- Create: `lib/image_pipe/output/resolved_quality_search/ssimulacra2.ex`
- Create: `lib/image_pipe/output/resolved_quality_search/butteraugli.ex`
- Delete: `lib/image_pipe/output/resolved_quality_search.ex`

- [ ] **Step 1: Create the resolved structs**

`lib/image_pipe/output/resolved_quality_search/size.ex`:
```elixir
defmodule ImagePipe.Output.ResolvedQualitySearch.Size do
  @moduledoc "Resolved `:size` byte-budget search (bracket per-format clamped)."
  @enforce_keys [:target, :min_quality, :max_quality]
  defstruct @enforce_keys ++ [max_resolution: 0]

  @type t :: %__MODULE__{
          target: pos_integer(),
          min_quality: 1..100,
          max_quality: 1..100,
          max_resolution: non_neg_integer()
        }
end
```

`lib/image_pipe/output/resolved_quality_search/ssimulacra2.ex`:
```elixir
defmodule ImagePipe.Output.ResolvedQualitySearch.Ssimulacra2 do
  @moduledoc """
  Resolved SSIMULACRA2 quality-target search (higher = better). Carries the
  per-content-class confirm-skipped crop offset (#380), populated for both
  `:photo` and `:graphic` so the `:crop` path's `Map.fetch!` is total.
  """
  @type content_class :: :photo | :graphic
  @enforce_keys [:target, :min_quality, :max_quality]
  defstruct @enforce_keys ++ [allowed_error: 0, max_resolution: 0, quality_search_offsets: %{}]

  @type t :: %__MODULE__{
          target: number(),
          min_quality: 1..100,
          max_quality: 1..100,
          allowed_error: number(),
          max_resolution: non_neg_integer(),
          quality_search_offsets: %{optional(content_class()) => number()}
        }
end
```

`lib/image_pipe/output/resolved_quality_search/butteraugli.ex`:
```elixir
defmodule ImagePipe.Output.ResolvedQualitySearch.Butteraugli do
  @moduledoc """
  Resolved butteraugli distance-target search for the **external-measure** path
  (non-JXL formats), lower = better. Full-frame only this cycle (no crop offsets).
  """
  @enforce_keys [:target, :min_quality, :max_quality]
  defstruct @enforce_keys ++ [allowed_error: 0, max_resolution: 0]

  @type t :: %__MODULE__{
          target: number(),
          min_quality: 1..100,
          max_quality: 1..100,
          allowed_error: number(),
          max_resolution: non_neg_integer()
        }
end
```

- [ ] **Step 2: Delete the old resolved struct**

```bash
git rm lib/image_pipe/output/resolved_quality_search.ex
```

- [ ] **Step 3: Compile — expect breakage in policy.ex & encode_search.ex**

Run: `mise exec -- mix compile --warnings-as-errors 2>&1 | head -30`
Expected: FAIL at `policy.ex` / `encode_search.ex` (they reference `%ResolvedQualitySearch{}` / `%RQS{}`). Fixed in Tasks 6 and 7.

- [ ] **Step 4: Commit (WIP)**

```bash
git add lib/image_pipe/output/resolved_quality_search/
git commit -m "refactor(output): split ResolvedQualitySearch into per-strategy structs"
```

## Task 5: `Output.Metric` behaviour + runtimes

**Files:**
- Create: `lib/image_pipe/output/metric.ex`
- Create: `lib/image_pipe/output/metric/ssimulacra2.ex`
- Create: `lib/image_pipe/output/metric/butteraugli.ex`
- Delete: `lib/image_pipe/output/ssim2_metric.ex`
- Modify: `lib/image_pipe/output/ssim2_metric/crop_score.ex` (alias)
- Test: `test/image_pipe/output/metric/butteraugli_test.exs`

- [ ] **Step 1: Write the failing butteraugli runtime test**

`test/image_pipe/output/metric/butteraugli_test.exs`:
```elixir
defmodule ImagePipe.Output.Metric.ButteraugliTest do
  use ExUnit.Case, async: true
  alias ImagePipe.Output.Metric.Butteraugli

  test "direction and range" do
    assert Butteraugli.direction() == :lower_better
    assert Butteraugli.target_range() == {0.0, 25.0}
  end

  test "identical images score near zero distance" do
    {:ok, img} = Image.new(64, 64, color: [120, 130, 140])
    {:ok, ref} = Butteraugli.reference(img)
    assert {:ok, score} = Butteraugli.score(ref, img)
    assert score < 0.5
  end
end
```

- [ ] **Step 2: Run it — expect failure**

Run: `mise exec -- mix test test/image_pipe/output/metric/butteraugli_test.exs`
Expected: FAIL (module doesn't exist).

- [ ] **Step 3: Create the behaviour + dispatch**

`lib/image_pipe/output/metric.ex`:
```elixir
defmodule ImagePipe.Output.Metric do
  @moduledoc """
  Perceptual-quality metric runtime behaviour for the autoquality external-measure
  search. One module per metric owns its measurement semantics; the search loop
  reads `direction/0` to orient its band walk and calls `reference/1` + `score/2`.
  `runtime/1` maps a resolved external-measure search struct to its runtime module.
  Native-encoder realization (e.g. JXL `distance`) is a resolve-time *strategy*
  choice, not a callback here.
  """
  alias ImagePipe.Output.ResolvedQualitySearch, as: RQS

  @callback direction() :: :higher_better | :lower_better
  @callback target_range() :: {number(), number()}
  @callback reference(Vix.Vips.Image.t()) :: {:ok, term()} | {:error, term()}
  @callback score(reference :: term(), Vix.Vips.Image.t()) :: {:ok, float()} | {:error, term()}

  @spec runtime(RQS.Ssimulacra2.t() | RQS.Butteraugli.t()) :: module()
  def runtime(%RQS.Ssimulacra2{}), do: __MODULE__.Ssimulacra2
  def runtime(%RQS.Butteraugli{}), do: __MODULE__.Butteraugli
end
```

`lib/image_pipe/output/metric/ssimulacra2.ex` (the renamed `Ssim2Metric`):
```elixir
defmodule ImagePipe.Output.Metric.Ssimulacra2 do
  @moduledoc """
  Thin adapter over the `ssimulacra2` package — the only module that references
  `Ssimulacra2.*`. `reference/1` precomputes the comparison reference once (from
  the finalized pre-encode image); the loop calls `score/2` per decoded candidate.
  Scores are SSIMULACRA2-native (0–100, 100 = identical), so `direction` is
  `:higher_better`.
  """
  @behaviour ImagePipe.Output.Metric

  @type ref :: Ssimulacra2.Reference.t()

  @impl true
  def direction, do: :higher_better

  @impl true
  def target_range, do: {0, 100}

  @impl true
  @spec reference(Vix.Vips.Image.t()) :: {:ok, ref()} | {:error, term()}
  def reference(%Vix.Vips.Image{} = image), do: Ssimulacra2.Vix.reference(image)

  @impl true
  @spec score(ref(), Vix.Vips.Image.t()) :: {:ok, float()} | {:error, term()}
  def score(reference, %Vix.Vips.Image{} = candidate),
    do: Ssimulacra2.Vix.compare(reference, candidate)
end
```

`lib/image_pipe/output/metric/butteraugli.ex`:
```elixir
defmodule ImagePipe.Output.Metric.Butteraugli do
  @moduledoc """
  Adapter over the `butteraugli` NIF — the only module that references
  `Butteraugli.*`. `reference/1` builds a reusable reference from the finalized
  pre-encode image; the loop calls `score/2` per decoded candidate. The targeted
  value is `Result.score` — the headline max butteraugli distance (lower = better;
  ~1.0 visually lossless), the same quantity libvips' JXL `distance` knob targets.
  `target_range` is libvips `jxlsave`'s own `distance` bound (min 0 / max 25).
  """
  @behaviour ImagePipe.Output.Metric

  @impl true
  def direction, do: :lower_better

  @impl true
  def target_range, do: {0.0, 25.0}

  @impl true
  @spec reference(Vix.Vips.Image.t()) :: {:ok, term()} | {:error, term()}
  def reference(%Vix.Vips.Image{} = image), do: Butteraugli.Vix.reference(image)

  @impl true
  @spec score(term(), Vix.Vips.Image.t()) :: {:ok, float()} | {:error, term()}
  def score(reference, %Vix.Vips.Image{} = candidate) do
    case Butteraugli.Vix.compare(reference, candidate) do
      {:ok, %{score: score}} -> {:ok, score}
      {:error, _reason} = err -> err
    end
  end
end
```

> Confirm the `Butteraugli.Vix.reference/1` + `Butteraugli.Reference.compare/2` arity against the installed NIF. If the package exposes only `Butteraugli.Vix.compare(img1, img2, opts)` (no reusable reference), implement `reference/1` to return `{:ok, image}` and `score/2` to call `Butteraugli.Vix.compare(reference_image, candidate)`. Adjust the `@type ref` accordingly.

- [ ] **Step 4: Delete `Ssim2Metric`, repoint `CropScore` + its arch test + the bench**

```bash
git rm lib/image_pipe/output/ssim2_metric.ex
```
In `lib/image_pipe/output/ssim2_metric/crop_score.ex`, change `alias ImagePipe.Output.Ssim2Metric` → `alias ImagePipe.Output.Metric.Ssimulacra2, as: Ssim2Metric` (keep the local `Ssim2Metric` alias name so the body — `Ssim2Metric.reference/1`, `Ssim2Metric.score/2` — is unchanged).

**Arch-test string trap (from plan review):** `test/image_pipe/architecture_boundary_test.exs:~352` does `refute crop_score.ex source =~ "Ssimulacra2"`. The new alias `Output.Metric.Ssimulacra2` introduces that literal → the test fails. Change the assertion to forbid the *raw NIF package* only, which CropScore still must not touch directly:
```elixir
refute source =~ "Ssimulacra2.Vix"
refute source =~ "Ssimulacra2.Reference"
```
(The intent — CropScore reaches the metric only through `Output.Metric.Ssimulacra2`, never the raw `Ssimulacra2.*` package — is preserved.)

**Bench alias (from plan review):** `test/support/mix/tasks/autoquality.bench.ex` aliases/uses `ImagePipe.Output.Ssim2Metric` (`Ssim2Metric.reference/score`). Repoint its alias to `ImagePipe.Output.Metric.Ssimulacra2, as: Ssim2Metric`. (Its `%RQS{objective:}` struct literals are migrated in Task 7.)

- [ ] **Step 5: Run the butteraugli test — expect pass**

Run: `mise exec -- mix test test/image_pipe/output/metric/butteraugli_test.exs`
Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add lib/image_pipe/output/metric.ex lib/image_pipe/output/metric/ lib/image_pipe/output/ssim2_metric/crop_score.ex test/image_pipe/output/metric/
git commit -m "feat(output): Metric behaviour + Ssimulacra2/Butteraugli runtimes"
```

## Task 6: `resolve_search/2` — per-struct, emit resolved external structs (infallible)

**Files:**
- Modify: `lib/image_pipe/output/policy.ex` (`resolve_search/2`, ~183-201)
- Test: `test/image_pipe/output_policy_test.exs`

**DESIGN CORRECTION (from plan review):** `resolve_search/2` is reached through the **infallible** `resolved/1` (`policy.ex:178`), which fans into `resolve/2`, `resolve_final_image_alpha/2` (+ `producer.ex:269`), and `supports_hdr?/2`. Making it return `{:error,_}` is a 5-site blast radius. And the existing **ssim2 path already range-validates at the parser** (`:target_float` enforces 0–100 in `option_grammar.ex`). So range validation belongs at the **parser** (Task 8), matching that precedent — and `resolve_search/2` stays **infallible** (returns the resolved value directly, like today). `Output.Metric.target_range/0` remains the source-of-truth constant the parser mirrors and the native clamp uses. Migrate the existing `%QualitySearch{objective:}`/`%ResolvedQualitySearch{}` cases in `output_policy_test.exs` (see migration checklist) in this task.

- [ ] **Step 1: Write the failing resolve test**

In `output_policy_test.exs` (mirror the existing resolve plumbing — it builds a `%Policy{}`/`%Output{}` and calls the resolve entry; reuse that helper):
```elixir
test "butteraugli plan resolves to external Butteraugli resolved struct (non-JXL)" do
  search = %ImagePipe.Plan.Output.QualitySearch.Butteraugli{
    target: 1.0, min_quality: 1, max_quality: 100, allowed_error: 0.1
  }
  assert %ImagePipe.Output.ResolvedQualitySearch.Butteraugli{target: 1.0} =
           resolve_search_for(search, :webp)
end
```

- [ ] **Step 2: Run — expect failure**

Run: `mise exec -- mix test test/image_pipe/output_policy_test.exs`
Expected: FAIL (compile error — `resolve_search` still matches the deleted single struct, and the existing ssim2 cases reference the old struct shape).

- [ ] **Step 3: Rewrite `resolve_search/2` (infallible, per-struct)**

Replace the `resolve_search/2` clauses in `policy.ex`. **No validation, returns the value directly** (keeps `resolved/1` infallible — zero blast-radius). Also migrate the existing ssim2/size cases in `output_policy_test.exs` to the new structs (drop `objective:`, match `%RQS.Ssimulacra2{}`/`%RQS.Size{}`, replace `rs.objective` reads with a struct match):
```elixir
  alias ImagePipe.Output.ResolvedQualitySearch, as: RQS

  defp resolve_search(%__MODULE__{quality_search: :none}, _format), do: :none

  defp resolve_search(%__MODULE__{quality_search: %Output.QualitySearch.Size{} = s}, format) do
    %RQS.Size{
      target: s.target,
      min_quality: Map.get(s.format_min, format, s.min_quality),
      max_quality: Map.get(s.format_max, format, s.max_quality),
      max_resolution: s.max_resolution
    }
  end

  defp resolve_search(
         %__MODULE__{quality_search: %Output.QualitySearch.Ssimulacra2{} = s} = policy,
         format
       ) do
    %RQS.Ssimulacra2{
      target: s.target,
      min_quality: Map.get(s.format_min, format, s.min_quality),
      max_quality: Map.get(s.format_max, format, s.max_quality),
      allowed_error: s.allowed_error,
      max_resolution: s.max_resolution,
      quality_search_offsets: %{
        photo: Output.offset_for(policy.quality_search_offsets, format, :photo),
        graphic: Output.offset_for(policy.quality_search_offsets, format, :graphic)
      }
    }
  end

  defp resolve_search(%__MODULE__{quality_search: %Output.QualitySearch.Butteraugli{} = s}, format) do
    %RQS.Butteraugli{
      target: s.target,
      min_quality: Map.get(s.format_min, format, s.min_quality),
      max_quality: Map.get(s.format_max, format, s.max_quality),
      allowed_error: s.allowed_error,
      max_resolution: s.max_resolution
    }
  end
```
(Phase 2 Task 13 splits the butteraugli clause by format. Range validation is the parser's job — Task 8.)

- [ ] **Step 4: Run resolve tests — expect pass**

Run: `mise exec -- mix test test/image_pipe/output_policy_test.exs`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add lib/image_pipe/output/policy.ex test/image_pipe/output_policy_test.exs
git commit -m "feat(output): resolve quality search per provider (infallible, per-struct)"
```

## Task 7: `EncodeSearch` — dispatch on resolved struct; direction-driven polarity

**Files:**
- Modify: `lib/image_pipe/output/encode_search.ex` (objective_phase, do_target/resolve_target, score_opts, run/3, moduledoc)
- Modify: `lib/image_pipe/output/encoder.ex` (`crop?/2`)
- Test: `test/image_pipe/output/encode_search_test.exs`

This is the core. The band search must invert for `:lower_better`. Keep `:higher_better` behavior byte-identical for ssim2.

- [ ] **Step 1: Write failing polarity tests (pure `search/3`, stub closures)**

In `encode_search_test.exs`, add tests that drive `search/3` with injected `encode_fun`/`score_fun` and a `:lower_better` resolved Butteraugli struct. Model a monotone-decreasing score(q): `score = 3.0 - q/50` so higher q → lower distance.
```elixir
alias ImagePipe.Output.ResolvedQualitySearch, as: RQS

defp const_encode, do: fn q -> :binary.copy(<<0>>, q) end   # bytes grow with q (monotone)

test "lower_better band search converges to in-band quality" do
  # target 1.0 ± 0.1 → band [0.9, 1.1]; score(q)=3.0 - q/50 hits 1.0 at q=100... pick params that land mid-bracket
  search = %RQS.Butteraugli{target: 1.0, min_quality: 70, max_quality: 95, allowed_error: 0.1}
  score_fun = fn bytes -> q = byte_size(bytes); 3.0 - q / 50 end
  assert {:ok, _bin, meta} =
    ImagePipe.Output.EncodeSearch.search(search, nil,
      encode_fun: const_encode(), score_fun: score_fun)
  assert meta.outcome in [:hit, :best_effort]
  assert meta.quality in 70..95
end

test "lower_better: distance above band searches HIGHER quality" do
  # A q whose distance > band_hi must drive the walk upward, not downward.
  # Assert the chosen q is at the high end when only high q gets the distance low enough.
  search = %RQS.Butteraugli{target: 0.5, min_quality: 70, max_quality: 95, allowed_error: 0.05}
  score_fun = fn bytes -> q = byte_size(bytes); 3.0 - q / 50 end  # needs q≈125 → unreachable
  assert {:ok, _bin, meta} =
    ImagePipe.Output.EncodeSearch.search(search, nil,
      encode_fun: const_encode(), score_fun: score_fun)
  assert meta.quality == 95              # pinned to ceiling (best quality) — never reached target
  assert meta.outcome == :best_effort
  assert meta.limiting_factor in [:ceiling, :floor]   # honest pin under inversion
end
```
(Tune the toy `score_fun`/params so the three cases — in-band, undershoot pin, straddle — are exercised. Add a third test for an empty-band straddle: pick `allowed_error` small enough that no integer q lands in-band and assert the shipped q is the one on the acceptable side, i.e. the higher-quality/lower-distance side.)

- [ ] **Step 2: Run — expect failure**

Run: `mise exec -- mix test test/image_pipe/output/encode_search_test.exs`
Expected: FAIL (the loop only knows `%RQS{objective: :ssim2}`; `%RQS.Butteraugli{}` hits no `objective_phase`/`score_opts` clause).

- [ ] **Step 3: Generalize the objective phase to a direction-aware band search**

In `encode_search.ex`, replace the single `objective_phase(%RQS{objective: :ssim2} = rqs, ...)` clause with two struct clauses sharing a direction-parameterized helper, and add a Size clause that matches the new struct. The `:size` clause changes only its match head (`%RQS.Size{}`) and uses `rqs.target` as before. New quality clauses:
```elixir
  defp objective_phase(%RQS.Ssimulacra2{} = rqs, ctx, _opts),
    do: quality_objective_phase(rqs, :higher_better, ctx)

  defp objective_phase(%RQS.Butteraugli{} = rqs, ctx, _opts),
    do: quality_objective_phase(rqs, :lower_better, ctx)

  defp quality_objective_phase(rqs, direction, ctx) do
    band_lo = rqs.target - rqs.allowed_error
    band_hi = rqs.target + rqs.allowed_error

    case search_to_target(rqs.min_quality, rqs.max_quality, band_lo, band_hi, direction, ctx) do
      {:error, _} = err ->
        err

      {chosen, outcome, factor, ctx} ->
        ctx = set_factor(ctx, factor)
        with {:ok, ctx} <- ensure_probed(chosen, ctx) do
          {:ok, chosen, outcome, Map.get(ctx.score_memo, chosen), ctx}
        end
    end
  end
```

- [ ] **Step 4: Invert the band-walk arms by direction**

Replace `search_to_target/5` and `do_target/7` with direction-threaded versions. The band membership test is symmetric; the two recursion arms and the overshoot bracket flip:
```elixir
  defp search_to_target(lo, hi, band_lo, band_hi, direction, ctx) do
    # ceiling = the bracket end we pin to when the target is never reached.
    # higher_better: pin to max_quality (hi) — best achievable score.
    # lower_better:  pin to max_quality (hi) too — best achievable (lowest) distance.
    do_target(lo, hi, band_lo, band_hi, direction, hi, nil, ctx)
  end

  defp do_target(lo, hi, _band_lo, _band_hi, _direction, ceiling, overshoot, ctx) when lo > hi do
    resolve_target(overshoot, ceiling, ctx)
  end

  defp do_target(lo, hi, band_lo, band_hi, direction, ceiling, overshoot, ctx) do
    mid = div(lo + hi, 2)

    case probe_score(mid, ctx) do
      {:error, _} = err ->
        err

      {:capped, ctx} ->
        resolve_target(overshoot, ceiling, ctx)

      {:ok, score, ctx} ->
        cond do
          score >= band_lo and score <= band_hi ->
            {mid, :hit, nil, ctx}

          # "acceptable-or-better" = the side that meets/exceeds the quality target.
          # higher_better: score > band_hi (over-quality) → record, search LOWER.
          # lower_better:  score < band_lo (distance below band = over-quality) → record, search LOWER.
          acceptable_overshoot?(direction, score, band_lo, band_hi) ->
            do_target(lo, mid - 1, band_lo, band_hi, direction, ceiling, mid, ctx)

          true ->
            do_target(mid + 1, hi, band_lo, band_hi, direction, ceiling, overshoot, ctx)
        end
    end
  end

  defp acceptable_overshoot?(:higher_better, score, _band_lo, band_hi), do: score > band_hi
  defp acceptable_overshoot?(:lower_better, score, band_lo, _band_hi), do: score < band_lo
```
`resolve_target/3` is unchanged in shape: a recorded overshoot ships as `:hit` (the just-past-band acceptable q); no overshoot pins to `ceiling` `:best_effort`. Because for both directions "acceptable" q are found by walking *down* in quality and the unreachable pin is the *ceiling* (max_quality, the best quality), the existing `resolve_target` semantics hold under the `acceptable_overshoot?` flip — verify with the straddle test.

- [ ] **Step 5: Generalize `score_opts` to the metric runtime**

Replace the two `objective: :ssim2` `score_opts` clauses and add the `:size` head change. The full-frame closure now calls `metric.score/2` via the runtime (not the hard-coded `Ssim2Metric`):
```elixir
  alias ImagePipe.Output.Metric

  defp score_opts(_image, %Resolved{quality_search: :none}, _scorer, _t), do: {:ok, []}
  defp score_opts(_image, %Resolved{quality_search: %RQS.Size{}}, _scorer, _t), do: {:ok, []}

  # Ssimulacra2: full-frame or crop (crop offset path unchanged from today).
  defp score_opts(image, %Resolved{quality_search: %RQS.Ssimulacra2{}}, :full, t) do
    full_frame_opts(Metric.Ssimulacra2, image, t)
  end

  defp score_opts(image, %Resolved{quality_search: %RQS.Ssimulacra2{} = rqs}, :crop, t) do
    tiles = CropScore.tile_count(Image.width(image), Image.height(image))
    offset = classify_offset(image, rqs.quality_search_offsets, t)
    crop = fn bytes -> crop_estimate(image, bytes, tiles, offset, t) end
    {:ok, [score_fun: crop, scorer_tiles: tiles]}
  end

  # Butteraugli: external-measure, full-frame only this cycle (scorer is forced :full — see encoder crop?).
  defp score_opts(image, %Resolved{quality_search: %RQS.Butteraugli{}}, _scorer, t) do
    full_frame_opts(Metric.Butteraugli, image, t)
  end

  defp full_frame_opts(metric, image, t) do
    case metric.reference(image) do
      {:ok, ref} -> {:ok, [score_fun: fn bytes -> full_frame_score(metric, ref, bytes, nil, t) end]}
      {:error, reason} -> {:error, {:encode, reason}}
    end
  end
```
And make `full_frame_score/4` take the metric module:
```elixir
  defp full_frame_score(metric, ref, bytes, tiles, telemetry_opts) do
    candidate = decode_leg(bytes, telemetry_opts)

    metric_leg(telemetry_opts, tiles, fn ->
      case metric.score(ref, candidate) do
        {:ok, score} -> score
        {:error, reason} -> throw({:image_pipe_score_error, reason})
      end
    end)
  end
```
(`crop_estimate/5` keeps calling `CropScore`, which still uses `Metric.Ssimulacra2` — unchanged; butteraugli never reaches it.)

- [ ] **Step 6: Force butteraugli to full-frame in `crop?/2`**

In `encoder.ex`, the `crop?/2` guard currently matches `%{objective: :ssim2}`. Replace with a match on the Ssimulacra2 resolved struct so only it can crop:
```elixir
  alias ImagePipe.Output.ResolvedQualitySearch, as: RQS

  defp crop?(%RQS.Ssimulacra2{}, megapixels), do: megapixels > CropScore.crossover_megapixels()
  defp crop?(_quality_search, _megapixels), do: false
```
(Both Butteraugli and Size fall through to `false` → `:full`.)

- [ ] **Step 7: Update the moduledoc monotonicity contract**

In `encode_search.ex` moduledoc, change "the SSIMULACRA2 score is non-decreasing in quality" to note both polarities:
```
  The binary search assumes encoded byte size is non-decreasing in quality, and
  the perceptual score is monotone in quality in the metric's direction —
  non-decreasing for `:higher_better` (SSIMULACRA2), non-increasing for
  `:lower_better` (butteraugli distance). The loop branches on direction rather
  than negating, so each walk arm is audited per polarity. Real encoders violate
  this locally; the consequence is bounded ...
```
Also update the `run/3`/`search/3` doc reference to `ImagePipe.Output.Ssim2Metric` → `ImagePipe.Output.Metric.*`. Update the now-stale inline comments inside `do_target` (the old "overshoot (score > band_hi)" lines) to reflect the direction-parameterized arms.

- [ ] **Step 7b: Migrate the `%RQS{}`/`.objective` helpers the split breaks (from plan review)**

These functions pattern-match the bare `%RQS{}` or read `.objective` and will not compile after Task 4. Give each per-struct clauses:
- `objective_of/1` — return the metric atom per struct: `objective_of(%RQS.Size{}) -> :size`, `%RQS.Ssimulacra2{} -> :ssimulacra2`, `%RQS.Butteraugli{} -> :butteraugli`, `objective_of(:none) -> :none`. (This is the telemetry `:objective` metadata **value** — value changes `:ssim2`→`:ssimulacra2`; do not rename the key.)
- `cap_floor/1` — `cap_floor(:none)` stays; add `cap_floor(%RQS.Size{min_quality: m})`, `%RQS.Ssimulacra2{min_quality: m}`, `%RQS.Butteraugli{min_quality: m}` → `m` (or one clause `cap_floor(%{min_quality: m})` matching all three, since all carry the field — acceptable here).
- `base_quality/2` — wherever it matches `%Resolved{quality_search: %RQS{max_quality: ...}}`, add the three struct clauses.
- `search_start_meta/2` and `search_stop_meta/2` — they call `objective_of/1`; once that is per-struct they compile. Verify no other `%RQS{}` field read inside them.
Also migrate the existing `%RQS{objective:}` literals in `encode_search_test.exs`, `encode_search_property_test.exs`, `encode_search_telemetry_test.exs`, `output_encoder_test.exs`, `resolved_test.exs`, `encoder_crop_scoring_test.exs`, and the `autoquality.bench.ex` structs (see migration checklist).

- [ ] **Step 7c: Add the empty-band straddle test**

In `encode_search_test.exs`, add a `:lower_better` straddle case: pick `allowed_error` small enough that no integer q lands in-band (e.g. target `1.0`, `allowed_error 0.001`), and assert the shipped q is on the **acceptable (lower-distance / higher-quality)** side, with `outcome == :hit` (the recorded overshoot ships). This is the case that actually exercises the flipped `acceptable_overshoot?`/`resolve_target` accumulator.

- [ ] **Step 8: Run the polarity tests + the existing ssim2 search tests — expect pass**

Run: `mise exec -- mix test test/image_pipe/output/encode_search_test.exs test/image_pipe/output/encode_search_property_test.exs test/image_pipe/output/encode_search_telemetry_test.exs`
Expected: PASS, including all pre-existing ssim2 cases (byte-identical behavior for `:higher_better`).

- [ ] **Step 9: Commit**

```bash
git add lib/image_pipe/output/encode_search.ex lib/image_pipe/output/encoder.ex test/image_pipe/output/ test/support/mix/tasks/autoquality.bench.ex
git commit -m "feat(output): direction-aware band search; dispatch encode search per resolved struct"
```

## Task 8: imgproxy parser — `aq:butteraugli` clause + defaults

**Files:**
- Modify: `lib/image_pipe/parser/imgproxy/option_grammar.ex` (parse_autoquality, field spec)
- Modify: `lib/image_pipe/parser/imgproxy/options.ex` (build per-objective, butteraugli defaults)
- Test: `test/image_pipe/parser/imgproxy/option_grammar_test.exs` (or the autoquality parser test)

- [ ] **Step 1: Write the failing grammar test**

```elixir
test "aq:butteraugli parses to a Butteraugli quality search" do
  assert {:ok, [quality_search: {:autoquality, fields}]} =
           OptionGrammar.parse("aq:butteraugli:1.0:75:95:0.1")
  assert Keyword.get(fields, :metric) == :butteraugli
  assert Keyword.get(fields, :target) == 1.0
  assert Keyword.get(fields, :min_quality) == 75
  assert Keyword.get(fields, :max_quality) == 95
  assert Keyword.get(fields, :allowed_error) == 0.1
end

test "aq:butteraugli target is not 0-100 clamped (distance > 100 allowed structurally)" do
  assert {:ok, [quality_search: {:autoquality, fields}]} =
           OptionGrammar.parse("aq:butteraugli:12.5")
  assert Keyword.get(fields, :target) == 12.5
end
```

- [ ] **Step 2: Run — expect failure**

Run: `mise exec -- mix test test/image_pipe/parser/imgproxy/option_grammar_test.exs`
Expected: FAIL (`butteraugli` hits the `parse_autoquality(_args, segment)` invalid-option fallback).

- [ ] **Step 3: Add the grammar clause + `:target_distance` field spec**

In `option_grammar.ex`, add before the catch-all `parse_autoquality(_args, segment)`:
```elixir
defp parse_autoquality(["butteraugli" | rest], segment) when length(rest) <= 4 do
  with {:ok, fields} <-
         parse_autoquality_args(rest, [
           :target_distance,
           :min_quality,
           :max_quality,
           :allowed_error
         ]) do
    autoquality_result([metric: :butteraugli] ++ fields, segment)
  end
end
```
Add the field-spec clause. Per the design correction (Task 6), the parser is where butteraugli's target range is validated — mirroring the existing `:target_float` clause that enforces `0.0..100.0` for ssim2. Enforce `0.0..25.0` (libvips `jxlsave` `distance` bound = `Output.Metric.Butteraugli.target_range/0`):
```elixir
defp parse_autoquality_field(:target_distance, value) do
  case parse_non_negative_float(value) do
    {:ok, float} when float <= 25.0 -> {:ok, {:target, float}}
    {:ok, _float} -> {:error, {:invalid_float, value}}
    {:error, _reason} = error -> error
  end
end
```
Also tag the existing size/ssim2 clauses with a metric for uniformity: change `[objective: :size]` → `[metric: :size]`, `[objective: :ssim2]` → `[metric: :ssimulacra2]`, and the bare `dssim` clause's `[objective: :ssim2]` → `[metric: :ssimulacra2]`. (This makes `metric:` the single selector key consumed by Options in Step 5.)

- [ ] **Step 4: Run grammar test — expect pass**

Run: `mise exec -- mix test test/image_pipe/parser/imgproxy/option_grammar_test.exs`
Expected: PASS.

- [ ] **Step 5: Build the right struct in Options + butteraugli defaults**

In `options.ex`:
- Add near `@default_ssim2_target 78`:
```elixir
# Default butteraugli distance target (≈ visually lossless) when a butteraugli
# search is active but neither URL nor host config supplies one.
@default_butteraugli_target 1.0
```
- **Migrate the host-config schema (from plan review):** in `lib/image_pipe/parser/imgproxy.ex` the NimbleOptions schema (~line 54) reads `autoquality_method: [type: {:in, [:none, :size, :ssim2]}, default: :none]`. Change to `{:in, [:none, :size, :ssimulacra2, :butteraugli]}` (greenfield — drop `:ssim2`), update the comment, and the `:autoquality_method` default plumbing (~line 314). A host that still wants `ssim2` uses `:ssimulacra2`. Without this, `autoquality_method: :ssimulacra2`/`:butteraugli` is rejected and `:ssim2` reaches a `build_quality_search` clause that no longer exists.
- Change `effective_quality_search_method/2` and `default_target/1` to key off `:metric` instead of `:objective` (rename the field read from `:objective` to `:metric`; the host-config key `:autoquality_method` now yields a metric atom `:size | :ssimulacra2 | :butteraugli`).
- **Validate the config-resolved target range (covers the config-default path, not just URL):** in `resolve_quality_search_target/3`, after resolving the target from URL-or-config, validate it against the metric's range (the parser owns range validation — Task 6 correction). Add a parser-local range map mirroring `Output.Metric.target_range/0` (the URL `:target_float`/`:target_distance` field specs already bound URL tokens; this catches a host-config default that is out of range):
```elixir
defp resolve_quality_search_target(metric, fields, defaults) do
  case Keyword.get(fields, :target, Keyword.get(defaults, :autoquality_target)) do
    nil -> default_target(metric)
    target -> validate_target_range(metric, target)
  end
end

# :size target is a byte count already validated by :target_bytes — no float range.
defp validate_target_range(:size, target), do: {:ok, target}

defp validate_target_range(metric, target) do
  {lo, hi} = metric_target_range(metric)
  if is_number(target) and target >= lo and target <= hi,
    do: {:ok, target},
    else: {:error, {:invalid_option, :autoquality, {:target_out_of_range, target}}}
end

# Mirrors Output.Metric.*.target_range/0 (parser may not depend on Output; same
# precedent as :target_float's inline 0–100 clamp).
defp metric_target_range(:ssimulacra2), do: {0.0, 100.0}
defp metric_target_range(:butteraugli), do: {0.0, 25.0}
```
- Replace `build_quality_search/3` with per-metric construction. The bracket defaults differ: ssim2/size keep `70`/`80`; **butteraugli defaults to full-range `1`/`100`** (so the bracket only bites when the user sets it — `dist(80)=1.9 > 1.0` would otherwise clamp every default request, Phase 2):
```elixir
defp build_quality_search(:size, fields, defaults) do
  with {:ok, target} <- resolve_quality_search_target(:size, fields, defaults) do
    {:ok,
     %QualitySearch.Size{
       target: target,
       min_quality: Keyword.get(fields, :min_quality, Keyword.get(defaults, :autoquality_min_quality, 70)),
       max_quality: Keyword.get(fields, :max_quality, Keyword.get(defaults, :autoquality_max_quality, 80)),
       format_min: Keyword.get(defaults, :autoquality_format_min_quality, %{}),
       format_max: Keyword.get(defaults, :autoquality_format_max_quality, %{}),
       max_resolution: Keyword.get(defaults, :autoquality_max_resolution, 0)
     }}
  end
end

defp build_quality_search(:ssimulacra2, fields, defaults),
  do: build_quality_metric(QualitySearch.Ssimulacra2, :ssimulacra2, fields, defaults, 70, 80)

defp build_quality_search(:butteraugli, fields, defaults),
  do: build_quality_metric(QualitySearch.Butteraugli, :butteraugli, fields, defaults, 1, 100)

defp build_quality_metric(struct_mod, metric, fields, defaults, default_min, default_max) do
  with {:ok, target} <- resolve_quality_search_target(metric, fields, defaults) do
    {:ok,
     struct(struct_mod, %{
       target: target,
       min_quality: Keyword.get(fields, :min_quality, Keyword.get(defaults, :autoquality_min_quality, default_min)),
       max_quality: Keyword.get(fields, :max_quality, Keyword.get(defaults, :autoquality_max_quality, default_max)),
       allowed_error: Keyword.get(fields, :allowed_error, Keyword.get(defaults, :autoquality_allowed_error, 1.0)),
       format_min: Keyword.get(defaults, :autoquality_format_min_quality, %{}),
       format_max: Keyword.get(defaults, :autoquality_format_max_quality, %{}),
       max_resolution: Keyword.get(defaults, :autoquality_max_resolution, 0)
     })}
  end
end
```
- Extend `default_target/1`:
```elixir
defp default_target(:ssimulacra2), do: {:ok, @default_ssim2_target}
defp default_target(:butteraugli), do: {:ok, @default_butteraugli_target}
defp default_target(_metric), do: {:error, {:invalid_option, :autoquality, :missing_target}}
```
> Note: butteraugli's default `allowed_error` reuses `1.0`, which is huge on the distance scale. Set a butteraugli-appropriate default if the host doesn't supply one — e.g. read `:autoquality_allowed_error` but fall back to `0.1` for butteraugli. Adjust `build_quality_metric` to take a `default_error` param (`1.0` for ssim2, `0.1` for butteraugli).

- [ ] **Step 6: Run the parser + options tests — expect pass**

Run: `mise exec -- mix test test/image_pipe/parser/imgproxy/`
Expected: PASS. Existing ssim2/size/dssim/none tests still pass (now via `metric:` tags).

- [ ] **Step 7: Commit**

```bash
git add lib/image_pipe/parser/imgproxy/ test/image_pipe/parser/imgproxy/
git commit -m "feat(parser): aq:butteraugli imgproxy clause + per-metric quality search build"
```

## Task 9: Wire-level test — butteraugli shrinks pixels on a non-JXL format

**Files:**
- Test: `test/image_pipe/imgproxy_wire_conformance_test.exs` (add a butteraugli case)

- [ ] **Step 1: Write the failing wire test**

```elixir
test "aq:butteraugli produces a smaller-but-valid WebP vs max quality" do
  # Build two requests through ImagePipe.call/2: one webp at max quality, one with aq:butteraugli.
  # Assert: 200, content-type image/webp, decoded dims equal, autoquality body smaller bytes.
  baseline = request_webp(quality: 100)
  auto = request_webp_autoquality("butteraugli:1.0:1:100:0.1")
  assert byte_size(auto.resp_body) < byte_size(baseline.resp_body)
  assert {:ok, a} = Image.from_binary(auto.resp_body)
  assert {:ok, b} = Image.from_binary(baseline.resp_body)
  assert {Image.width(a), Image.height(a)} == {Image.width(b), Image.height(b)}
end
```
Mirror the construction of an existing `imgproxy_wire_conformance_test.exs` autoquality/ssim2 case for the request helpers.

- [ ] **Step 2: Run — expect pass (the pipeline is wired end-to-end now)**

Run: `mise exec -- mix test test/image_pipe/imgproxy_wire_conformance_test.exs`
Expected: PASS. If it fails on the encode/score path, debug the closure wiring from Task 7.

- [ ] **Step 3: Commit**

```bash
git add test/image_pipe/imgproxy_wire_conformance_test.exs
git commit -m "test(wire): aq:butteraugli shrinks a non-JXL encode end-to-end"
```

## Task 10: Phase 1 docs + fiddle + full gate

**Files:**
- Modify: `docs/imgproxy_support_matrix.md` (autoquality surface row + config note)
- Modify: `fiddle/assets/...` (autoquality control: add butteraugli option + URL state)

- [ ] **Step 1: Conformance matrix (surface axis)**

In `docs/imgproxy_support_matrix.md`, on the `autoquality`/`aq` row, add the `aq:butteraugli:<target>:<min>:<max>:<allowed_error>` form as a documented ImagePipe extension (imgproxy has no butteraugli method); in the "Autoquality and byte-budget search" config section add `@default_butteraugli_target 1.0` and the full-range butteraugli bracket default. Note butteraugli is lower-is-better and full-frame-only.

- [ ] **Step 2: Fiddle UI**

In `fiddle/assets/`, add `butteraugli` to the autoquality method control and URL state (mirror the existing `ssim2` option: a target field + min/max/allowed_error). Build: `pnpm -C fiddle/assets run build`.

- [ ] **Step 3: Full gate**

Run: `mise run precommit` (and `mise run precommit:fiddle` since fiddle changed).
Expected: format/compile/credo/test all green.

- [ ] **Step 4: Commit**

```bash
git add docs/imgproxy_support_matrix.md fiddle/
git commit -m "docs(imgproxy): document aq:butteraugli; add butteraugli to fiddle autoquality"
```

---

# PHASE 2 — Native JXL strategy

End state: `aq:butteraugli` on JPEG XL drives libvips' native `distance` knob (single encode), honors `min/max_quality` via a libjxl Q→distance clamp, and self-caps for `max_bytes`.

## Task 11: JXL `distance` encoder suffix

**Files:**
- Modify: `lib/image_pipe/output/encoder.ex` (`jxl_vix_suffix/1`; add a buffer-encode-at-distance entry the native strategy can call)
- Test: `test/image_pipe/output/encoder_test.exs`

- [ ] **Step 1: Write the failing test**

```elixir
test "jxl distance suffix encodes a valid JXL" do
  {:ok, img} = Image.new(64, 64, color: [100, 110, 120])
  assert {:ok, bin} = ImagePipe.Output.Encoder.encode_jxl_distance(img, 1.5)
  assert {:ok, decoded} = Image.from_binary(bin)
  assert Image.width(decoded) == 64
end
```

- [ ] **Step 2: Run — expect failure**

Run: `mise exec -- mix test test/image_pipe/output/encoder_test.exs`
Expected: FAIL (`encode_jxl_distance/2` undefined).

- [ ] **Step 3: Add the distance suffix + a public buffer encode**

In `encoder.ex`, add a `jxl_vix_suffix` clause and a small public function the native strategy uses:
```elixir
  defp jxl_vix_suffix({:distance, value}), do: ".jxl[distance=#{value}]"
```
```elixir
  @doc """
  Encode `image` to a JPEG XL buffer at a target butteraugli `distance`
  (0.0–25.0). Used by the native-JXL autoquality strategy. Failures surface as
  `{:error, {:encode, _, _}}`, consistent with `encode_jxl_buffer/2`.
  """
  @spec encode_jxl_distance(VixImage.t(), number()) :: {:ok, binary()} | {:error, term()}
  def encode_jxl_distance(%VixImage{} = image, distance) do
    case VixImage.write_to_buffer(image, jxl_vix_suffix({:distance, distance})) do
      {:ok, binary} -> {:ok, binary}
      {:error, reason} -> {:error, {:encode, encode_error(reason), []}}
    end
  rescue
    exception -> {:error, {:encode, exception, __STACKTRACE__}}
  end
```

- [ ] **Step 4: Run — expect pass**

Run: `mise exec -- mix test test/image_pipe/output/encoder_test.exs`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add lib/image_pipe/output/encoder.ex test/image_pipe/output/encoder_test.exs
git commit -m "feat(output): JXL distance encode suffix + encode_jxl_distance/2"
```

## Task 12: libjxl Q→distance formula module + drift guard

**Files:**
- Create: `lib/image_pipe/output/jxl_distance.ex`
- Test: `test/image_pipe/output/jxl_distance_test.exs`

- [ ] **Step 1: Write the failing unit + drift-guard tests**

`test/image_pipe/output/jxl_distance_test.exs`:
```elixir
defmodule ImagePipe.Output.JxlDistanceTest do
  use ExUnit.Case, async: true
  alias ImagePipe.Output.JxlDistance

  test "known points match libjxl mapping" do
    assert_in_delta JxlDistance.from_quality(100), 0.0, 1.0e-6
    assert_in_delta JxlDistance.from_quality(90), 1.0, 1.0e-6
    assert_in_delta JxlDistance.from_quality(80), 1.9, 1.0e-6
    assert_in_delta JxlDistance.from_quality(70), 2.8, 1.0e-6
  end

  test "monotone non-increasing in quality" do
    ds = Enum.map(1..100, &JxlDistance.from_quality/1)
    assert ds == Enum.sort(ds, :desc)
  end

  @tag :jxl   # requires libvips jxlsave; runs on the default lane in this repo
  test "drift guard: encode(Q=q) is byte-identical to encode(distance=from_quality(q))" do
    {:ok, img} = Image.new(96, 96, color: [40, 160, 90])
    for q <- [50, 70, 80, 90] do
      {:ok, by_q} = Vix.Vips.Image.write_to_buffer(img, ".jxl[Q=#{q}]")
      {:ok, by_d} = ImagePipe.Output.Encoder.encode_jxl_distance(img, JxlDistance.from_quality(q))
      assert by_q == by_d, "Q=#{q} diverged from distance=#{JxlDistance.from_quality(q)} — libjxl formula drift"
    end
  end
end
```

- [ ] **Step 2: Run — expect failure**

Run: `mise exec -- mix test test/image_pipe/output/jxl_distance_test.exs`
Expected: FAIL (module undefined).

- [ ] **Step 3: Implement the formula**

`lib/image_pipe/output/jxl_distance.ex`:
```elixir
defmodule ImagePipe.Output.JxlDistance do
  @moduledoc """
  libjxl's quality→distance mapping (`JxlEncoderDistanceFromQuality`), replicated
  so the native-JXL autoquality strategy can clamp a butteraugli-distance target
  into a Q-scale `[min_quality, max_quality]` bracket. Monotone non-increasing in
  quality. This duplicates a libjxl encode-internal; the duplication is pinned by
  a drift-guard test asserting `encode(Q=q) == encode(distance=from_quality(q))`
  against the installed libvips/libjxl (see `jxl_distance_test.exs`).
  """

  @doc "Target butteraugli distance for an integer/float JXL quality `q`."
  @spec from_quality(number()) :: float()
  def from_quality(q) when q >= 100, do: 0.0
  def from_quality(q) when q >= 90, do: (100 - q) * 0.10
  def from_quality(q) when q >= 30, do: 0.1 + (100 - q) * 0.09
  def from_quality(q) when q > 0, do: 15.0 + (59.0 * q - 4350.0) * q / 9000.0
  def from_quality(_q), do: 15.0
end
```

- [ ] **Step 4: Run — expect pass**

Run: `mise exec -- mix test test/image_pipe/output/jxl_distance_test.exs`
Expected: PASS (incl. the drift guard). If the drift guard fails, the installed libjxl's formula differs from this copy — update `from_quality/1` to match and note the libvips/libjxl version.

- [ ] **Step 5: Commit**

```bash
git add lib/image_pipe/output/jxl_distance.ex test/image_pipe/output/jxl_distance_test.exs
git commit -m "feat(output): libjxl Q->distance formula with encode-equivalence drift guard"
```

## Task 13: Native strategy resolved struct + resolve selection

**Files:**
- Create: `lib/image_pipe/output/resolved_quality_search/native_jxl_butteraugli.ex`
- Modify: `lib/image_pipe/output/policy.ex` (butteraugli clause branches on format)
- Test: `test/image_pipe/output_policy_test.exs`

- [ ] **Step 1: Write the failing resolve test**

```elixir
test "butteraugli + JXL resolves to the native strategy" do
  search = %ImagePipe.Plan.Output.QualitySearch.Butteraugli{
    target: 1.0, min_quality: 1, max_quality: 100, allowed_error: 0.1
  }
  assert %ImagePipe.Output.ResolvedQualitySearch.NativeJxlButteraugli{target: 1.0} =
           resolve_search_for(search, :jpeg_xl)
end

test "butteraugli + webp stays external" do
  search = %ImagePipe.Plan.Output.QualitySearch.Butteraugli{
    target: 1.0, min_quality: 1, max_quality: 100, allowed_error: 0.1
  }
  assert %ImagePipe.Output.ResolvedQualitySearch.Butteraugli{} = resolve_search_for(search, :webp)
end
```

- [ ] **Step 2: Run — expect failure**

Run: `mise exec -- mix test test/image_pipe/output/policy_test.exs`
Expected: FAIL (native struct undefined; JXL still resolves to external `Butteraugli`).

- [ ] **Step 3: Create the resolved struct**

`lib/image_pipe/output/resolved_quality_search/native_jxl_butteraugli.ex`:
```elixir
defmodule ImagePipe.Output.ResolvedQualitySearch.NativeJxlButteraugli do
  @moduledoc """
  Resolved native-JXL butteraugli strategy: libvips drives `distance` directly, so
  there is no external measurement. `min_quality`/`max_quality` are Q-scale bracket
  bounds clamped into distance space (libjxl Q→distance) at execution; `max_bytes`
  is honored by raising `distance` from the clamped target until the bytes fit.
  """
  @enforce_keys [:target, :min_quality, :max_quality]
  defstruct @enforce_keys ++ [allowed_error: 0, max_resolution: 0]

  @type t :: %__MODULE__{
          target: number(),
          min_quality: 1..100,
          max_quality: 1..100,
          allowed_error: number(),
          max_resolution: non_neg_integer()
        }
end
```

- [ ] **Step 4: Branch the butteraugli resolve clause on format**

In `policy.ex`, split the (infallible) butteraugli `resolve_search` clause from Task 6 by format — the `:jpeg_xl` clause must come first:
```elixir
  defp resolve_search(%__MODULE__{quality_search: %Output.QualitySearch.Butteraugli{} = s}, :jpeg_xl) do
    %RQS.NativeJxlButteraugli{
      target: s.target,
      min_quality: Map.get(s.format_min, :jpeg_xl, s.min_quality),
      max_quality: Map.get(s.format_max, :jpeg_xl, s.max_quality),
      allowed_error: s.allowed_error,
      max_resolution: s.max_resolution
    }
  end

  defp resolve_search(%__MODULE__{quality_search: %Output.QualitySearch.Butteraugli{} = s}, format) do
    %RQS.Butteraugli{
      target: s.target,
      min_quality: Map.get(s.format_min, format, s.min_quality),
      max_quality: Map.get(s.format_max, format, s.max_quality),
      allowed_error: s.allowed_error,
      max_resolution: s.max_resolution
    }
  end
```

- [ ] **Step 5: Run — expect pass**

Run: `mise exec -- mix test test/image_pipe/output/policy_test.exs`
Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add lib/image_pipe/output/resolved_quality_search/native_jxl_butteraugli.ex lib/image_pipe/output/policy.ex test/image_pipe/output/policy_test.exs
git commit -m "feat(output): select NativeJxlButteraugli strategy for (butteraugli, jpeg_xl)"
```

## Task 14: `NativeJxlButteraugli` execution in `EncodeSearch`

**Files:**
- Modify: `lib/image_pipe/output/encode_search.ex` (run/3 dispatch, native strategy, `:native` outcome)
- Test: `test/image_pipe/output/encode_search_test.exs`

The native strategy is self-contained: it does NOT go through `search/3`'s band loop. Dispatch it from `run/3` on the resolved struct.

- [ ] **Step 1: Write the failing native-strategy tests**

```elixir
alias ImagePipe.Output.ResolvedQualitySearch, as: RQS
alias ImagePipe.Output.{Resolved, EncodeSearch}

test "native jxl butteraugli: no max_bytes → single encode, outcome :native, no NIF" do
  {:ok, img} = Image.new(128, 128, color: [10, 20, 30])
  resolved = %Resolved{format: :jpeg_xl, quality: :default, max_bytes: nil,
    quality_search: %RQS.NativeJxlButteraugli{target: 1.0, min_quality: 1, max_quality: 100, allowed_error: 0.1}}
  assert {:ok, bin, meta} = EncodeSearch.run(img, resolved, [])
  assert {:ok, _} = Image.from_binary(bin)
  assert meta.outcome == :native
  assert meta.iterations == 0
  assert meta.score == nil
end

test "native jxl butteraugli: explicit max_quality is never exceeded" do
  # target 1.0 (= Q90) with max_quality 80 (= dist 1.9) → clamps to dist 1.9, never higher quality.
  {:ok, img} = Image.new(256, 256, color: [200, 60, 60])
  clamped = %Resolved{format: :jpeg_xl, quality: :default, max_bytes: nil,
    quality_search: %RQS.NativeJxlButteraugli{target: 1.0, min_quality: 1, max_quality: 80, allowed_error: 0.1}}
  uncapped = put_in(clamped.quality_search.max_quality, 100)
  {:ok, capped_bin, _} = EncodeSearch.run(img, clamped, [])
  {:ok, free_bin, _} = EncodeSearch.run(img, uncapped, [])
  # clamped (Q80) must not be larger (higher quality) than the unclamped (Q90) encode.
  assert byte_size(capped_bin) <= byte_size(free_bin)
end

test "native jxl butteraugli: max_bytes degrades distance and self-caps" do
  {:ok, img} = Image.new(512, 512, color: [123, 222, 64])
  {:ok, big, _} = EncodeSearch.run(img,
    %Resolved{format: :jpeg_xl, quality: :default, max_bytes: nil,
      quality_search: %RQS.NativeJxlButteraugli{target: 0.3, min_quality: 1, max_quality: 100, allowed_error: 0.05}}, [])
  budget = div(byte_size(big), 2)
  {:ok, capped, meta} = EncodeSearch.run(img,
    %Resolved{format: :jpeg_xl, quality: :default, max_bytes: budget,
      quality_search: %RQS.NativeJxlButteraugli{target: 0.3, min_quality: 1, max_quality: 100, allowed_error: 0.05}}, [])
  assert byte_size(capped) <= budget
  assert meta.outcome in [:native, :best_effort]
end
```

- [ ] **Step 2: Run — expect failure**

Run: `mise exec -- mix test test/image_pipe/output/encode_search_test.exs`
Expected: FAIL (`run/3` has no clause for `%RQS.NativeJxlButteraugli{}`).

- [ ] **Step 3: Add `:native` to the outcome type**

In `encode_search.ex`:
```elixir
  @type outcome :: :hit | :best_effort | :skipped | :native
```

- [ ] **Step 4: Dispatch + implement the native strategy in `run/3`**

At the top of `run/3`, before the existing body, add a clause that intercepts the native resolved struct (pattern-match on `resolved.quality_search`):
```elixir
  def run(finalized_image, %Resolved{quality_search: %RQS.NativeJxlButteraugli{} = nqs} = resolved, opts) do
    telemetry_opts = Keyword.get(opts, :telemetry_opts, [])
    native_jxl_butteraugli(finalized_image, nqs, resolved.max_bytes, telemetry_opts)
  end

  def run(finalized_image, %Resolved{} = resolved, opts) do
    # ... existing body unchanged ...
  end
```
Implement the strategy (clamp first, then single encode or distance-degrade self-cap):
```elixir
  alias ImagePipe.Output.{Encoder, JxlDistance}

  @native_distance_max 25.0

  defp native_jxl_butteraugli(image, nqs, max_bytes, telemetry_opts) do
    # Q-bracket → distance bracket; clamp the target. dist is decreasing in Q, so
    # max_quality is the distance floor (lowest distance / highest quality allowed).
    dist_floor = JxlDistance.from_quality(nqs.max_quality)
    dist_ceil = JxlDistance.from_quality(nqs.min_quality)
    effective = nqs.target |> max(dist_floor) |> min(dist_ceil)

    Telemetry.span(telemetry_opts, [:encode, :search], native_start_meta(nqs), fn ->
      result = native_encode(image, effective, max_bytes)
      {result, native_stop_meta(result)}
    end)
  end

  defp native_encode(image, distance, nil) do
    with {:ok, bin} <- Encoder.encode_jxl_distance(image, distance) do
      {:ok, bin, native_meta(distance, bin, :native, nil)}
    end
  end

  defp native_encode(image, distance, max_bytes) do
    native_descend(image, distance, max_bytes)
  end

  # Raise distance (degrade) from the clamped target until bytes fit or we hit the
  # distance ceiling. Coarse geometric steps; max_bytes is the hard cap. `effective`
  # is always <= dist_ceil = from_quality(min_quality) <= ~14.5 (min_quality >= 1),
  # so the recursion saturates at @native_distance_max in finite steps.
  defp native_descend(image, distance, max_bytes) do
    with {:ok, bin} <- Encoder.encode_jxl_distance(image, distance) do
      cond do
        byte_size(bin) <= max_bytes -> {:ok, bin, native_meta(bin, :native, nil)}
        distance >= @native_distance_max -> {:ok, bin, native_meta(bin, :best_effort, :max_bytes)}
        true -> native_descend(image, min(@native_distance_max, distance * 1.5 + 0.5), max_bytes)
      end
    end
  end

  defp native_meta(bin, outcome, factor) do
    %{
      quality: 0,
      bytes: byte_size(bin),
      iterations: 0,
      outcome: outcome,
      score: nil,
      confirm_passes: 0,
      scorer: :full,
      tiles_scored: nil,
      limiting_factor: factor
    }
  end
```
**`meta.quality` type (resolved, not open):** the native path picks no Q, so set `quality: 0` and **widen `@type meta` `quality:` from `1..100` to `0..100`** in the same edit, with a comment: `# 0 = native distance encode, no Q chosen`. (The reviewer confirmed consumers — `search_stop_meta`, Logger, OTel — tolerate the value at runtime; this just keeps the typespec honest. The earlier `native_descend/4` `:final` clause and the `> @native_distance_max` guard were removed as dead code: `effective` can never exceed ~14.5 and `min/2` caps the step at exactly 25.0, so the `>` branch is unreachable.)

Add `native_start_meta/1` and `native_stop_meta/1` mirroring `search_start_meta`/`search_stop_meta` (objective value `:butteraugli`, scorer `:full`) so the `[:encode, :search]` span stays uniform; `native_stop_meta({:ok, _bin, meta})` maps the same keys as `search_stop_meta`.

- [ ] **Step 5: Run — expect pass**

Run: `mise exec -- mix test test/image_pipe/output/encode_search_test.exs`
Expected: PASS (native cases + all earlier cases).

- [ ] **Step 6: Commit**

```bash
git add lib/image_pipe/output/encode_search.ex test/image_pipe/output/encode_search_test.exs
git commit -m "feat(output): NativeJxlButteraugli execution (bracket clamp + max_bytes self-cap)"
```

## Task 15: Phase 2 wire test, telemetry sync, docs, full gate

**Files:**
- Test: `test/image_pipe/imgproxy_wire_conformance_test.exs`
- Modify: `lib/image_pipe/telemetry/logger.ex`, `lib/image_pipe/telemetry/trace/capture.ex`, `docs/telemetry.md`
- Modify: `docs/imgproxy_support_matrix.md` (stage/order + behavioral)

- [ ] **Step 1: Wire test — JXL+butteraugli takes the single-encode path**

```elixir
test "aq:butteraugli on JXL takes the native single-encode path" do
  # Request format jxl (Accept: image/jxl or explicit) with aq:butteraugli.
  # Assert 200, content-type image/jxl, decoded dims preserved, and (if meta is
  # observable via telemetry) outcome :native / iterations 0.
end
```
Use a `telemetry_prefix` (per the telemetry test rule in `AGENTS.md`) and attach to the prefixed `[:encode, :search]` `:stop` to assert `outcome: :native`, `iterations: 0`.

- [ ] **Step 2: Telemetry Logger + OTel sync**

The native path emits the existing `[:encode, :search]` span — already subscribed. If `native_stop_meta` adds a new `outcome: :native` value or a `:metric` key:
- `lib/image_pipe/telemetry/logger.ex`: ensure the `[:encode, :search]` render surfaces `outcome` (it falls through `outcome(meta)`); add a `:native` case if a friendlier line is wanted (must still surface the outcome). Add a `logger_test.exs` assertion.
- `lib/image_pipe/telemetry/trace/capture.ex`: confirm `[:encode, :search]` is in `@span_stages` (it is) and that `outcome`/`metric` keys are in `@safe_keys`; add `:metric` if introduced. Add a Capture test.
- `docs/telemetry.md`: note the native `outcome: :native`.

- [ ] **Step 2b: De-`:ssim2` the probe cost-leg span names (Chunk 1 review carry-over)**

`encode_search.ex`'s `decode_leg/2` + `metric_leg/3` hardcode the metric segment `:ssim2` in their span names (`[:encode, :search, :probe, :ssim2, :decode]` / `[…, :ssim2, :metric]`), and their doc comment promises the segment "qualifies the scoring legs so a future metric gets distinct span names a backend can group by." Butteraugli currently reuses `:ssim2` → its cost legs are **mislabeled**. Now that the metric module is threaded through `full_frame_score/5`, derive the leg segment from the metric instead of hardcoding `:ssim2`. Per `AGENTS.md`'s telemetry sync rule, any new stage name introduced here must be registered on **both** surfaces or butteraugli's legs go untraced/unlogged:
- Thread a metric-derived leg-name segment (e.g. `:ssimulacra2`/`:butteraugli`, or a `leg_name/0` on the `Output.Metric` behaviour) into `decode_leg`/`metric_leg`; update the comment to describe the actual behavior.
- `lib/image_pipe/telemetry/trace/capture.ex`: add the new `[:encode, :search, :probe, <metric>, :decode]` and `[…, <metric>, :metric]` stages to `@span_stages` (the current list only has the `:ssim2` variants). Add a Capture test asserting the butteraugli legs are captured.
- `lib/image_pipe/telemetry/logger.ex`: subscribe the new leg stage names (one-shot/span lists) so they aren't silently dropped; add a `logger_test.exs` assertion.
- `docs/telemetry.md`: update the probe cost-leg names to reflect per-metric segments.
- If, after this, the crop-path `metric_leg`'s "aggregate SSIMULACRA2 metric leg" comment is inaccurate for butteraugli's full-frame leg, fix the comment too.

- [ ] **Step 3: Conformance matrix (stage/order + behavioral)**

In `docs/imgproxy_support_matrix.md`: in the Save/encode pipeline section, document the native-JXL butteraugli single-encode path (`iterations: 0`, distance-driven, self-capping for max_bytes); update the existing line claiming "a butteraugli distance mapping is deferred" — it's now implemented. Add the lower-is-better/full-frame behavioral note.

- [ ] **Step 4: Full gate**

Run: `mise run precommit:fiddle`
Expected: all green (format, compile --warnings-as-errors, credo --strict, test, fiddle suite).

- [ ] **Step 5: Commit**

```bash
git add test/ lib/image_pipe/telemetry/ docs/
git commit -m "feat(output): wire native JXL butteraugli; telemetry + conformance sync"
```

---

## Self-Review notes (author checklist — already applied)

- **Spec coverage:** provider abstraction (T5), per-provider Plan structs (T2), polarity-neutral search (T7), resolve-time strategy selection / native seam (T6, T13, T14), bracket clamp + max_bytes self-cap (T14), `target_range` validation (T6), struct-split fan-out — cache key (T3), exports + arch mirror (T2), full-frame-only crop guard (T7 Step 6), parser extension + butteraugli defaults (T8), conformance + fiddle + telemetry (T10, T15). butteraugli crop proxy + calibration bake are spec Non-Goals (not planned).
- **Type consistency:** `RQS` = `ImagePipe.Output.ResolvedQualitySearch`; resolved structs `RQS.{Size,Ssimulacra2,Butteraugli,NativeJxlButteraugli}`; metric runtimes `Output.Metric.{Ssimulacra2,Butteraugli}` with `direction/0,target_range/0,reference/1,score/2`; `JxlDistance.from_quality/1`; `Encoder.encode_jxl_distance/2`. Parser emits `metric:` tag (`:size|:ssimulacra2|:butteraugli`) consumed by `Options.build_quality_search/3`.
- **Open confirmations for the implementer (flagged inline):** exact `Butteraugli.Vix` reference/compare arity (T5); whether `resolve_search`'s caller already threads `{:error,_}` (T6); the `meta.quality` `0`-vs-widen decision for the native path (T14). These are environmental/contract checks best done against the running code, not guessable from the spec.
