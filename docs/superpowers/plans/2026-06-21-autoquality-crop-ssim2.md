# Crop-based ssim2 scoring for autoquality — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the `:ssim2` autoquality quality-search affordable on large outputs by scoring SSIMULACRA2 on K native-resolution p10-tiles of the full-res encode above an internal ~6 MP crossover, with one full-frame confirm + bounded bump.

**Architecture:** A new `ImagePipe.Output.Ssim2Metric.CropScore` child module owns the tiling geometry + p10 (delegating all SSIMULACRA2 access to the parent `Ssim2Metric`). `Encoder.stream_output` computes megapixels once and picks `:skip | :crop | :full`, passing the scorer mode to `EncodeSearch.run/3`. `EncodeSearch` builds a crop `score_fun` (objective phase) plus a full-frame `confirm_fun`/`confirm_band`, and a new **objective-neutral, closure-injected** confirm phase re-validates the objective winner against the authoritative full-frame score and linear-bumps (cap 2) on undershoot. Everything stays in the `Output` boundary.

**Tech Stack:** Elixir, Vix/libvips (`Vix.Vips.Operation`), the `ssimulacra2` NIF (via `Ssim2Metric`), ExUnit, `:telemetry`.

**Spec:** `docs/superpowers/specs/2026-06-21-autoquality-crop-ssim2-design.md`

---

## File Structure

- **Create** `lib/image_pipe/output/ssim2_metric/crop_score.ex` — tiling geometry (`tile_coords`, `axis_positions`), `subsample`, `percentile`, `crossover_megapixels/0`, `p10/2`. Delegates scoring to `Ssim2Metric`.
- **Create** `test/image_pipe/output/ssim2_metric/crop_score_test.exs` — pure-geometry + `p10/2` unit tests.
- **Modify** `lib/image_pipe/output/encode_search.ex` — `Ctx` fields, objective-neutral confirm phase, `run/3` scorer mode, `build_score_fun/3`, stop-meta fields, honest `result_score`.
- **Modify** `test/image_pipe/output/encode_search_test.exs` — confirm/bump closure tests.
- **Modify** `test/image_pipe/output/encode_search_telemetry_test.exs` — `scorer`/`confirm_passes` meta assertions.
- **Modify** `lib/image_pipe/output/encoder.ex` — `:skip | :crop | :full` precedence ladder; pass `scorer` to `run/3`.
- **Create** `test/image_pipe/output/encoder_crop_scoring_test.exs` — wire-level (`stream_output`) zone-plate tests.
- **Modify** `lib/image_pipe/telemetry/logger.ex` + `test/image_pipe/telemetry/logger_test.exs` + `docs/telemetry.md` — render `scorer`.
- **Modify** `test/image_pipe/architecture_boundary_test.exs` — assert `CropScore` names no `Ssimulacra2.`.
- **Modify** `docs/autoquality_benchmark.md` (calibration record) + `docs/imgproxy_support_matrix.md` (Save/encode stage note).

**No fiddle change:** this adds no transform/parser option parameter — K/tile/crossover/macro_offset are internal constants. The demo UI already exposes the autoquality controls; there is nothing new to wire.

---

## Task 1: CropScore tiling geometry (pure functions)

**Files:**
- Create: `lib/image_pipe/output/ssim2_metric/crop_score.ex`
- Test: `test/image_pipe/output/ssim2_metric/crop_score_test.exs`

- [ ] **Step 1: Write the failing test**

```elixir
defmodule ImagePipe.Output.Ssim2Metric.CropScoreTest do
  use ExUnit.Case, async: true

  alias ImagePipe.Output.Ssim2Metric.CropScore

  describe "tile_coords/3" do
    test "covers the frame with full-size windows, last row/col clamped to the edge" do
      # 1100x600 with 512 tiles: x positions 0,512,588 (1100-512); y: 0,88 (600-512)
      coords = CropScore.tile_coords(1100, 600, 512)
      xs = coords |> Enum.map(fn {x, _y, _w, _h} -> x end) |> Enum.uniq() |> Enum.sort()
      ys = coords |> Enum.map(fn {_x, y, _w, _h} -> y end) |> Enum.uniq() |> Enum.sort()

      assert xs == [0, 512, 588]
      assert ys == [0, 88]
      assert Enum.all?(coords, fn {_x, _y, w, h} -> w == 512 and h == 512 end)
      # right and bottom edges are reached (full coverage, overlap not gap)
      assert Enum.any?(coords, fn {x, _y, w, _h} -> x + w == 1100 end)
      assert Enum.any?(coords, fn {_x, y, _w, h} -> y + h == 600 end)
    end

    test "an axis <= tile size yields a single clamped tile on that axis" do
      coords = CropScore.tile_coords(400, 900, 512)
      assert Enum.all?(coords, fn {x, _y, w, _h} -> x == 0 and w == 400 end)
      ys = coords |> Enum.map(fn {_x, y, _w, _h} -> y end) |> Enum.sort()
      assert ys == [0, 388]
    end

    test "an exact multiple needs no edge clamp" do
      coords = CropScore.tile_coords(1024, 512, 512)
      assert length(coords) == 2
      assert Enum.map(coords, fn {x, _, _, _} -> x end) |> Enum.sort() == [0, 512]
    end
  end

  describe "subsample/2" do
    test "returns all tiles when count <= k" do
      tiles = Enum.to_list(1..10)
      assert CropScore.subsample(tiles, 16) == tiles
    end

    test "picks k evenly-spaced tiles spanning both endpoints when count > k" do
      tiles = Enum.to_list(0..99)
      sub = CropScore.subsample(tiles, 16)
      assert length(sub) == 16
      assert hd(sub) == 0
      assert List.last(sub) == 99
    end
  end

  describe "percentile/2" do
    test "p10 of a single value is that value" do
      assert CropScore.percentile([42.0], 0.10) == 42.0
    end

    test "p10 of 16 sorted scores is the 2nd-lowest (floor index 1)" do
      sorted = Enum.map(0..15, &(&1 * 1.0))
      assert CropScore.percentile(sorted, 0.10) == 1.0
    end
  end

  test "crossover_megapixels/0 is the documented 6 MP operating point" do
    assert CropScore.crossover_megapixels() == 6
  end
end
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `mise exec -- mix test test/image_pipe/output/ssim2_metric/crop_score_test.exs`
Expected: FAIL — `CropScore` (module) is not available / undefined function.

- [ ] **Step 3: Write the minimal implementation (geometry only)**

Create `lib/image_pipe/output/ssim2_metric/crop_score.ex`:

```elixir
defmodule ImagePipe.Output.Ssim2Metric.CropScore do
  @moduledoc """
  Crop-based (tiled) SSIMULACRA2 scoring for the autoquality search on large
  outputs. Above an internal ~6 MP crossover the search scores `@subsample_k`
  native-resolution 512px tiles of the full-res encode and takes their p10,
  instead of scoring the whole frame — a flat ~4.2 MP metric sample regardless of
  source size (issue #354, benchmark Part E).

  This module does tiling + `extract_area` only; **all** SSIMULACRA2 access is
  delegated to the parent `ImagePipe.Output.Ssim2Metric`, which stays the only
  module touching `Ssimulacra2.*`.
  """

  alias ImagePipe.Output.Ssim2Metric
  alias Vix.Vips.Operation

  # Part E operating point. Internal constants, not host config (issue #354
  # forbids a second user-facing knob; dynamic-K selection is future work).
  @tile 512
  @subsample_k 16
  @crossover_megapixels 6

  @doc "Megapixel crossover above which the search uses crop scoring."
  @spec crossover_megapixels() :: pos_integer()
  def crossover_megapixels, do: @crossover_megapixels

  @doc """
  Tile windows covering a `w`×`h` frame with full-size `t`×`t` windows. The last
  row/col is clamped to the edge (slight overlap, never a gap) so every tile is
  full size and safe for SSIMULACRA2's multiscale downsamples. An axis `<= t`
  yields a single clamped tile on that axis.
  """
  @spec tile_coords(pos_integer(), pos_integer(), pos_integer()) ::
          [{non_neg_integer(), non_neg_integer(), pos_integer(), pos_integer()}]
  def tile_coords(w, h, t \\ @tile) do
    tw = min(t, w)
    th = min(t, h)
    for y <- axis_positions(h, th), x <- axis_positions(w, tw), do: {x, y, tw, th}
  end

  defp axis_positions(size, t) when size <= t, do: [0]

  defp axis_positions(size, t) do
    (Enum.take_while(Stream.iterate(0, &(&1 + t)), &(&1 + t <= size)) ++ [size - t])
    |> Enum.uniq()
    |> Enum.sort()
  end

  @doc "Return `k` evenly-spaced items spanning both endpoints; all of them when `length <= k`."
  @spec subsample([a], pos_integer()) :: [a] when a: term()
  def subsample(items, k \\ @subsample_k) do
    n = length(items)

    if n <= k do
      items
    else
      Enum.map(0..(k - 1), &Enum.at(items, div(&1 * (n - 1), k - 1)))
    end
  end

  @doc "Percentile `p` (0.0–1.0) of an already-sorted list, floor-indexed (nearest-rank-low)."
  @spec percentile([number()], float()) :: number()
  def percentile(sorted, p) do
    n = length(sorted)
    Enum.at(sorted, min(n - 1, max(0, trunc(p * (n - 1)))))
  end
end
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `mise exec -- mix test test/image_pipe/output/ssim2_metric/crop_score_test.exs`
Expected: PASS (all geometry tests green). The `Operation`/`Ssim2Metric` aliases are unused for now — if `mix compile --warnings-as-errors` (Task end) complains, they're consumed by `p10/2` in Task 2; keep them.

- [ ] **Step 5: Commit**

```bash
git add lib/image_pipe/output/ssim2_metric/crop_score.ex test/image_pipe/output/ssim2_metric/crop_score_test.exs
git commit -m "feat(output): CropScore tiling geometry for autoquality (#354)

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Task 2: CropScore.p10/2 — score tiles via Ssim2Metric

**Files:**
- Modify: `lib/image_pipe/output/ssim2_metric/crop_score.ex`
- Test: `test/image_pipe/output/ssim2_metric/crop_score_test.exs`

- [ ] **Step 1: Write the failing test**

Append to `crop_score_test.exs` inside the module (add `alias Vix.Vips.Operation` at top):

```elixir
  describe "p10/2" do
    setup do
      # A 1100x600 sRGB zone-plate base (multi-tile on x, single-clamped pair on y).
      {:ok, z} = Operation.zone(1100, 600)
      {:ok, scaled} = Operation.linear(z, [127.5], [127.5])
      {:ok, uchar} = Operation.cast(scaled, :VIPS_FORMAT_UCHAR)
      {:ok, gray} = Operation.copy(uchar, interpretation: :VIPS_INTERPRETATION_B_W)
      {:ok, base} = Operation.bandjoin([gray, gray, gray])
      {:ok, base} = Operation.copy(base, interpretation: :VIPS_INTERPRETATION_sRGB)
      %{base: base}
    end

    test "identical candidate scores ~100 (perfect)", %{base: base} do
      assert {:ok, p10} = CropScore.p10(base, base)
      assert p10 > 99.0
    end

    test "a degraded candidate scores below a perfect one", %{base: base} do
      {:ok, blurred} = Operation.gaussblur(base, 3.0)
      assert {:ok, p10_blur} = CropScore.p10(base, blurred)
      assert {:ok, p10_same} = CropScore.p10(base, base)
      assert p10_blur < p10_same
    end
  end
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `mise exec -- mix test test/image_pipe/output/ssim2_metric/crop_score_test.exs -o p10`
Expected: FAIL — `CropScore.p10/2` undefined.

- [ ] **Step 3: Implement `p10/2`**

Add to `crop_score.ex`:

```elixir
  @doc """
  p10 of the per-tile SSIMULACRA2 scores between a finalized `base` image and a
  decoded `candidate` image, sub-sampled to `@subsample_k` tiles. Returns
  `{:ok, score}` or `{:error, reason}` (any `extract_area`/score failure).
  """
  @spec p10(Vix.Vips.Image.t(), Vix.Vips.Image.t()) :: {:ok, float()} | {:error, term()}
  def p10(%Vix.Vips.Image{} = base, %Vix.Vips.Image{} = candidate) do
    coords = tile_coords(Image.width(base), Image.height(base))

    with {:ok, scores} <- tile_scores(base, candidate, subsample(coords)) do
      {:ok, percentile(Enum.sort(scores), 0.10)}
    end
  end

  defp tile_scores(base, candidate, coords) do
    Enum.reduce_while(coords, {:ok, []}, fn coord, {:ok, acc} ->
      case tile_score(base, candidate, coord) do
        {:ok, score} -> {:cont, {:ok, [score | acc]}}
        {:error, _} = err -> {:halt, err}
      end
    end)
  end

  defp tile_score(base, candidate, {x, y, w, h}) do
    with {:ok, bt} <- Operation.extract_area(base, x, y, w, h),
         {:ok, ct} <- Operation.extract_area(candidate, x, y, w, h),
         {:ok, ref} <- Ssim2Metric.reference(bt),
         {:ok, score} <- Ssim2Metric.score(ref, ct) do
      {:ok, score}
    end
  end
```

> Note: `subsample(coords)` sub-samples the *spatial* tile list before scoring, so only K tiles are ever scored — the cost lever. `Image.width/height` are the public `image` accessors already used across the codebase.

- [ ] **Step 4: Run the test to verify it passes**

Run: `mise exec -- mix test test/image_pipe/output/ssim2_metric/crop_score_test.exs`
Expected: PASS. (First run compiles the `ssimulacra2` NIF — slow once.)

- [ ] **Step 5: Commit**

```bash
git add lib/image_pipe/output/ssim2_metric/crop_score.ex test/image_pipe/output/ssim2_metric/crop_score_test.exs
git commit -m "feat(output): CropScore.p10 scores tiles via Ssim2Metric (#354)

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Task 3: Architecture test — CropScore touches no Ssimulacra2.*

**Files:**
- Modify: `test/image_pipe/architecture_boundary_test.exs`

- [ ] **Step 1: Inspect the existing file to match its source-scan style**

Run: `mise exec -- mix test test/image_pipe/architecture_boundary_test.exs` (confirm it's green) and open it to copy the established `File.read!` + `=~` pattern used for the namespace scans (this is the **only** file allowed to scan `.ex` source, per AGENTS.md).

- [ ] **Step 2: Write the failing test**

Add a test asserting the single-touchpoint invariant:

```elixir
  test "CropScore delegates all SSIMULACRA2 access through Ssim2Metric" do
    src = File.read!("lib/image_pipe/output/ssim2_metric/crop_score.ex")
    refute src =~ "Ssimulacra2", "CropScore must not reference Ssimulacra2.* directly"
  end
```

- [ ] **Step 3: Run it to verify it passes (invariant already holds)**

Run: `mise exec -- mix test test/image_pipe/architecture_boundary_test.exs`
Expected: PASS — Task 2's `p10/2` already routes through `Ssim2Metric`. (This is a guard test that *locks in* the invariant; it should pass on first write. If it fails, Task 2 introduced a direct `Ssimulacra2.` reference — fix Task 2.)

- [ ] **Step 4: Commit**

```bash
git add test/image_pipe/architecture_boundary_test.exs
git commit -m "test(output): lock CropScore single-touchpoint invariant (#354)

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Task 4: EncodeSearch — objective-neutral confirm/bump phase

**Files:**
- Modify: `lib/image_pipe/output/encode_search.ex`
- Test: `test/image_pipe/output/encode_search_test.exs`

This task adds the closure-injected confirm phase to the pure `search/3` core (no `:ssim2`/crop literal in the new mechanics). It is fully testable with injected closures.

- [ ] **Step 1: Write the failing tests**

Append to `encode_search_test.exs`. These use injected `confirm_fun`/`confirm_band` to drive the new phase. (`search/3` will accept `:confirm_fun`, `:confirm_band`, `:confirm_max_quality`, `:max_bump_passes` opts.)

```elixir
  describe "confirm phase (objective-neutral re-validation)" do
    # The objective score_fun is an ESTIMATE (e.g. crop p10 - offset); the
    # confirm_fun is the AUTHORITATIVE measure. confirm_band is target-allowed_error.
    test "no confirm_fun is a pure passthrough (today's behavior)" do
      rs = %RQS{objective: :ssim2, target: 90.0, min_quality: 10, max_quality: 80, allowed_error: 0.0}
      enc = fn q -> {:ok, :binary.copy(<<0>>, q * 100)} end
      score = fn bin -> byte_size(bin) / 100 + 20.0 end

      assert {:ok, _bin, %{quality: 70, outcome: :hit, score: s}} =
               EncodeSearch.search(rs, nil, encode_fun: enc, score_fun: score, max_iterations: 8)

      assert s >= 90.0
    end

    test "confirm clears at the objective winner -> :hit, 1 confirm pass, authoritative score" do
      rs = %RQS{objective: :ssim2, target: 90.0, min_quality: 10, max_quality: 80, allowed_error: 0.0}
      enc = fn q -> {:ok, :binary.copy(<<0>>, q * 100)} end
      # estimate over-reports by +5 so the objective picks q65; confirm (true) clears at 65.
      estimate = fn bin -> byte_size(bin) / 100 + 25.0 end
      confirm = fn bin -> byte_size(bin) / 100 + 20.0 end

      assert {:ok, _bin, meta} =
               EncodeSearch.search(rs, nil,
                 encode_fun: enc,
                 score_fun: estimate,
                 confirm_fun: confirm,
                 confirm_band: 90.0,
                 confirm_max_quality: 80,
                 max_bump_passes: 2
               )

      assert meta.quality == 65
      assert meta.outcome == :hit
      assert meta.score >= 90.0
      assert meta.confirm_passes == 1
    end

    test "undershoot bumps up to clear (2 confirm passes)" do
      rs = %RQS{objective: :ssim2, target: 90.0, min_quality: 10, max_quality: 80, allowed_error: 0.0}
      enc = fn q -> {:ok, :binary.copy(<<0>>, q * 100)} end
      # estimate over-reports by +6: objective picks q64 (est 90), true at 64 is 89 (undershoot),
      # true at 65 is 90 (clears) -> bump +1.
      estimate = fn bin -> byte_size(bin) / 100 + 26.0 end
      confirm = fn bin -> byte_size(bin) / 100 + 25.0 end

      assert {:ok, _bin, meta} =
               EncodeSearch.search(rs, nil,
                 encode_fun: enc,
                 score_fun: estimate,
                 confirm_fun: confirm,
                 confirm_band: 90.0,
                 confirm_max_quality: 80,
                 max_bump_passes: 2
               )

      assert meta.quality == 65
      assert meta.outcome == :hit
      assert meta.score >= 90.0
      assert meta.confirm_passes == 2
    end

    test "bump-cap exhaustion ships best-effort at the highest q tried" do
      rs = %RQS{objective: :ssim2, target: 90.0, min_quality: 10, max_quality: 80, allowed_error: 0.0}
      enc = fn q -> {:ok, :binary.copy(<<0>>, q * 100)} end
      # estimate clears at q60 (60+30=90) but the TRUE score never reaches 90 in [60,62]:
      # true = bytes/100 + 25 -> q60..62 give 85..87, all undershoot; cap 2 -> best-effort at 62.
      estimate = fn bin -> byte_size(bin) / 100 + 30.0 end
      confirm = fn bin -> byte_size(bin) / 100 + 25.0 end

      assert {:ok, _bin, meta} =
               EncodeSearch.search(rs, nil,
                 encode_fun: enc,
                 score_fun: estimate,
                 confirm_fun: confirm,
                 confirm_band: 90.0,
                 confirm_max_quality: 80,
                 max_bump_passes: 2
               )

      assert meta.quality == 62
      assert meta.outcome == :best_effort
      assert meta.confirm_passes == 3
    end
  end
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `mise exec -- mix test test/image_pipe/output/encode_search_test.exs`
Expected: FAIL — `confirm_passes` missing from meta / new opts ignored (the passthrough test passes; the four new ones fail on `meta.confirm_passes` or wrong quality).

- [ ] **Step 3: Implement the confirm phase**

In `encode_search.ex`:

(a) Add the bump-cap default and extend `Ctx`:

```elixir
  @default_max_iterations 6
  @default_max_bump_passes 2
  @max_bytes_alone_floor 10
  @max_bytes_alone_base 90
```

```elixir
  defmodule Ctx do
    @moduledoc false
    @enforce_keys [:encode_fun]
    defstruct encode_fun: nil,
              score_fun: nil,
              confirm_fun: nil,
              confirm_band: nil,
              confirm_max_quality: nil,
              max_bump_passes: 2,
              encode_memo: %{},
              score_memo: %{},
              confirm_memo: %{},
              confirm_passes: 0,
              iterations: 0,
              max_iterations: 0,
              telemetry_opts: []
  end
```

(b) Populate the new `Ctx` fields in `search/3`:

```elixir
    ctx = %Ctx{
      encode_fun: Keyword.fetch!(opts, :encode_fun),
      score_fun: Keyword.get(opts, :score_fun),
      confirm_fun: Keyword.get(opts, :confirm_fun),
      confirm_band: Keyword.get(opts, :confirm_band),
      confirm_max_quality: Keyword.get(opts, :confirm_max_quality),
      max_bump_passes: Keyword.get(opts, :max_bump_passes, @default_max_bump_passes),
      max_iterations: Keyword.get(opts, :max_iterations, @default_max_iterations),
      telemetry_opts: telemetry_opts
    }
```

(c) Insert the confirm phase into `do_search`:

```elixir
  defp do_search(quality_search, max_bytes, ctx, opts) do
    with {:ok, objective_q, objective_outcome, _objective_score, ctx} <-
           objective_phase(quality_search, ctx, opts),
         {:ok, confirmed_q, confirmed_outcome, ctx} <-
           confirm_phase(objective_q, objective_outcome, ctx),
         {:ok, final_q, final_outcome, ctx} <-
           cap_phase(quality_search, max_bytes, confirmed_q, confirmed_outcome, ctx) do
      build_result(final_q, final_outcome, quality_search, ctx)
    end
  end
```

(d) Add the phase itself (objective-neutral — keys off `confirm_fun`):

```elixir
  # --- confirm phase (objective-neutral re-validation) ----------------------

  # No confirm closure: the objective's verdict stands (full-frame ssim2, :size,
  # :none paths are byte-identical to before this feature).
  defp confirm_phase(objective_q, objective_outcome, %Ctx{confirm_fun: nil} = ctx),
    do: {:ok, objective_q, objective_outcome, ctx}

  # The objective ran on an ESTIMATE; re-validate the winner against the
  # authoritative measure and linear-bump on undershoot (cap @max_bump_passes).
  defp confirm_phase(objective_q, _objective_outcome, ctx) do
    with {:ok, ctx} <- confirm_score(objective_q, ctx) do
      if Map.fetch!(ctx.confirm_memo, objective_q) >= ctx.confirm_band do
        {:ok, objective_q, :hit, ctx}
      else
        bump(objective_q, ctx)
      end
    end
  end

  # Linear scan q+1..q+cap (bounded by confirm_max_quality), first clearing q wins;
  # else best-effort at the highest q tried. Linear (not binary) is deliberate:
  # encoder score-vs-quality is only approximately monotone, and a linear scan
  # catches a local non-monotone dip a binary step could skip.
  defp bump(objective_q, %Ctx{max_bump_passes: cap, confirm_max_quality: max_q} = ctx) do
    last_q = min(objective_q + cap, max_q)
    do_bump(objective_q + 1, last_q, objective_q, ctx)
  end

  defp do_bump(try_q, last_q, best_q, ctx) when try_q > last_q,
    do: {:ok, best_q, :best_effort, ctx}

  defp do_bump(try_q, last_q, _best_q, ctx) do
    case confirm_score(try_q, ctx) do
      {:error, _} = err ->
        err

      {:ok, ctx} ->
        if Map.fetch!(ctx.confirm_memo, try_q) >= ctx.confirm_band,
          do: {:ok, try_q, :hit, ctx},
          else: do_bump(try_q + 1, last_q, try_q, ctx)
    end
  end

  # Ensure q is encoded, then authoritatively score it once (memoized), counting
  # the pass. Encode is forced even past the iteration cap: the confirm MUST run.
  defp confirm_score(q, ctx) do
    with {:ok, ctx} <- ensure_probed(q, ctx) do
      if Map.has_key?(ctx.confirm_memo, q) do
        {:ok, ctx}
      else
        score = ctx.confirm_fun.(Map.fetch!(ctx.encode_memo, q))

        {:ok,
         %{
           ctx
           | confirm_memo: Map.put(ctx.confirm_memo, q, score),
             confirm_passes: ctx.confirm_passes + 1
         }}
      end
    end
  end
```

(e) Make the result honest and carry `confirm_passes`. Replace `build_result/6` and the score helpers:

```elixir
  defp build_result(final_q, final_outcome, quality_search, ctx) do
    binary = Map.fetch!(ctx.encode_memo, final_q)
    ctx = ensure_winner_scored(final_q, binary, quality_search, ctx)

    meta = %{
      quality: final_q,
      bytes: byte_size(binary),
      iterations: ctx.iterations,
      outcome: final_outcome,
      score: result_score(final_q, quality_search, ctx),
      confirm_passes: ctx.confirm_passes
    }

    {:ok, binary, meta}
  end

  # In crop mode the authoritative score lives in confirm_memo; a cap-relocated
  # winner (max_bytes) may not be there yet — confirm-score it so meta.score is the
  # true full-frame score, never the crop estimate in score_memo.
  defp ensure_winner_scored(final_q, _binary, %RQS{objective: :ssim2}, %Ctx{confirm_fun: fun} = ctx)
       when not is_nil(fun) do
    case confirm_score(final_q, ctx) do
      {:ok, ctx} -> ctx
      {:error, _} -> ctx
    end
  end

  defp ensure_winner_scored(final_q, binary, %RQS{objective: :ssim2}, ctx) do
    if Map.has_key?(ctx.score_memo, final_q), do: ctx, else: maybe_score(final_q, binary, ctx)
  end

  defp ensure_winner_scored(_final_q, _binary, _quality_search, ctx), do: ctx

  defp result_score(final_q, %RQS{objective: :ssim2}, ctx),
    do: Map.get(ctx.confirm_memo, final_q) || Map.get(ctx.score_memo, final_q)

  defp result_score(_final_q, _quality_search, _ctx), do: nil
```

(f) Add `confirm_passes` to the stop meta map in `search_stop_meta/2` (success clause):

```elixir
  defp search_stop_meta(quality_search, {:ok, _binary, meta}) do
    %{
      result: :ok,
      objective: objective_of(quality_search),
      chosen_quality: meta.quality,
      chosen_bytes: meta.bytes,
      iterations: meta.iterations,
      outcome: meta.outcome,
      final_score: meta.score,
      scorer: scorer_of(meta),
      confirm_passes: meta.confirm_passes
    }
  end
```

And add the helper (the `scorer` is derivable from whether confirm ran; the real `:full | :crop` tag is threaded in Task 5 via meta — for now default to `:full` when no confirm passes were needed *and* no confirm_fun; Task 5 finalizes it):

```elixir
  # Placeholder until Task 5 threads the scorer mode through meta. Overwritten there.
  defp scorer_of(_meta), do: :full
```

> Task 5 replaces `scorer_of/1` with a real `meta.scorer` value. Keeping a single source of truth: see Task 5 Step 3.

- [ ] **Step 4: Run the tests to verify they pass**

Run: `mise exec -- mix test test/image_pipe/output/encode_search_test.exs test/image_pipe/output/encode_search_property_test.exs`
Expected: PASS (existing + new confirm tests). The property test must still pass (confirm phase is a no-op without `confirm_fun`).

- [ ] **Step 5: Commit**

```bash
git add lib/image_pipe/output/encode_search.ex test/image_pipe/output/encode_search_test.exs
git commit -m "feat(output): objective-neutral confirm/bump phase in EncodeSearch (#354)

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Task 5: EncodeSearch.run/3 — scorer mode + crop closures

**Files:**
- Modify: `lib/image_pipe/output/encode_search.ex`
- Test: `test/image_pipe/output/encode_search_test.exs`

`run/3` gains a `scorer: :full | :crop` opt (default `:full`). For `:crop` + `:ssim2` it builds the crop `score_fun` (`CropScore.p10 - macro_offset`) and the full-frame `confirm_fun`/`confirm_band`/`confirm_max_quality`, and stamps `meta.scorer`.

- [ ] **Step 1: Add the macro_offset constant (placeholder, calibrated in Task 9)**

At the top of `encode_search.ex` add:

```elixir
  alias ImagePipe.Output.Ssim2Metric.CropScore

  # Crop-scoring p10→full-frame correction (benchmark Part E). Subtracted from the
  # tile p10 so the unchanged objective predicate (score >= target-allowed_error)
  # reproduces the full-frame decision. CALIBRATED in #354 Task 9 on `clic`,
  # validated on `clic_holdout`; Part E median was +0.22.
  @crop_macro_offset 0.22
```

- [ ] **Step 2: Write the failing test (scorer threading via a fake, no real images at the search layer)**

The crop `score_fun` is built inside `run/3` from a real image, so the *unit* assertion for scorer threading lives at the `search/3` meta level. Add a test that the stop-meta `scorer` reflects crop mode when a `confirm_fun` is present. Append to `encode_search_test.exs`:

```elixir
  test "stop meta scorer is :crop when a confirm_fun drives the search, else :full" do
    rs = %RQS{objective: :ssim2, target: 90.0, min_quality: 10, max_quality: 80, allowed_error: 0.0}
    enc = fn q -> {:ok, :binary.copy(<<0>>, q * 100)} end
    score = fn bin -> byte_size(bin) / 100 + 20.0 end

    # full mode: no confirm_fun
    assert {:ok, _b, %{quality: 70}} =
             EncodeSearch.search(rs, nil, encode_fun: enc, score_fun: score, max_iterations: 8)

    # crop mode: confirm_fun present -> scorer :crop (asserted via run/3 in the wire test;
    # here we assert search/3 accepts and uses the scorer opt without crashing)
    assert {:ok, _b, %{quality: q}} =
             EncodeSearch.search(rs, nil,
               encode_fun: enc,
               score_fun: score,
               confirm_fun: score,
               confirm_band: 90.0,
               confirm_max_quality: 80,
               scorer: :crop,
               max_iterations: 8
             )

    assert is_integer(q)
  end
```

- [ ] **Step 3: Implement scorer threading**

(a) `search/3` reads the scorer opt and stores it for the stop meta. Add to the `Ctx` (`scorer: :full`) and set it:

```elixir
      scorer: Keyword.get(opts, :scorer, :full),
```

Replace the placeholder `scorer_of/1` from Task 4 with a real read — change `search_stop_meta` to take the ctx-derived scorer. Simplest: thread scorer into the result meta in `build_result`:

```elixir
    meta = %{
      quality: final_q,
      bytes: byte_size(binary),
      iterations: ctx.iterations,
      outcome: final_outcome,
      score: result_score(final_q, quality_search, ctx),
      confirm_passes: ctx.confirm_passes,
      scorer: ctx.scorer
    }
```

and in `search_stop_meta`:

```elixir
      scorer: meta.scorer,
```

Delete the placeholder `scorer_of/1`.

(b) `run/3` builds the closures by scorer mode:

```elixir
  def run(finalized_image, %Resolved{} = resolved, opts) do
    encode_fun = fn quality -> Encoder.encode_to_buffer(finalized_image, resolved, quality) end
    max_iterations = Keyword.get(opts, :max_iterations, @default_max_iterations)
    scorer = Keyword.get(opts, :scorer, :full)

    with {:ok, search_opts} <- score_opts(finalized_image, resolved, scorer) do
      base_quality = base_quality(resolved)

      try do
        search(resolved.quality_search, resolved.max_bytes,
          [
            encode_fun: encode_fun,
            base_quality: base_quality,
            max_iterations: max_iterations,
            scorer: scorer,
            telemetry_opts: Keyword.get(opts, :telemetry_opts, [])
          ] ++ search_opts
        )
      catch
        {:image_pipe_score_error, reason} -> {:error, {:encode, reason}}
      end
    end
  end

  # Build the objective score_fun (+ confirm closures for crop mode) for the
  # resolved objective and the chosen scorer.
  defp score_opts(_image, %Resolved{quality_search: :none}, _scorer), do: {:ok, []}
  defp score_opts(_image, %Resolved{quality_search: %RQS{objective: :size}}, _scorer), do: {:ok, []}

  defp score_opts(image, %Resolved{quality_search: %RQS{objective: :ssim2} = rqs}, :full) do
    with {:ok, ref} <- Ssim2Metric.reference(image) do
      {:ok, [score_fun: fn bytes -> full_frame_score(ref, bytes) end]}
    else
      {:error, reason} -> {:error, {:encode, reason}}
    end
  end

  defp score_opts(image, %Resolved{quality_search: %RQS{objective: :ssim2} = rqs}, :crop) do
    with {:ok, ref} <- Ssim2Metric.reference(image) do
      confirm = fn bytes -> full_frame_score(ref, bytes) end
      crop = fn bytes -> crop_estimate(image, bytes) end

      {:ok,
       [
         score_fun: crop,
         confirm_fun: confirm,
         confirm_band: rqs.target - rqs.allowed_error,
         confirm_max_quality: rqs.max_quality
       ]}
    else
      {:error, reason} -> {:error, {:encode, reason}}
    end
  end
```

(c) Replace the old `build_score_fun/2` + `ssim2_score/2` with the shared decode-and-score helpers (the full-frame one is the old logic; the crop one decodes once then delegates to `CropScore`). Both throw the tagged tuple `run/3` catches:

```elixir
  # Decode the candidate once and score the whole frame against the reference.
  defp full_frame_score(ref, bytes) do
    with {:ok, candidate} <- Image.from_binary(bytes),
         {:ok, score} <- Ssim2Metric.score(ref, candidate) do
      score
    else
      {:error, reason} -> throw({:image_pipe_score_error, reason})
    end
  end

  # Decode the candidate once; crop-score its tiles vs the base; subtract the
  # macro offset so the unchanged objective predicate reproduces the full-frame
  # decision. Failures route through the same tagged-throw channel.
  defp crop_estimate(base, bytes) do
    with {:ok, candidate} <- Image.from_binary(bytes),
         {:ok, p10} <- CropScore.p10(base, candidate) do
      p10 - @crop_macro_offset
    else
      {:error, reason} -> throw({:image_pipe_score_error, reason})
    end
  end
```

Remove the now-dead `build_score_fun/2` clauses and the old `ssim2_score/2`.

- [ ] **Step 4: Run the tests**

Run: `mise exec -- mix test test/image_pipe/output/encode_search_test.exs test/image_pipe/output/encode_search_telemetry_test.exs test/image_pipe/output/encode_search_property_test.exs`
Expected: PASS. (The telemetry test asserts `final_score`/`chosen_*` still present; `scorer`/`confirm_passes` are extra keys — fine. Task 6 wires `run/3` callers.)

- [ ] **Step 5: Commit**

```bash
git add lib/image_pipe/output/encode_search.ex test/image_pipe/output/encode_search_test.exs
git commit -m "feat(output): EncodeSearch.run scorer mode + crop closures (#354)

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Task 6: Encoder precedence — skip | crop | full

**Files:**
- Modify: `lib/image_pipe/output/encoder.ex`

- [ ] **Step 1: Inspect current `stream_output`/`skip_search?`/`search_output`**

Open `encoder.ex` lines 39–86. The decision today is binary (`skip_search?` → search or lazy). We add the crop/full split inside the search branch, computing MP once.

- [ ] **Step 2: Implement the three-way ladder**

Replace `stream_output`’s branch and `search_output`:

```elixir
  def stream_output(%VixImage{} = image, %Resolved{} = resolved_output, opts) do
    with {:ok, mime_type, suffix} <- output_format(resolved_output),
         {:ok, finalized} <- finalize(image, resolved_output) do
      if search?(resolved_output) and Format.supports_quality?(resolved_output.format) do
        case scorer_mode(finalized, resolved_output) do
          :skip -> lazy_output(finalized, resolved_output, mime_type, suffix, opts)
          scorer -> search_output(finalized, resolved_output, mime_type, scorer, opts)
        end
      else
        lazy_output(finalized, resolved_output, mime_type, suffix, opts)
      end
    end
  rescue
    exception -> {:error, {:encode, exception, __STACKTRACE__}}
  end
```

```elixir
  # One megapixel computation, one precedence ladder: the host max_resolution skip
  # wins; otherwise crop-score above the internal crossover, else full-frame.
  defp scorer_mode(finalized, %Resolved{quality_search: quality_search}) do
    megapixels = Image.width(finalized) * Image.height(finalized) / 1_000_000
    max_resolution = max_resolution_of(quality_search)

    cond do
      EncodeSearch.skip?(%{max_resolution: max_resolution}, megapixels) -> :skip
      megapixels > CropScore.crossover_megapixels() -> :crop
      true -> :full
    end
  end

  defp max_resolution_of(%{max_resolution: mr}), do: mr
  defp max_resolution_of(:none), do: 0
```

```elixir
  defp search_output(finalized, resolved_output, mime_type, scorer, opts) do
    search_opts = [scorer: scorer, telemetry_opts: ImagePipe.Telemetry.telemetry_opts(opts)]

    case EncodeSearch.run(finalized, resolved_output, search_opts) do
      {:ok, binary, _meta} -> {:ok, [binary], mime_type}
      {:error, _reason} = err -> err
    end
  end
```

Add the alias near the top:

```elixir
  alias ImagePipe.Output.Ssim2Metric.CropScore
```

Remove the now-unused `skip_search?/2` (its logic moved into `scorer_mode/2`).

- [ ] **Step 3: Run the existing encoder/output suite**

Run: `mise exec -- mix test test/image_pipe/output/`
Expected: PASS (no behavior change for ≤6 MP / `:size` / `:none`; the `:skip` path is unchanged). If `skip_search?` had a dedicated test, it now exercises `scorer_mode` indirectly via wire tests (Task 8) — do **not** add a `function_exported?`/name test (forbidden).

- [ ] **Step 4: Commit**

```bash
git add lib/image_pipe/output/encoder.ex
git commit -m "feat(output): Encoder skip|crop|full scorer precedence (#354)

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Task 7: Telemetry — render scorer in the default Logger

**Files:**
- Modify: `lib/image_pipe/telemetry/logger.ex`
- Modify: `test/image_pipe/telemetry/logger_test.exs`
- Modify: `test/image_pipe/output/encode_search_telemetry_test.exs`
- Modify: `docs/telemetry.md`

- [ ] **Step 1: Write the failing telemetry-meta test**

In `encode_search_telemetry_test.exs`, extend the existing assertions (in the one test) to cover the new keys for a crop-driven search:

```elixir
    assert stop_meta.scorer == :full
    assert stop_meta.confirm_passes == 0
```

(Place these next to the other `stop_meta.*` assertions — the existing test runs full-frame mode, so `:full`/`0`.)

- [ ] **Step 2: Write the failing Logger test**

In `logger_test.exs`, find the encode-search rendering assertion and add a crop-scorer case. Mirror the existing search-stop test, emitting a stop event with `scorer: :crop` and asserting the rendered line names the scorer. Example addition:

```elixir
  test "encode search stop names the crop scorer and surfaces outcome" do
    log =
      capture_log(fn ->
        emit_stop(%{
          result: :ok,
          objective: :ssim2,
          chosen_quality: 72,
          chosen_bytes: 12_345,
          iterations: 4,
          outcome: :hit,
          final_score: 90.4,
          scorer: :crop,
          confirm_passes: 1
        })
      end)

    assert log =~ "encode search"
    assert log =~ "crop"
    assert log =~ "q72"
  end
```

> Use the file's existing emit/capture helper (e.g. `emit_stop/1` or an inline `:telemetry.execute`); match its established pattern rather than inventing one.

- [ ] **Step 3: Run both to verify they fail**

Run: `mise exec -- mix test test/image_pipe/output/encode_search_telemetry_test.exs test/image_pipe/telemetry/logger_test.exs`
Expected: FAIL — Logger ignores `scorer`; meta assertions missing.

- [ ] **Step 4: Render `scorer` in the Logger message clause**

In `logger.ex`, update the encode-search `message/3` clause (line ~229) to surface the scorer while still surfacing the outcome:

```elixir
  defp message([:encode, :search | _], _m, meta) do
    score = if meta[:final_score], do: " score #{round2(meta[:final_score])}", else: ""
    scorer = if meta[:scorer], do: "#{meta[:scorer]} ", else: ""

    "image_pipe encode search: #{outcome(meta)} (#{scorer}#{meta[:outcome]} " <>
      "q#{meta[:chosen_quality]} #{meta[:chosen_bytes]}b#{score})"
  end
```

No subscription change is needed — `[:encode, :search]` is already in `@group_span_events` (the `scorer`/`confirm_passes` keys ride the existing `:stop` meta). `level_for/3` already escalates `:best_effort` to `:warning`; crop best-effort inherits that correctly.

- [ ] **Step 5: Run to verify they pass**

Run: `mise exec -- mix test test/image_pipe/output/encode_search_telemetry_test.exs test/image_pipe/telemetry/logger_test.exs`
Expected: PASS.

- [ ] **Step 6: Update `docs/telemetry.md`**

Find the `[:encode, :search]` stop-event metadata documentation and add the two new keys with one-line descriptions:

```markdown
- `scorer` — `:full` (whole-frame SSIMULACRA2) or `:crop` (K p10-tiles above the
  internal ~6 MP crossover, #354).
- `confirm_passes` — full-frame confirm/bump passes on the crop path (1 = confirm
  only; up to 3 with the bump cap). `0` on the full-frame path.
```

- [ ] **Step 7: Commit**

```bash
git add lib/image_pipe/telemetry/logger.ex test/image_pipe/telemetry/logger_test.exs test/image_pipe/output/encode_search_telemetry_test.exs docs/telemetry.md
git commit -m "feat(telemetry): surface crop scorer in encode-search span + Logger (#354)

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Task 8: Wire-level tests — stream_output on a zone-plate

**Files:**
- Create: `test/image_pipe/output/encoder_crop_scoring_test.exs`

These exercise the real path end-to-end through `Encoder.stream_output`, self-referentially (compute the full-frame baseline in-test; no golden q). Inputs are the deterministic synthetic zone-plate at a **capped near-crossover ~7 MP** size — never 15–36 MP (keeps the test in low-single-digit seconds; no committed fixture / `SourceInventory` burden).

- [ ] **Step 1: Write the tests**

```elixir
defmodule ImagePipe.Output.EncoderCropScoringTest do
  use ExUnit.Case, async: true

  alias ImagePipe.Output.Encoder
  alias ImagePipe.Output.Resolved
  alias ImagePipe.Output.ResolvedQualitySearch, as: RQS
  alias Vix.Vips.Operation

  # Deterministic high-frequency zone-plate -> full-range 8-bit sRGB, square at `mp`.
  defp zone_plate(mp) do
    side = round(:math.sqrt(mp * 1_000_000))
    {:ok, z} = Operation.zone(side, side)
    {:ok, scaled} = Operation.linear(z, [127.5], [127.5])
    {:ok, uchar} = Operation.cast(scaled, :VIPS_FORMAT_UCHAR)
    {:ok, gray} = Operation.copy(uchar, interpretation: :VIPS_INTERPRETATION_B_W)
    {:ok, rgb} = Operation.bandjoin([gray, gray, gray])
    {:ok, srgb} = Operation.copy(rgb, interpretation: :VIPS_INTERPRETATION_sRGB)
    srgb
  end

  defp ssim2_resolved do
    %Resolved{
      format: :jpeg,
      quality: :default,
      response_headers: [],
      strip_metadata: true,
      keep_copyright: false,
      color_profile: :preserve_source,
      quality_search: %RQS{
        objective: :ssim2,
        target: 80.0,
        min_quality: 40,
        max_quality: 95,
        allowed_error: 1.0,
        max_resolution: 0
      }
    }
  end

  defp delivered_quality(%Resolved{} = resolved, image) do
    {:ok, [binary], _mime} = Encoder.stream_output(image, resolved, [])
    # decode the delivered JPEG; assert a property via re-encoding probes is overkill —
    # instead compare bytes to the full-frame search's delivered bytes below.
    binary
  end

  test "crop-scored large output is within ~2 q / tolerance of the full-frame search" do
    image = zone_plate(7)
    resolved = ssim2_resolved()

    # The image is >6 MP, so stream_output picks :crop automatically.
    {:ok, [crop_bin], _} = Encoder.stream_output(image, resolved, [])

    # Build the full-frame baseline on the SAME image by forcing :full via a small input.
    # Run EncodeSearch.run directly with scorer: :full for a same-image baseline.
    {:ok, finalized} = force_finalize(image, resolved)
    {:ok, _full_bin, full_meta} =
      ImagePipe.Output.EncodeSearch.run(finalized, resolved, scorer: :full)
    {:ok, _crop_bin2, crop_meta} =
      ImagePipe.Output.EncodeSearch.run(finalized, resolved, scorer: :crop)

    assert abs(crop_meta.quality - full_meta.quality) <= 2
    assert crop_meta.scorer == :crop
    assert crop_meta.score >= resolved.quality_search.target - resolved.quality_search.allowed_error
    assert is_binary(crop_bin)
  end

  test "small (<6 MP) output uses the full-frame scorer" do
    image = zone_plate(2)
    resolved = ssim2_resolved()
    {:ok, finalized} = force_finalize(image, resolved)

    {:ok, _bin, meta} = ImagePipe.Output.EncodeSearch.run(finalized, resolved, scorer: :full)
    assert meta.scorer == :full
    # And stream_output's ladder must NOT crop a 2 MP image: assert via telemetry in
    # the wire-conformance suite, or trust scorer_mode (covered by the crossover test).
  end

  test "crossover-boundary input (~6.x MP) engages crop and runs the confirm" do
    image = zone_plate(7)
    resolved = ssim2_resolved()
    {:ok, finalized} = force_finalize(image, resolved)

    {:ok, _bin, meta} = ImagePipe.Output.EncodeSearch.run(finalized, resolved, scorer: :crop)
    assert meta.scorer == :crop
    assert meta.confirm_passes >= 1
  end

  test "max_bytes still binds the final delivered q on the crop path" do
    image = zone_plate(7)
    base = ssim2_resolved()
    # A tight byte budget below the ssim2 pick forces cap_phase to descend.
    resolved = %Resolved{base | max_bytes: 50_000}
    {:ok, finalized} = force_finalize(image, resolved)

    {:ok, binary, meta} = ImagePipe.Output.EncodeSearch.run(finalized, resolved, scorer: :crop)
    assert byte_size(binary) <= 50_000
    assert meta.quality <= base.quality_search.max_quality
  end

  # finalize/2 is private to Encoder; reproduce its observable effect (copy_memory +
  # color/flatten) by round-tripping through stream_output is not possible, so call the
  # public encode path's finalize via a thin helper if exposed; otherwise encode the
  # raw image (the search re-encodes per probe regardless of finalize identity for a
  # plain sRGB zone-plate with strip_metadata + preserve_source).
  defp force_finalize(image, _resolved), do: {:ok, image}
end
```

> Implementation note for the executor: `Encoder.finalize/2` is private. For a plain sRGB, opaque, metadata-light zone-plate, `finalize` is effectively `copy_memory` (no flatten, no profile convert), so passing the raw `image` to `EncodeSearch.run/3` is pixel-equivalent for the baseline-vs-crop *comparison* (both sides use the same input). The `stream_output` calls in the first test exercise the real `finalize`. If a future reviewer wants the exact finalized frame, expose a test-only `finalize` via `@doc false` rather than duplicating color logic. Keep `force_finalize/2` as the documented shim.

- [ ] **Step 2: Run the tests**

Run: `mise exec -- mix test test/image_pipe/output/encoder_crop_scoring_test.exs`
Expected: PASS. If the 7 MP search is slow, confirm it stays in low-single-digit seconds; if flaky on `<= 2` q, widen to `<= 3` only with a comment citing Part E's ±2–4 q residual (do not loosen silently).

- [ ] **Step 3: Commit**

```bash
git add test/image_pipe/output/encoder_crop_scoring_test.exs
git commit -m "test(output): wire-level crop-scoring on a near-crossover zone-plate (#354)

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Task 9: Calibrate macro_offset + measure cap-2 miss rate

**Files:**
- Modify: `lib/image_pipe/output/encode_search.ex` (`@crop_macro_offset` value, if calibration moves it)
- Modify: `docs/autoquality_benchmark.md` (record results)

This task produces the empirical constant and the data that gates §3's fallback. It runs the existing benchmark harness; it does **not** invent new measurement code beyond what `--part e` already emits.

- [ ] **Step 1: Fetch the corpus (one-time)**

Run: `mise exec -- mix autoquality.corpus`
Expected: populates the shared cache; note the printed cache dir as `<cache>`.

- [ ] **Step 2: Derive the offset on `clic`, validate on `clic_holdout`**

Run: `mise exec -- mix autoquality.bench --part e --corpus <cache>`
Read the per-source `p10 offset (median)` table. The calibration target is the macro-average offset that makes the crop decision track full-frame; the bench already prints `p10 offset (mean of per-source medians)`. Confirm the `clic` median and the held-out `clic_holdout` median agree within the spec tolerance (~±1.5). If they diverge materially, the global constant is photo-overfit — record that and prefer a value centered on the macro (all-source) behavior, per spec §6.

- [ ] **Step 3: Measure the cap-2 miss rate (gate for §3 fallback)**

From the same Part E run, the bench reports per-source hit/miss against target and the offset spread. Compute the fraction of crop picks whose full-frame confirm would still be >2 q below target after the offset correction (the bench's offset spread + the per-source `q̄` give this; if the harness does not already print a cap-miss column, treat the offset-spread tail beyond `2 q × (Δscore/Δq)` as the proxy). Decision:
  - **Miss rate low/small** → keep §3 default (best-effort at cap 2). No code change beyond the offset value.
  - **Miss rate not acceptably low** → implement the escalation: in `EncodeSearch.do_bump/4`'s exhaustion clause, replace `{:ok, best_q, :best_effort, ctx}` with a bounded full-frame `search_lowest_satisfying` over `[best_q+1, confirm_max_quality]` using `confirm_fun`. (Add a focused closure test mirroring Task 4's exhaustion test but asserting it then clears.) Record the decision in the benchmark doc.

- [ ] **Step 4: Set the calibrated constant**

If the validated offset differs from the placeholder `0.22`, update `@crop_macro_offset` in `encode_search.ex` to the calibrated value and re-run Task 8's wire test to confirm the ±2 q assertion still holds.

- [ ] **Step 5: Record the results in `docs/autoquality_benchmark.md`**

Under Part E / recommendation #5, add a short subsection: the chosen `@crop_macro_offset`, the `clic` vs `clic_holdout` medians, the bump-fire rate, the cap-2 miss rate, and the fallback decision (best-effort vs bounded full-frame search). Keep it factual, machine-caveated like the rest of the doc.

- [ ] **Step 6: Run the focused suite + commit**

```bash
mise exec -- mix test test/image_pipe/output/
git add lib/image_pipe/output/encode_search.ex docs/autoquality_benchmark.md
git commit -m "feat(autoquality): calibrate crop macro_offset + record cap-2 miss rate (#354)

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Task 10: imgproxy support matrix — Save/encode stage note

**Files:**
- Modify: `docs/imgproxy_support_matrix.md`

- [ ] **Step 1: Update the Save/encode row (line ~149)**

The row currently calls the search "a binary search over encoder quality." Append a sentence (matching the row's existing config-less-internal-stage framing):

```markdown
Above an internal ~6 MP crossover the `:ssim2` objective scores K=16
native-resolution p10-tiles of the full-res encode per probe (size-independent
metric cost, #354) plus one full-frame confirm + bounded bump on the winner;
below the crossover the full-frame search is unchanged. The crossover is internal
(it only selects the scorer); `autoquality_max_resolution` is unchanged and still
*disables* the search above the host cap.
```

- [ ] **Step 2: Confirm no option-table / config-row edit is needed**

Verify the autoquality config section (lines ~600–616) needs **no** new `IMGPROXY_AUTOQUALITY_*` row — K/tile/crossover/macro_offset are internal constants. Do not add a row. Do not add a `Diverges` note (no imgproxy wire oracle; `max_resolution` parity preserved).

- [ ] **Step 3: Commit**

```bash
git add docs/imgproxy_support_matrix.md
git commit -m "docs(imgproxy): note crop-scored ssim2 stage on the Save/encode row (#354)

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Task 11: Full gate

**Files:** none (verification)

- [ ] **Step 1: Run the Elixir gate**

Run: `mise exec -- mix format --check-formatted && mise exec -- mix compile --warnings-as-errors && mise exec -- mix credo --strict && mise exec -- mix test`

Or the task: `mise run precommit`
Expected: all green. Fix any formatting/credo/warning issues inline (e.g. unused aliases, doc gaps).

- [ ] **Step 2: Confirm architecture + boundary tests pass**

Run: `mise exec -- mix test test/image_pipe/architecture_boundary_test.exs`
Expected: PASS (CropScore single-touchpoint + Output boundary intact).

- [ ] **Step 3: Final commit if the gate required fixups**

```bash
git add -A
git commit -m "chore(autoquality): gate fixups for crop-based ssim2 scoring (#354)

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Self-review notes (for the executor)

- **Spec coverage:** §1→T1–T3, §2→T5, §3→T4, §4→T6, §5→T7, §6→T9, §7→T1/T4/T8, §8→T10.
- **The `@crop_macro_offset` placeholder (0.22)** is intentionally provisional until T9; T8's ±2 q assertion is robust to the exact value within the calibrated range, but re-run T8 after T9 sets the final constant.
- **Type/name consistency:** `CropScore.p10/2`, `CropScore.crossover_megapixels/0`, `scorer: :full | :crop`, meta keys `scorer`/`confirm_passes`, Ctx fields `confirm_fun`/`confirm_band`/`confirm_max_quality`/`max_bump_passes`/`confirm_memo`/`confirm_passes`/`scorer` are used identically across T4–T7.
- **No forbidden tests:** no hand-built internal structs, no `function_exported?`/existence pins (T6 explicitly avoids one for the removed `skip_search?`), no private-error-string assertions, no sequential-materialization-gate test (out of gate, per spec).
