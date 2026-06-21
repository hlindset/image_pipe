defmodule ImagePipe.Output.Ssim2Metric.CropScorePropertyTest do
  @moduledoc """
  Property invariants for the pure crop-scoring geometry. Tiling, sub-sampling and
  the p10 percentile are order/coverage-sensitive, so these assert the invariants
  that must hold across many frame shapes and list sizes regardless of the exact
  values (#354): full coverage with no gap, endpoint-preserving sub-sampling, and a
  monotone floor-indexed percentile.
  """
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias ImagePipe.Output.Ssim2Metric.CropScore

  property "tile_coords fully covers the frame with full-size, edge-clamped tiles (no gap)" do
    check all(
            w <- integer(1..6000),
            h <- integer(1..6000),
            t <- member_of([16, 64, 256, 512, 1000])
          ) do
      coords = CropScore.tile_coords(w, h, t)
      tw = min(t, w)
      th = min(t, h)

      # Every tile is a full tw×th window (safe for SSIMULACRA2 multiscale).
      assert Enum.all?(coords, fn {_x, _y, cw, ch} -> cw == tw and ch == th end)

      xs = coords |> Enum.map(&elem(&1, 0)) |> Enum.uniq() |> Enum.sort()
      ys = coords |> Enum.map(&elem(&1, 1)) |> Enum.uniq() |> Enum.sort()

      assert_axis_coverage(xs, tw, w)
      assert_axis_coverage(ys, th, h)
    end
  end

  # Starts at 0, the last window reaches the edge, and consecutive windows never
  # leave a gap (overlap is allowed).
  defp assert_axis_coverage(positions, tile, size) do
    assert hd(positions) == 0
    assert Enum.max(positions) + tile == size

    positions
    |> Enum.chunk_every(2, 1, :discard)
    |> Enum.each(fn [a, b] -> assert b - a <= tile end)
  end

  property "subsample keeps <= k items, preserves order, and keeps both endpoints when it cuts" do
    check all(
            n <- integer(1..400),
            k <- integer(1..32)
          ) do
      items = Enum.to_list(0..(n - 1))
      sub = CropScore.subsample(items, k)

      assert length(sub) == min(n, k)
      # values == indices, so order preservation == a non-decreasing result.
      assert sub == Enum.sort(sub)

      cond do
        n <= k -> assert sub == items
        # A single sample can't span both ends — it keeps the leading item.
        k == 1 -> assert sub == [hd(items)]
        true -> assert hd(sub) == hd(items) and List.last(sub) == List.last(items)
      end
    end
  end

  property "percentile is a member, hits both ends, and is non-decreasing in p" do
    check all(
            values <- list_of(float(min: -1000.0, max: 1000.0), min_length: 1, max_length: 200),
            [p_lo, p_hi] <- list_of(float(min: 0.0, max: 1.0), length: 2) |> map(&Enum.sort/1)
          ) do
      sorted = Enum.sort(values)

      assert CropScore.percentile(sorted, 0.0) == hd(sorted)
      assert CropScore.percentile(sorted, 1.0) == List.last(sorted)

      lo = CropScore.percentile(sorted, p_lo)
      hi = CropScore.percentile(sorted, p_hi)

      assert lo in sorted
      assert hi in sorted
      assert lo <= hi
    end
  end
end
