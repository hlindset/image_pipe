defmodule ImagePipe.Output.Ssim2Metric.CropScore do
  @moduledoc """
  Crop-based (tiled) SSIMULACRA2 scoring for the autoquality search on large
  outputs. Above an internal ~6 MP crossover the search scores `@subsample_k`
  native-resolution 512px tiles of the full-res encode and takes their p10,
  instead of scoring the whole frame — a flat ~4.2 MP metric sample regardless of
  source size (issue #354, benchmark Part E).

  This module does tiling + `extract_area` only; **all** SSIMULACRA2 access is
  delegated to the parent `ImagePipe.Output.Ssim2Metric`, which stays the only
  module touching the SSIMULACRA2 NIF.
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
  How many tiles `p10/2` will actually score for a `w`×`h` frame — the sub-sampled
  tile count (`<= @subsample_k`). Deterministic from dimensions; used for the
  `tiles_scored` telemetry field without doing any scoring.
  """
  @spec tile_count(pos_integer(), pos_integer()) :: pos_integer()
  def tile_count(w, h), do: length(subsample(tile_coords(w, h)))

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
end
