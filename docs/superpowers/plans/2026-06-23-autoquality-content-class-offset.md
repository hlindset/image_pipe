# Autoquality `{format, content-class} → offset` Policy Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the single global confirm-skipped offset (`@crop_confirm_skipped_offset = 2.4`) with a `{format, content-class} → offset` policy keyed on a cheap libvips content classifier, so large AVIF dense-graphic renders stop shipping silently under-quality above the 6 MP crop crossover.

**Architecture:** A new `ImagePipe.Output.ContentClassifier` classifies the finalized image (`:photo` / `:graphic`) lazily, only inside the `:ssim2`+>6 MP crop-scoring path where the offset is consumed. The declarative `{format, class} → offset` table lives on `Plan.Output` (defaulted, a future parser seam like `flatten_background`), is resolved per negotiated format into `ResolvedQualitySearch`, and is applied as a per-class offset in `EncodeSearch.crop_estimate`. A `[:encode, :classify]` telemetry span surfaces the class + applied offset.

**Tech Stack:** Elixir, libvips via `Vix.Vips.Operation` / `Image`, `:telemetry`, ExUnit, the `mix autoquality.bench` test-support task.

**Spec:** `docs/superpowers/specs/2026-06-23-autoquality-content-class-offset-design.md`

---

## File Structure

- **Create** `lib/image_pipe/output/content_classifier.ex` — the classifier (downsample → features → `:photo`/`:graphic`, safe fallback). One responsibility: turn a finalized image into a content class.
- **Create** `test/image_pipe/output/content_classifier_test.exs` — classifier unit tests.
- **Modify** `lib/image_pipe/plan/output.ex` — add the `quality_search_offsets` field + default policy helper.
- **Modify** `lib/image_pipe/output/resolved_quality_search.ex` — add the resolved per-class `quality_search_offsets` field.
- **Modify** `lib/image_pipe/output/policy.ex` — carry the field through the policy struct; collapse the table per-format in `resolve_search`.
- **Modify** `lib/image_pipe/output/encode_search.ex` — remove the constant; classify + look up offset in the `:crop` `score_opts` clause; parametrize `crop_estimate`; emit the classify span.
- **Modify** `lib/image_pipe/telemetry/logger.ex` — subscribe + render the classify span.
- **Modify** `lib/image_pipe/telemetry/trace/capture.ex` — trace the classify span; allowlist its metadata keys.
- **Modify** `docs/telemetry.md` — document the new span on both surfaces.
- **Modify** `test/support/mix/tasks/autoquality.bench.ex` — report the exact shipped 2-feature rule (to pin/validate the constants).
- **Modify** `test/image_pipe/output_policy_test.exs` — resolution test for the table collapse.
- **Modify** `test/image_pipe/output/encoder_crop_scoring_test.exs` — adapt to the offset-as-parameter shape.
- **Modify** `test/image_pipe/imgproxy_wire_conformance_test.exs` — the request-boundary acceptance test + a `:graphic` large-AVIF origin.

**Note on `lib/image_pipe/cache/key.ex`:** `output_plan_data/2` enumerates cache-key fields explicitly (no whole-struct serialization, no `KeyData` protocol impl for `%Output{}`). **Do NOT add `quality_search_offsets` to it** — the policy is a constant default (never request-varying), so it stays out of the key and ETag (spec §2; the ETag path `http_cache.ex` → `Key.plan_material/2` shares `output_plan_data/2`). No change to `key.ex` is required, and a cache-key test would be a no-op pin.

**Note on the `Output` boundary:** **no `output.ex` `exports:`/`deps:` change is needed.** `ContentClassifier` is an unexported sibling consumed only by `EncodeSearch` (also intra-`Output`, unexported — like `Ssim2Metric`/`CropScore`); Boundary requires `exports:` only for cross-boundary refs. `Vix`/`Image` are external libraries, not boundaries, so the existing `deps: [Format, Plan, Telemetry]` already covers the classifier. Task 8 Step 2 asserts this.

---

## Task 1: Pin the empirical constants via the bench

**Files:**
- Modify: `test/support/mix/tasks/autoquality.bench.ex` (around the Part M separation report, `m_report_separation/1` near line 3800)

This task produces three frozen numbers consumed by Tasks 2 and 3:
1. `θ_palette` — `palette_ent` photo-side Youden threshold
2. `θ_nat` — `nat_var` photo-side Youden threshold
3. the `{:avif, :graphic}` offset (round the avif×screen residual p90 ≈ 6.07)

The bench already reports per-feature θ (the `θ` column) and the 4-/5-feature AND-rules, but **not** the exact shipped 2-feature rule. Add that report so the run confirms `palette_ent ∧ nat_var` makes **0 screen→photo** errors at those θ.

- [ ] **Step 1: Add the production-rule report**

In `m_report_separation/1`, immediately after the existing `strong-features AND-rule` block (the `case strong do … end`), add:

```elixir
    production = Enum.filter(stats, &(&1.name in ["palette_ent", "nat_var"]))
    m_rule_report("PRODUCTION rule (palette_ent ∧ nat_var)", rows, production)
```

This reuses `m_rule_report/3` (prints photo→photo recall, photo→screen, and the safety-critical screen→photo count) over just the two shipped features, each at its own Youden θ from the printed stats table.

- [ ] **Step 2: Set up the corpus (network; one-time)**

Run:
```bash
mise exec -- mix autoquality.corpus
mise exec -- mix autoquality.corpus.capture
```
Expected: both complete; `mix autoquality.corpus --path` prints a populated corpus dir.

- [ ] **Step 3: Run Part M and capture the numbers**

Run:
```bash
mise exec -- mix autoquality.bench --part m --downsample 512 --corpus "$(mise exec -- mix autoquality.corpus --path)"
```
Expected (≈18 min): the `(a) class separation` table prints `θ` for `palette_ent` and `nat_var`; the new `PRODUCTION rule (palette_ent ∧ nat_var)` line prints `screen→photo 0`; the `(b)` residual section prints `screen avif … p90_hit ≈ 6`. 

**Record** in this task's commit message: `θ_palette = <value>`, `θ_nat = <value>` (the printed Youden θ for each), `avif_graphic_offset = <round(p90_hit)>` (≈ 6.0). Confirm the production-rule line shows **0** screen→photo.

If it shows 1, raise whichever θ is closer to its overlap and **re-run the bench** so the `PRODUCTION rule` line is re-printed for the *adjusted* pair — the frozen constants are the hand-adjusted ones, so the 0-screen→photo evidence must be for those exact values, not the original Youden pair. Repeat until the re-printed line reads 0, and paste that final line into the commit body. The thresholds hardcoded in Task 2 must be exactly the values whose `PRODUCTION rule` line you pasted.

- [ ] **Step 4: Commit (bench change only)**

```bash
git add test/support/mix/tasks/autoquality.bench.ex
git commit -m "bench(autoquality): report the shipped palette_ent ∧ nat_var rule (#380)

Pinned constants from this run (downsample 512):
θ_palette=<value> θ_nat=<value> avif×graphic offset=<value>; screen→photo=0"
```

> These three values are referenced below as `@palette_photo_threshold`, `@nat_var_photo_threshold`, and the `{:avif, :graphic} => <offset>` table entry. Substitute the recorded numbers wherever the plan shows them; the example values below (`0.62`, `0.22`, `6.0`) are placeholders for the bench-pinned ones.

---

## Task 2: `ContentClassifier` module

**Files:**
- Create: `lib/image_pipe/output/content_classifier.ex`
- Test: `test/image_pipe/output/content_classifier_test.exs`

The classifier downsamples to 512 px long-edge, grayscales, computes `palette_ent` (luminance-hist entropy ÷ 8) and `nat_var` (mid-band gradient fraction), and applies the AND-rule with the safe `:graphic` fallback. Ported from the bench `m_features/2` (constants `@m_flat_thresh 8.0`, `@m_hard_thresh 64.0`, Sobel kernels `@m_k0`/`@m_k90`). Only `palette_ent` + `nat_var` are needed (the dropped features `axis_align`/`hard_edge` and kernels `k45`/`k135` are not ported).

- [ ] **Step 1: Write the failing test**

```elixir
defmodule ImagePipe.Output.ContentClassifierTest do
  use ExUnit.Case, async: true

  alias ImagePipe.Output.ContentClassifier
  alias Vix.Vips.Operation

  # A smooth high-frequency continuous-tone field (zone plate): many luminance
  # values (high palette entropy) + abundant mid-band gradient (high nat_var) →
  # :photo. (Used elsewhere in the suite as the continuous-tone surrogate.)
  defp photo_image do
    {:ok, ramp} = Operation.zone(512, 512)
    {:ok, scaled} = Operation.linear(ramp, [127.5], [127.5])
    {:ok, uchar} = Operation.cast(scaled, :VIPS_FORMAT_UCHAR)
    {:ok, gray} = Operation.copy(uchar, interpretation: :VIPS_INTERPRETATION_B_W)
    {:ok, rgb} = Operation.bandjoin([gray, gray, gray])
    {:ok, srgb} = Operation.copy(rgb, interpretation: :VIPS_INTERPRETATION_sRGB)
    srgb
  end

  # A hard-edged two-tone field (line-art surrogate): a white canvas overlaid with
  # a fine black line grid → two luminance values (low palette entropy) + all-hard
  # edges (near-zero mid-band) → :graphic. Built with Image.Draw, not Operation.grid.
  defp graphic_image do
    side = 512
    base = Image.new!(side, side, color: :white)

    drawn =
      Enum.reduce(0..(side - 1)//8, base, fn x, acc ->
        acc
        |> Image.Draw.rect!(x, 0, 1, side, color: :black)
        |> Image.Draw.rect!(0, x, side, 1, color: :black)
      end)

    Image.to_colorspace!(drawn, :srgb)
  end

  test "classifies a continuous-tone field as :photo" do
    assert {:photo, %{palette_ent: pe, nat_var: nv}} = ContentClassifier.classify(photo_image())
    assert is_float(pe) and is_float(nv)
  end

  test "classifies a hard-edged two-tone field as :graphic" do
    assert {:graphic, _features} = ContentClassifier.classify(graphic_image())
  end

  test "falls back to :graphic on a degenerate 1x1 input (no raise)" do
    {:ok, tiny} = Operation.black(1, 1)
    {:ok, srgb} = Operation.copy(tiny, interpretation: :VIPS_INTERPRETATION_sRGB)
    assert {:graphic, _features} = ContentClassifier.classify(srgb)
  end
end
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `mise exec -- mix test test/image_pipe/output/content_classifier_test.exs`
Expected: FAIL — `ImagePipe.Output.ContentClassifier` is undefined.

- [ ] **Step 3: Implement the classifier**

```elixir
defmodule ImagePipe.Output.ContentClassifier do
  @moduledoc """
  Cheap content classifier for the autoquality crop-offset policy.

  Returns `:photo` (continuous-tone photographic content) or `:graphic`
  (discrete-tone synthetic content: screenshots, UI, text, charts, line art).
  Derived entirely from runtime image inspection on a 512 px downsample, like
  EXIF auto-orient and input color management — not a `Plan.Operation`.

  `:graphic` is the **safe fallback**: misclassification is asymmetric (a photo
  read as graphic only inflates a file slightly; a graphic read as photo ships
  visible text/edge damage at the lean offset), so any internal libvips error
  returns `:graphic` rather than failing the request. The graphic→photo error is
  the one that must stay at zero (validated on the labeled cohort by
  `mix autoquality.bench --part m`).
  """

  alias Vix.Vips.Image, as: VixImage
  alias Vix.Vips.Operation

  @type class :: :photo | :graphic
  @type features :: %{palette_ent: float(), nat_var: float()}

  # 512 px long-edge downsample: separation is near-invariant 256→1024 px
  # (palette_ent is a histogram measure) and screen→photo stays 0 at every size,
  # so 512 buys ~all the accuracy at ~60% the cost (bench Part M).
  @downsample 512

  # Gradient-magnitude thresholds (bench Part M): below @flat = flat fill, above
  # @hard = hard edge; nat_var is the mid-band fraction between them.
  @flat_thresh 8.0
  @hard_thresh 64.0

  # Sobel kernels (horizontal / vertical).
  @k0 [[1.0, 0.0, -1.0], [2.0, 0.0, -2.0], [1.0, 0.0, -1.0]]
  @k90 [[1.0, 2.0, 1.0], [0.0, 0.0, 0.0], [-1.0, -2.0, -1.0]]

  # Photo-side Youden thresholds, pinned by `mix autoquality.bench --part m`
  # (Task 1). Photos read HIGH on both features (cohort medians palette_ent
  # 0.909/0.393, nat_var 0.411/0.110); :photo requires BOTH to clear their
  # threshold, else the safe :graphic fallback.
  @palette_photo_threshold 0.62
  @nat_var_photo_threshold 0.22

  @doc """
  Classify a finalized image. Never raises; any libvips failure → `:graphic`.
  """
  @spec classify(VixImage.t()) :: {class(), features()}
  def classify(%VixImage{} = image) do
    case features(image) do
      {:ok, %{palette_ent: pe, nat_var: nv} = feats} ->
        class =
          if pe >= @palette_photo_threshold and nv >= @nat_var_photo_threshold,
            do: :photo,
            else: :graphic

        {class, feats}

      :error ->
        {:graphic, %{palette_ent: 0.0, nat_var: 0.0}}
    end
  end

  defp features(image) do
    with {:ok, feats} <- extract(image) do
      {:ok, feats}
    end
  rescue
    _ -> :error
  catch
    _, _ -> :error
  end

  defp extract(image) do
    scale = min(1.0, @downsample / max(VixImage.width(image), VixImage.height(image)))

    with {:ok, small} <- Operation.resize(image, scale),
         {:ok, g8lazy} <- Operation.colourspace(small, :VIPS_INTERPRETATION_B_W),
         # Pull the downsample+grayscale into RAM once so the convolutions and the
         # histogram read the ~256 KB buffer instead of re-evaluating the resize.
         {:ok, g8} <- VixImage.copy_memory(g8lazy),
         {:ok, gf} <- Operation.cast(g8, :VIPS_FORMAT_FLOAT),
         {:ok, c0} <- conv(gf, @k0),
         {:ok, c90} <- conv(gf, @k90),
         {:ok, mag} <- gradient_magnitude(c0, c90),
         {:ok, flat} <- frac(mag, :VIPS_OPERATION_RELATIONAL_LESS, @flat_thresh),
         {:ok, hard} <- frac(mag, :VIPS_OPERATION_RELATIONAL_MORE, @hard_thresh),
         {:ok, hist} <- Operation.hist_find(g8),
         {:ok, ent} <- Operation.hist_entropy(hist) do
      {:ok, %{palette_ent: ent / 8.0, nat_var: max(0.0, 1.0 - flat - hard)}}
    end
  end

  defp conv(gf, kernel) do
    with {:ok, mask} <- VixImage.new_from_list(kernel), do: Operation.conv(gf, mask)
  end

  defp gradient_magnitude(c0, c90) do
    with {:ok, sq0} <- Operation.multiply(c0, c0),
         {:ok, sq90} <- Operation.multiply(c90, c90),
         {:ok, sumsq} <- Operation.add(sq0, sq90) do
      Operation.math2_const(sumsq, :VIPS_OPERATION_MATH2_POW, [0.5])
    end
  end

  # Fraction of pixels passing a relational test on the gradient magnitude. The
  # boolean image is 255 where true, so avg / 255 is the fraction.
  defp frac(mag, op, threshold) do
    with {:ok, bool} <- Operation.relational_const(mag, op, [threshold]),
         {:ok, avg} <- Operation.avg(bool) do
      {:ok, avg / 255.0}
    end
  end
end
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `mise exec -- mix test test/image_pipe/output/content_classifier_test.exs`
Expected: PASS (3 tests). If `:photo`/`:graphic` mismatch, the example fixtures are robust to any sane θ — recheck the pinned thresholds from Task 1.

- [ ] **Step 5: Commit**

```bash
git add lib/image_pipe/output/content_classifier.ex test/image_pipe/output/content_classifier_test.exs
git commit -m "feat(autoquality): add ContentClassifier (:photo/:graphic) (#380)"
```

---

## Task 3: `Plan.Output.quality_search_offsets` field + default

**Files:**
- Modify: `lib/image_pipe/plan/output.ex`
- Test: `test/image_pipe/plan/output_test.exs` (create if absent)

- [ ] **Step 1: Write the failing test**

Create/extend `test/image_pipe/plan/output_test.exs`:

```elixir
defmodule ImagePipe.Plan.OutputTest do
  use ExUnit.Case, async: true
  alias ImagePipe.Plan.Output

  test "default quality_search_offsets carries the 2.4 default and the avif×graphic override" do
    %Output{quality_search_offsets: offsets} = %Output{mode: :automatic}
    assert offsets.default == 2.4
    assert Map.fetch!(offsets.overrides, {:avif, :graphic}) == 6.0
  end

  test "offset_for/3 falls back to the default for unlisted cells" do
    offsets = Output.default_quality_search_offsets()
    assert Output.offset_for(offsets, :avif, :graphic) == 6.0
    assert Output.offset_for(offsets, :avif, :photo) == 2.4
    assert Output.offset_for(offsets, :jpeg, :graphic) == 2.4
    assert Output.offset_for(offsets, :webp, :photo) == 2.4
  end
end
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `mise exec -- mix test test/image_pipe/plan/output_test.exs`
Expected: FAIL — `quality_search_offsets`/`default_quality_search_offsets`/`offset_for` undefined.

- [ ] **Step 3: Implement the field, default, and lookup**

In `lib/image_pipe/plan/output.ex`, add to the `defstruct` (after `max_bytes: nil`):

```elixir
            max_bytes: nil,
            quality_search_offsets: %{default: 2.4, overrides: %{{:avif, :graphic} => 6.0}}
```

Add to the `@type t` map (after `max_bytes:`):

```elixir
          max_bytes: nil | pos_integer(),
          quality_search_offsets: quality_search_offsets()
```

Add the type + helpers (the `@moduledoc` should gain a sentence noting `quality_search_offsets` is the confirm-skipped crop-estimate correction per `{format, content-class}`, a defaulted seam no parser overrides today — like `flatten_background`):

```elixir
  @type content_class :: :photo | :graphic
  @type quality_search_offsets :: %{
          default: number(),
          overrides: %{optional({format(), content_class()}) => number()}
        }

  @doc "The built-in confirm-skipped crop-offset policy (bench Part M / #380)."
  @spec default_quality_search_offsets() :: quality_search_offsets()
  def default_quality_search_offsets,
    do: %{default: 2.4, overrides: %{{:avif, :graphic} => 6.0}}

  @doc "Resolve the offset for a `{format, content_class}` cell, defaulting per policy."
  @spec offset_for(quality_search_offsets(), format(), content_class()) :: number()
  def offset_for(%{overrides: overrides, default: default}, format, class),
    do: Map.get(overrides, {format, class}, default)
```

> Substitute the Task 1 bench-pinned offset for `6.0` if it rounded differently.

- [ ] **Step 4: Run the test to verify it passes**

Run: `mise exec -- mix test test/image_pipe/plan/output_test.exs`
Expected: PASS (2 tests).

- [ ] **Step 5: Commit**

```bash
git add lib/image_pipe/plan/output.ex test/image_pipe/plan/output_test.exs
git commit -m "feat(autoquality): add Plan.Output.quality_search_offsets policy (#380)"
```

---

## Task 4: Resolve the table per format into `ResolvedQualitySearch`

**Files:**
- Modify: `lib/image_pipe/output/resolved_quality_search.ex`
- Modify: `lib/image_pipe/output/policy.ex` (struct fields + `from_output_plan/3` both clauses + `resolve_search/2`, near lines 24, 60, 76, 177)
- Test: `test/image_pipe/output_policy_test.exs`

- [ ] **Step 1: Write the failing test**

Add to `test/image_pipe/output_policy_test.exs` (follow the file's existing setup for building a `%Output.Policy{}` / `Plan.Output` + calling `resolve/2`; mirror an existing `quality_search` resolution test):

```elixir
  test "resolves quality_search_offsets to the per-class map for the negotiated format" do
    output = %ImagePipe.Plan.Output{
      mode: {:explicit, :avif},
      quality_search: %ImagePipe.Plan.Output.QualitySearch{
        objective: :ssim2,
        target: 78,
        min_quality: 70,
        max_quality: 80,
        allowed_error: 1.0,
        max_resolution: 0,
        format_min: %{},
        format_max: %{}
      }
    }

    policy = ImagePipe.Output.Policy.from_output_plan(%Plug.Conn{}, output, [])
    {:ok, resolved} = ImagePipe.Output.Policy.resolve(policy, :avif)

    # avif → graphic draws the big offset; photo keeps the lean default.
    assert resolved.quality_search.quality_search_offsets == %{photo: 2.4, graphic: 6.0}
  end

  test "a non-avif format keeps the lean default for both classes" do
    output = %ImagePipe.Plan.Output{
      mode: {:explicit, :jpeg},
      quality_search: %ImagePipe.Plan.Output.QualitySearch{
        objective: :ssim2,
        target: 78,
        min_quality: 70,
        max_quality: 80,
        allowed_error: 1.0,
        max_resolution: 0,
        format_min: %{},
        format_max: %{}
      }
    }

    policy = ImagePipe.Output.Policy.from_output_plan(%Plug.Conn{}, output, [])
    {:ok, resolved} = ImagePipe.Output.Policy.resolve(policy, :jpeg)
    assert resolved.quality_search.quality_search_offsets == %{photo: 2.4, graphic: 2.4}
  end
```

- [ ] **Step 2: Run to verify it fails**

Run: `mise exec -- mix test test/image_pipe/output_policy_test.exs`
Expected: FAIL — `quality_search_offsets` not a key of `ResolvedQualitySearch`.

- [ ] **Step 3: Add the resolved field**

In `lib/image_pipe/output/resolved_quality_search.ex`, extend the struct + type:

```elixir
  @enforce_keys [:objective, :target, :min_quality, :max_quality]
  defstruct @enforce_keys ++ [allowed_error: 0, max_resolution: 0, quality_search_offsets: %{}]

  @type content_class :: :photo | :graphic
  @type t :: %__MODULE__{
          objective: :size | :ssim2,
          target: number(),
          min_quality: 1..100,
          max_quality: 1..100,
          allowed_error: number(),
          max_resolution: non_neg_integer(),
          quality_search_offsets: %{optional(content_class()) => number()}
        }
```

Update the `@moduledoc` to note `quality_search_offsets` is the per-class confirm-skipped crop offset for the negotiated format, consumed by `EncodeSearch`. Note the default `%{}` is the resolved shape only for `:size`/`:none` (which never crop-score); the `:ssim2` resolver always populates both `:photo` and `:graphic` keys, so the `:crop` path's `Map.fetch!` trusts a fully-populated map.

- [ ] **Step 4: Carry the field through the policy struct**

In `lib/image_pipe/output/policy.ex`:

In the `defstruct` defaults (line ~24/25), add `quality_search_offsets` defaulting to the Plan.Output default:

```elixir
  defstruct @enforce_keys ++
              [
                flatten_background: Color.white(),
                quality_search: :none,
                max_bytes: nil,
                quality_search_offsets: Output.default_quality_search_offsets()
              ]
```

Add to the `@type t` map: `quality_search_offsets: Output.quality_search_offsets()`.

In **both** `from_output_plan/3` clauses, add to the struct literal (next to `quality_search: output.quality_search`):

```elixir
      quality_search: output.quality_search,
      quality_search_offsets: output.quality_search_offsets,
```

- [ ] **Step 5: Collapse the table in `resolve_search/2`**

Replace the `%Output.QualitySearch{}` clause of `resolve_search/2` so it takes the whole policy and stamps the per-class map for the format:

```elixir
  defp resolve_search(%__MODULE__{quality_search: :none}, _format), do: :none

  defp resolve_search(
         %__MODULE__{quality_search: %Output.QualitySearch{} = search} = policy,
         format
       ) do
    %ResolvedQualitySearch{
      objective: search.objective,
      target: search.target,
      min_quality: Map.get(search.format_min, format, search.min_quality),
      max_quality: Map.get(search.format_max, format, search.max_quality),
      allowed_error: search.allowed_error,
      max_resolution: search.max_resolution,
      quality_search_offsets: %{
        photo: Output.offset_for(policy.quality_search_offsets, format, :photo),
        graphic: Output.offset_for(policy.quality_search_offsets, format, :graphic)
      }
    }
  end
```

(The call site `resolve_search(policy, format)` already passes the whole policy — confirm line ~170 reads `quality_search: resolve_search(policy, format)`.)

- [ ] **Step 6: Run to verify it passes**

Run: `mise exec -- mix test test/image_pipe/output_policy_test.exs`
Expected: PASS.

- [ ] **Step 7: Commit**

```bash
git add lib/image_pipe/output/resolved_quality_search.ex lib/image_pipe/output/policy.ex test/image_pipe/output_policy_test.exs
git commit -m "feat(autoquality): resolve quality_search_offsets per negotiated format (#380)"
```

---

## Task 5: Apply the per-class offset in `EncodeSearch` (remove the constant)

**Files:**
- Modify: `lib/image_pipe/output/encode_search.ex` (the `@crop_confirm_skipped_offset` constant ~line 44-67; the `:crop` `score_opts/4` clause ~line 786-790; `crop_estimate/4` ~line 814-823)
- Modify: `test/image_pipe/output/encoder_crop_scoring_test.exs`

The pure `search/3` core is unchanged — the offset is baked into the crop closure by `run/3`, exactly like the reference build. The classify telemetry span is added here in Task 6; this task does the offset plumbing first and keeps tests green.

- [ ] **Step 1: Preserve the existing crop test by neutralizing the offset**

Read `test/image_pipe/output/encoder_crop_scoring_test.exs` first. Its full-vs-crop test asserts `abs(crop.quality - full.quality) <= 4` (~line 99) and the by-construction `crop.score >= band` (~line 102) under the *old* fixed 2.4. This task is a pure refactor (global constant → per-class map lookup) that must keep that test green; the *new* per-class behavior is proven in Task 6 via telemetry. Preserve the existing test's intent by adding a content-neutral offset map to its `%RQS{}` literal (~line 49), so classification cannot change its result:

```elixir
        quality_search: %RQS{
          objective: :ssim2,
          # ... existing fields (target/min/max/allowed_error/max_resolution) ...
          quality_search_offsets: %{photo: 2.4, graphic: 2.4}
        }
```

Both classes subtract 2.4 (the prior global value), so the `<=4` bound and the by-construction assertion hold regardless of how the test image classifies. Do **not** widen the bound; do **not** use this test to prove the new offset.

- [ ] **Step 2: Run to verify the refactor target is reachable**

Run: `mise exec -- mix test test/image_pipe/output/encoder_crop_scoring_test.exs`
Expected: with Task 4 done, the `%RQS{quality_search_offsets: …}` literal compiles; the test currently **passes** (the live `:crop` path still subtracts the hardcoded 2.4, matching the neutral map). This step has no fail-first — it is a behavior-preserving refactor; the new behavior's fail-first lives in Task 6. Proceed to wire the offset so the constant is gone.

- [ ] **Step 3: Remove the constant; thread the per-class offset**

In `lib/image_pipe/output/encode_search.ex`:

Delete the `@crop_confirm_skipped_offset 2.4` attribute and its long explanatory comment block (lines ~44-67). Its 2.4 now lives as the `Plan.Output` policy default.

Replace the `:crop` clause of `score_opts/4`:

```elixir
  defp score_opts(image, %Resolved{quality_search: %RQS{objective: :ssim2} = rqs}, :crop, t) do
    tiles = CropScore.tile_count(Image.width(image), Image.height(image))
    {class, _features} = ContentClassifier.classify(image)
    # `Output.Policy.resolve_search/2` always stamps both :photo and :graphic keys
    # for an :ssim2 search (the only objective that reaches the :crop path), so
    # `fetch!` trusts the in-repo producer — a missing key is a resolver bug, not a
    # runtime input. (The `RQS` default `%{}` only occurs for :size/:none, which
    # never crop-score.)
    offset = Map.fetch!(rqs.quality_search_offsets, class)
    crop = fn bytes -> crop_estimate(image, bytes, tiles, offset, t) end
    {:ok, [score_fun: crop, scorer_tiles: tiles]}
  end
```

Update `crop_estimate/4` → `crop_estimate/5` to take the offset:

```elixir
  defp crop_estimate(base, bytes, tiles, offset, telemetry_opts) do
    candidate = decode_leg(bytes, telemetry_opts)

    metric_leg(telemetry_opts, tiles, fn ->
      case CropScore.p10(base, candidate) do
        {:ok, p10} -> p10 - offset
        {:error, reason} -> throw({:image_pipe_score_error, reason})
      end
    end)
  end
```

Add the alias near the top (with the other `alias ImagePipe.Output.*`):

```elixir
  alias ImagePipe.Output.ContentClassifier
```

- [ ] **Step 4: Run the focused tests**

Run: `mise exec -- mix test test/image_pipe/output/encoder_crop_scoring_test.exs test/image_pipe/output/encode_search_test.exs`
Expected: PASS. (`encode_search_test.exs` drives the pure `search/3` with injected closures and the `confirm_fun` baseline — unaffected by the offset change.)

- [ ] **Step 5: Commit**

```bash
git add lib/image_pipe/output/encode_search.ex test/image_pipe/output/encoder_crop_scoring_test.exs
git commit -m "feat(autoquality): apply per-class crop offset, drop global constant (#380)"
```

---

## Task 6: Classify telemetry span + Logger + Capture + docs

**Files:**
- Modify: `lib/image_pipe/output/encode_search.ex` (wrap the classify in a span in the `:crop` `score_opts` clause)
- Modify: `lib/image_pipe/telemetry/logger.ex` (`@group_span_events` line ~17-18; add a `message/3` clause)
- Modify: `lib/image_pipe/telemetry/trace/capture.ex` (`@span_stages` line ~13-14; `@safe_keys` line ~65)
- Modify: `docs/telemetry.md`
- Test: `test/image_pipe/output/encode_search_telemetry_test.exs`

- [ ] **Step 1: Write the failing per-class telemetry test**

This is the **fail-first proof of the new behavior**: the right offset is selected per content class. It's deterministic (depends only on classification, which is robust to the exact thresholds) and fails before Step 3 (no span emitted, offset still hardcoded). Add to `test/image_pipe/output/encode_search_telemetry_test.exs` (mirror the file's existing crop-path `%Resolved{}`/`telemetry_prefix` setup; the helper builds a >6 MP image and an `:ssim2` resolved search):

```elixir
  # >6 MP hard-edged two-tone field (dense-graphic surrogate): a white canvas with
  # a fine grid of black lines → two luminance values (low palette entropy) +
  # all-hard edges (low mid-band) → classifies :graphic. Built with Image.Draw (no
  # Operation.grid). >6 MP so the crop scorer fires.
  defp large_graphic_image do
    side = 2800
    base = Image.new!(side, side, color: :white)

    drawn =
      Enum.reduce(0..(side - 1)//16, base, fn x, acc ->
        acc
        |> Image.Draw.rect!(x, 0, 1, side, color: :black)
        |> Image.Draw.rect!(0, x, side, 1, color: :black)
      end)

    Image.to_colorspace!(drawn, :srgb)
  end

  # A smooth continuous-tone field → high palette entropy + mid-band variation →
  # classifies :photo. A zone plate (used elsewhere in the suite) works.
  defp large_photo_image do
    side = 2800
    {:ok, z} = Vix.Vips.Operation.zone(side, side)
    {:ok, scaled} = Vix.Vips.Operation.linear(z, [127.5], [127.5])
    {:ok, uchar} = Vix.Vips.Operation.cast(scaled, :VIPS_FORMAT_UCHAR)
    {:ok, gray} = Vix.Vips.Operation.copy(uchar, interpretation: :VIPS_INTERPRETATION_B_W)
    {:ok, rgb} = Vix.Vips.Operation.bandjoin([gray, gray, gray])
    {:ok, srgb} = Vix.Vips.Operation.copy(rgb, interpretation: :VIPS_INTERPRETATION_sRGB)
    srgb
  end

  defp resolved_ssim2_avif do
    %ImagePipe.Output.Resolved{
      format: :avif,
      quality: :default,
      response_headers: [],
      strip_metadata: true,
      keep_copyright: true,
      color_profile: :strip,
      quality_search: %ImagePipe.Output.ResolvedQualitySearch{
        objective: :ssim2,
        target: 88,
        min_quality: 40,
        max_quality: 95,
        allowed_error: 1.0,
        max_resolution: 0,
        quality_search_offsets: %{photo: 2.4, graphic: 6.0}
      }
    }
  end

  defp attach_classify(prefix) do
    handler = {__MODULE__, make_ref()}
    :telemetry.attach(handler, prefix ++ [:encode, :classify, :stop],
      fn _e, _m, meta, pid -> send(pid, {:classify, meta}) end, self())
    on_exit(fn -> :telemetry.detach(handler) end)
  end

  test "classify span selects the avif×graphic offset (6.0) for graphic content" do
    prefix = [:ip_classify_graphic_test]
    attach_classify(prefix)

    EncodeSearch.run(large_graphic_image(), resolved_ssim2_avif(), telemetry_opts: [prefix: prefix])

    assert_receive {:classify, meta}
    assert meta.content_class == :graphic
    assert meta.applied_offset == 6.0
    assert is_float(meta.palette_ent) and is_float(meta.nat_var)
  end

  test "classify span keeps the lean offset (2.4) for photo content" do
    prefix = [:ip_classify_photo_test]
    attach_classify(prefix)

    EncodeSearch.run(large_photo_image(), resolved_ssim2_avif(), telemetry_opts: [prefix: prefix])

    assert_receive {:classify, meta}
    assert meta.content_class == :photo
    assert meta.applied_offset == 2.4
  end
```

> Confirm the two fixtures classify as intended during implementation (the tests assert it). If `large_graphic_image/0` reads `:photo` or vice-versa, adjust the fixture (line density/contrast) — the synthetic must be unambiguous. Confirm `Image.Draw.rect!`/`Image.to_colorspace!` against the installed `image` lib API.

- [ ] **Step 2: Run to verify it fails**

Run: `mise exec -- mix test test/image_pipe/output/encode_search_telemetry_test.exs`
Expected: FAIL — no `[:encode, :classify]` event emitted yet (the `assert_receive` times out).

- [ ] **Step 3: Emit the span from `score_opts(:crop)`**

In `lib/image_pipe/output/encode_search.ex`, wrap the classification in a span:

```elixir
  defp score_opts(image, %Resolved{quality_search: %RQS{objective: :ssim2} = rqs}, :crop, t) do
    tiles = CropScore.tile_count(Image.width(image), Image.height(image))

    {class, offset} =
      Telemetry.span(t, [:encode, :classify], %{}, fn ->
        {class, features} = ContentClassifier.classify(image)
        offset = Map.fetch!(rqs.quality_search_offsets, class)

        {{class, offset},
         %{
           result: :ok,
           content_class: class,
           applied_offset: offset,
           palette_ent: features.palette_ent,
           nat_var: features.nat_var
         }}
      end)

    crop = fn bytes -> crop_estimate(image, bytes, tiles, offset, t) end
    {:ok, [score_fun: crop, scorer_tiles: tiles]}
  end
```

(Confirm `Telemetry.span/4` arity against the existing calls in this file, e.g. `encode_leg/4`.)

- [ ] **Step 4: Subscribe + render in the Logger**

In `lib/image_pipe/telemetry/logger.ex`, add `[:encode, :classify]` to the `request` list in `@group_span_events` (after `[:encode, :search, :probe]`):

```elixir
      [:encode, :search, :probe],
      [:encode, :classify],
```

Add a `message/3` clause (before the generic fallback) that surfaces class + offset and still carries the outcome:

```elixir
  defp message([:encode, :classify, :stop], _measurements, meta) do
    "encode.classify #{meta.content_class} offset=#{meta.applied_offset} #{outcome(meta)}"
  end
```

(Match the exact `message/3` signature/`outcome/1` helper used by the file's other clauses.)

**Level note:** the classify stop meta carries `result: :ok` and **no `:outcome` key**, so it logs at the base level (`:info`). Do not add an `:outcome` key — `level_for([:encode, :search | _])` escalates on `outcome: :best_effort`, but `[:encode, :classify]` does not match that clause anyway (it is `[:encode, :classify | _]`), so the classify span stays at base level regardless. Keep it that way.

- [ ] **Step 5: Trace + allowlist in Capture**

In `lib/image_pipe/telemetry/trace/capture.ex`, add the stage to `@span_stages` (after `[:encode, :search]`):

```elixir
    [:encode, :search],
    [:encode, :classify],
```

Add the new metadata keys to `@safe_keys` (next to `:scorer`, `:tiles_scored`):

```elixir
    :content_class,
    :applied_offset,
    :palette_ent,
    :nat_var,
```

- [ ] **Step 6: Add a Logger coverage assertion**

In `test/image_pipe/telemetry/logger_test.exs`, add an assertion that the classify line renders the class + offset (follow the file's existing capture-log pattern), and that it logs at `:info` (not `:warning`) — pinning the base-level behavior from Step 4's level note.

- [ ] **Step 7: Update `docs/telemetry.md`**

Document `[:encode, :classify]` (start/stop; the `:exception` leg is structurally unreachable — the classifier is total and never raises) on both the Logger and OTel surfaces, listing the metadata keys `content_class`, `applied_offset`, `palette_ent`, `nat_var`, and noting all are product-neutral/non-sensitive.

- [ ] **Step 8: Run the telemetry + logger + capture tests**

Run: `mise exec -- mix test test/image_pipe/output/encode_search_telemetry_test.exs test/image_pipe/telemetry/logger_test.exs test/image_pipe/telemetry/trace/capture_test.exs`
Expected: PASS.

- [ ] **Step 9: Commit**

```bash
git add lib/image_pipe/output/encode_search.ex lib/image_pipe/telemetry/logger.ex lib/image_pipe/telemetry/trace/capture.ex docs/telemetry.md test/image_pipe/output/encode_search_telemetry_test.exs test/image_pipe/telemetry/logger_test.exs
git commit -m "feat(autoquality): classify telemetry span on Logger + OTel surfaces (#380)"
```

---

## Task 7: Request-boundary contract test

**Files:**
- Modify: `test/image_pipe/imgproxy_wire_conformance_test.exs` (add a `:graphic` large origin near `LargeSsim2OriginImage` ~line 73; add the tests near the #369 crop-verdict test ~line 678)

**What this proves (and what it deliberately does NOT).** This test proves the user-visible *contract*: a large graphic AVIF goes through `ImagePipe.call/2` end-to-end, classifies `:graphic`, and the `{avif, :graphic}` offset (6.0) is selected and applied on the crop path — while a continuous-tone AVIF keeps the lean 2.4. It does **NOT** assert "achieves target band": on the crop path `final_score` is the *offset-corrected estimate*, which the objective walk lands in-band **by construction at any offset** (see `encoder_crop_scoring_test.exs:100-102`), so such an assertion is vacuous — it passes identically at 2.4 and 6.0. The empirical claim that 6.0 is the *right magnitude* for real dense text is owned by `mix autoquality.bench --part m` (Task 1), not reproducible on the network-free default lane. The wire test's job (per the repo's "representative public contracts, not exhaustive" test guideline) is the plumbing + per-class selection, end-to-end.

- [ ] **Step 1: Add a deterministic large `:graphic` origin**

After `LargeSsim2OriginImage`, add an origin serving a >6 MP white field overlaid with a fine grid of black lines (a dense line-art surrogate the classifier reads as `:graphic`), as JPEG to stay under `max_body_bytes`. Built with `Image.Draw` (the file already uses `Image.Draw.rect!`), **not** `Operation.grid` (which tiles a tall input into a grid layout — it does not replicate a small tile):

```elixir
  # A >6 MP white field overlaid with a fine black line grid: a dense line-art /
  # text surrogate the classifier reads as :graphic (two luminance values → low
  # palette entropy; all-hard edges → low mid-band gradient). Above the crossover
  # this is the cell whose crop estimate overshoots full-frame, so {avif,:graphic}
  # draws the big offset. 2800² ≈ 7.84 MP. Served JPEG to stay under the default
  # 10 MB source max_body_bytes.
  defmodule LargeGraphicOriginImage do
    @moduledoc false

    def call(conn, _opts) do
      side = 2800
      base = Image.new!(side, side, color: :white)

      drawn =
        Enum.reduce(0..(side - 1)//16, base, fn x, acc ->
          acc
          |> Image.Draw.rect!(x, 0, 1, side, color: :black)
          |> Image.Draw.rect!(0, x, side, 1, color: :black)
        end)

      body = drawn |> Image.to_colorspace!(:srgb) |> Image.write!(:memory, suffix: ".jpg")

      conn
      |> Plug.Conn.put_resp_content_type("image/jpeg")
      |> Plug.Conn.send_resp(200, body)
    end
  end
```

> The served content must (a) decode ≥ 6 MP and (b) classify `:graphic`. The Step 2 test asserts (b) directly (telemetry `content_class: :graphic`), so a miss fails loudly — but verify with `ContentClassifier.classify/1` in IEx during implementation and raise the line density/contrast if it reads `:photo`. Confirm `Image.Draw.rect!`/`Image.to_colorspace!` against the installed `image` lib API.

- [ ] **Step 2: Write the contract test (graphic → 6.0)**

Mirror the existing #369 crop-verdict test for request construction (explicit AVIF, autoquality `:ssim2`, **no resize** so the full >6 MP frame is finalized and the crop scorer fires), against `LargeGraphicOriginImage`. Use a unique `telemetry_prefix`; attach to `prefix ++ [:encode, :classify, :stop]` and `prefix ++ [:encode, :search, :stop]`. Read `target`/`allowed_error` from the request the test itself built (they are **not** in the search `:stop` meta — that meta carries `chosen_quality`, `scorer`, `final_score`, etc., per `search_stop_meta/2`).

```elixir
  test "large graphic AVIF above the crossover selects the {avif, graphic} offset (#380)" do
    prefix = [:ip_aq_graphic_offset]
    attach_meta(prefix ++ [:encode, :classify, :stop], :classify)
    attach_meta(prefix ++ [:encode, :search, :stop], :search)

    conn = call_imgproxy(LargeGraphicOriginImage, "<avif autoquality ssim2 path, no resize>",
                          telemetry_prefix: prefix)

    assert conn.status == 200
    assert get_resp_header(conn, "content-type") == ["image/avif"]

    # Classification + per-class offset selection, end-to-end:
    assert_receive {:classify, %{content_class: :graphic, applied_offset: 6.0}}
    # Crop path was taken (the regime the offset governs):
    assert_receive {:search, %{scorer: :crop}}
  end
```

(`attach_meta/2` and `call_imgproxy/3` stand for the file's existing telemetry-attach and request helpers — reuse them, do not invent new ones; read the file first.)

- [ ] **Step 3: Add the no-inflation companion (photo → 2.4)**

Either extend the existing #369 zone-plate test (continuous-tone → `:photo`) or add a sibling against `LargeSsim2OriginImage`, asserting the lean offset is retained for the covered cells:

```elixir
    assert_receive {:classify, %{content_class: :photo, applied_offset: 2.4}}
```

This is the "no byte inflation vs today" guard: avif×photo (and jpeg/webp) keep the prior 2.4.

- [ ] **Step 4: Run the wire tests**

Run: `mise exec -- mix test test/image_pipe/imgproxy_wire_conformance_test.exs`
Expected: PASS. If `content_class` comes back `:photo` for the graphic origin (or vice-versa), fix the origin generator (Step 1) until classification is unambiguous.

- [ ] **Step 5: Commit**

```bash
git add test/image_pipe/imgproxy_wire_conformance_test.exs
git commit -m "test(autoquality): request-boundary contract for {format,class} offset (#380)"
```

---

## Task 8: Full gate + bench re-validation

**Files:** none (verification only)

- [ ] **Step 1: Run the precommit gate**

Run: `mise run precommit`
Expected: `mix format --check-formatted`, `mix compile --warnings-as-errors`, `mix credo --strict`, and `mix test` all pass.

- [ ] **Step 2: Architecture boundary check**

Run: `mise exec -- mix test test/image_pipe/architecture_boundary_test.exs`
Expected: PASS — `ContentClassifier` sits inside `Output.*`; no request/source/response code names it. (No boundary edits expected.)

- [ ] **Step 3: Re-confirm the frozen-constant safety property (environmental)**

Confirm the thresholds hardcoded in `ContentClassifier` (Task 2) are exactly the pair whose `PRODUCTION rule` line read `screen→photo 0` in Task 1's commit body (re-validated there after any hand-adjustment). If they differ, re-run `mise exec -- mix autoquality.bench --part m --downsample 512 --corpus "$(mise exec -- mix autoquality.corpus --path)"` for the hardcoded pair and confirm `screen→photo 0` before shipping.

- [ ] **Step 4: Final review prep**

Confirm the spec's acceptance criteria are all covered:
- No silent under-quality for large AVIF graphic → proven across layers: the per-class
  6.0 offset is selected/applied end-to-end (T6 telemetry + T7 wire contract), the offset
  bites in the correcting direction (search monotonicity, documented), and 6.0 is the
  right magnitude on real dense text (bench, T1). The lane does **not** assert "hits
  target" off the by-construction estimate (would be vacuous).
- avif×photo / jpeg / webp no byte inflation → T7 Step 3 (`applied_offset: 2.4` retained).
- Request-boundary test through `ImagePipe.call/2`, classification confirmed → T7.
- Telemetry surfaces class + offset on both surfaces → T6.

---

## Self-Review Notes

- **Spec coverage:** ContentClassifier (T2 ↔ spec §1), Plan.Output table (T3 ↔ §2), resolution (T4 ↔ §3), EncodeSearch consumption + constant removal (T5 ↔ §4), telemetry both surfaces (T6 ↔ §5), tests incl. acceptance (T2/T4/T6/T7 ↔ §"Testing"), empirical constants (T1 ↔ §"Empirical constants"). WebP cap (#381) correctly excluded.
- **Cache key:** explicitly NOT touched (constant policy, out of key/ETag) — documented in File Structure.
- **Naming consistency:** `quality_search_offsets` (field, all three layers), `offset_for/3`, `default_quality_search_offsets/0`, `:photo`/`:graphic`, `crop_estimate/5`, span `[:encode, :classify]`, meta keys `content_class`/`applied_offset`/`palette_ent`/`nat_var` — used identically across tasks.
- **Empirical placeholders:** the three constants (`@palette_photo_threshold`, `@nat_var_photo_threshold`, avif×graphic offset) are bench-derived in T1; example values (`0.62`/`0.22`/`6.0`) are flagged as substitutable, not invented design gaps.
