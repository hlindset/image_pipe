defmodule ImagePipe.Test.Autoquality.TileSelection do
  @moduledoc """
  Benchmark-only tile selectors for `mix autoquality.bench --part f`.

  Part E ships even-spaced K-tile sub-sampling (`ImagePipe.Output.Ssim2Metric.CropScore`).
  Part F asks whether a *saliency-guided* selection tracks the full-frame score
  tightly enough to retire the full-frame confirm gate (see
  `docs/autoquality_benchmark.md`). This module is the pure selection core: given a
  list of tiles carrying cheap per-tile signals, return the K to score.

  A tile is a map with `:x, :y, :w, :h` (pixel window) plus the cheap signals
  `:source_detail` (edge energy of the *source* tile — candidate-independent),
  `:diff` (mean |source − candidate|) and `:diff_detail` (edge energy of that
  difference). `:diff`/`:diff_detail` depend on the candidate, so any selector
  using them is candidate-dependent (per-probe in a real search) — an upper bound,
  not a production-plausible selector.

  Strategies:

    * `:even` — index-spanning sub-sample (the shipped Part E baseline).
    * `:source_detail` — top-K by `source_detail` with spatial suppression
      (candidate-independent; computable once per source).
    * `:mixed` — half even coverage + half `source_detail` (candidate-independent).
    * `:diff_aware` — coverage + source-detail + high-diff + smooth-but-high-diff
      (candidate-dependent upper bound).

  Every strategy returns exactly `min(k, length(tiles))` unique tiles. Spatial
  suppression and per-group quotas can leave a strategy short of its quota on a
  small or clustered grid; a final fill pass (suppression relaxed) tops up to `k`
  from a global `source_detail` ranking so the scored sample size is always `k`.
  """
  use Boundary, top_level?: true, deps: []

  @type tile :: %{
          :x => non_neg_integer(),
          :y => non_neg_integer(),
          :w => pos_integer(),
          :h => pos_integer(),
          :source_detail => float(),
          :diff => float(),
          :diff_detail => float(),
          optional(any()) => any()
        }

  @type strategy :: :even | :source_detail | :mixed | :diff_aware

  @doc """
  Select `k` tiles from `tiles` using `strategy`. `opts[:suppress_radius]` sets the
  minimum center-to-center distance for spatial suppression (default: one tile
  width), so orthogonally adjacent tiles suppress each other but diagonal neighbors
  do not.
  """
  @spec select([tile()], pos_integer(), strategy(), keyword()) :: [tile()]
  def select(tiles, k, strategy, opts \\ [])

  def select(tiles, k, _strategy, _opts) when length(tiles) <= k, do: tiles

  def select(tiles, k, :even, _opts), do: even_pick(tiles, k)

  def select(tiles, k, :source_detail, opts) do
    radius = suppress_radius(tiles, opts)
    ranked = Enum.sort_by(tiles, & &1.source_detail, :desc)

    []
    |> greedy_pick(ranked, k, radius)
    |> fill_to_k(tiles, k)
  end

  def select(tiles, k, :mixed, opts) do
    radius = suppress_radius(tiles, opts)
    cov_k = div(k, 2)
    coverage = even_pick(tiles, cov_k)
    detail_ranked = Enum.sort_by(tiles, & &1.source_detail, :desc)

    coverage
    |> greedy_pick(detail_ranked, k, radius)
    |> fill_to_k(tiles, k)
  end

  def select(tiles, k, :diff_aware, opts) do
    radius = suppress_radius(tiles, opts)
    %{even: ek, source: sk, diff: dk} = diff_aware_quotas(k)

    coverage = even_pick(tiles, ek)
    by_detail = Enum.sort_by(tiles, & &1.source_detail, :desc)
    by_diff = Enum.sort_by(tiles, & &1.diff, :desc)
    by_smooth_diff = smooth_high_diff_ranking(tiles)

    coverage
    |> greedy_pick(by_detail, ek + sk, radius)
    |> greedy_pick(by_diff, ek + sk + dk, radius)
    |> greedy_pick(by_smooth_diff, k, radius)
    |> fill_to_k(tiles, k)
  end

  # --- selection primitives -------------------------------------------------

  # Index-spanning sub-sample: `k` items spanning both endpoints (mirrors
  # ImagePipe.Output.Ssim2Metric.CropScore.subsample so `:even` is the shipped
  # baseline exactly).
  defp even_pick(tiles, k) do
    n = length(tiles)

    cond do
      n <= k -> tiles
      k <= 1 -> Enum.take(tiles, k)
      true -> Enum.map(0..(k - 1), &Enum.at(tiles, div(&1 * (n - 1), k - 1)))
    end
  end

  # Add tiles from `ranked` (best first) to `selected` until it reaches `target`,
  # skipping any already selected (by coordinate) or within `radius` of one. Stops
  # when `ranked` is exhausted even if short of `target` — `fill_to_k` tops up.
  defp greedy_pick(selected, ranked, target, radius) do
    Enum.reduce_while(ranked, selected, fn tile, acc ->
      cond do
        length(acc) >= target -> {:halt, acc}
        member?(acc, tile) -> {:cont, acc}
        suppressed?(acc, tile, radius) -> {:cont, acc}
        true -> {:cont, [tile | acc]}
      end
    end)
  end

  # Top up to exactly `k` from a global source_detail ranking, suppression relaxed,
  # so quotas/suppression can never leave the scored sample short of `k`.
  defp fill_to_k(selected, _all_tiles, k) when length(selected) >= k,
    do: selected |> Enum.reverse() |> Enum.take(k)

  defp fill_to_k(selected, all_tiles, k) do
    ranked = Enum.sort_by(all_tiles, & &1.source_detail, :desc)

    ranked
    |> Enum.reduce_while(selected, fn tile, acc ->
      cond do
        length(acc) >= k -> {:halt, acc}
        member?(acc, tile) -> {:cont, acc}
        true -> {:cont, [tile | acc]}
      end
    end)
    |> Enum.reverse()
  end

  # Smooth-but-changed: tiles at or below the median source_detail, ranked by diff
  # (the banding-in-smooth case source-detail selection misses).
  defp smooth_high_diff_ranking(tiles) do
    med = median(Enum.map(tiles, & &1.source_detail))

    tiles
    |> Enum.filter(&(&1.source_detail <= med))
    |> Enum.sort_by(& &1.diff, :desc)
  end

  defp diff_aware_quotas(k) do
    ek = round(0.5 * k)
    sk = round(0.25 * k)
    dk = round(0.125 * k)
    %{even: ek, source: sk, diff: dk, smooth: max(0, k - ek - sk - dk)}
  end

  defp member?(selected, tile),
    do: Enum.any?(selected, &(&1.x == tile.x and &1.y == tile.y))

  defp suppressed?(selected, tile, radius) do
    {cx, cy} = center(tile)

    Enum.any?(selected, fn s ->
      {sx, sy} = center(s)
      :math.sqrt(:math.pow(cx - sx, 2) + :math.pow(cy - sy, 2)) <= radius
    end)
  end

  defp center(%{x: x, y: y, w: w, h: h}), do: {x + w / 2, y + h / 2}

  defp suppress_radius(tiles, opts) do
    case Keyword.get(opts, :suppress_radius) do
      nil -> tiles |> Enum.map(& &1.w) |> Enum.max()
      r -> r
    end
  end

  defp median([]), do: 0.0

  defp median(values) do
    sorted = Enum.sort(values)
    n = length(sorted)
    mid = div(n, 2)

    if rem(n, 2) == 1,
      do: Enum.at(sorted, mid),
      else: (Enum.at(sorted, mid - 1) + Enum.at(sorted, mid)) / 2
  end
end
