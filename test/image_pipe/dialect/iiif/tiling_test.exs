defmodule ImagePipe.Dialect.IIIF.TilingTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias ImagePipe.Dialect.IIIF.Tiling

  test "Cantaloupe reference: 1500x1200, tile 512" do
    result = Tiling.tiles_and_sizes(1500, 1200, 512)

    assert result.scale_factors == [1, 2, 4, 8, 16]
    assert result.tile == %{width: 512, height: 512}
    # round (half-up for positive), smallest-first, full last.
    # 1500/16 = 93.75 -> 94 (floor would give 93 -> proves round).
    assert result.sizes == [
             %{width: 94, height: 75},
             %{width: 188, height: 150},
             %{width: 375, height: 300},
             %{width: 750, height: 600},
             %{width: 1500, height: 1200}
           ]
  end

  test "source smaller than tile in a dimension: tile clamps to source" do
    result = Tiling.tiles_and_sizes(300, 200, 512)

    # short side 200 -> 100, 50<64 at i=1 -> maxRF=1
    assert result.scale_factors == [1, 2]
    assert result.tile == %{width: 300, height: 200}
    assert result.sizes == [%{width: 150, height: 100}, %{width: 300, height: 200}]
  end

  test "tiny sources collapse to a single level" do
    assert Tiling.tiles_and_sizes(64, 64, 512) == %{
             scale_factors: [1],
             tile: %{width: 64, height: 64},
             sizes: [%{width: 64, height: 64}]
           }

    assert Tiling.tiles_and_sizes(1, 1, 512) == %{
             scale_factors: [1],
             tile: %{width: 1, height: 1},
             sizes: [%{width: 1, height: 1}]
           }
  end

  test "extreme aspect ratio: ladder bounded by the short side" do
    # short side 65 -> 32.5<64 at i=0 -> maxRF=0 -> single level
    result = Tiling.tiles_and_sizes(2000, 65, 512)
    assert result.scale_factors == [1]
    assert result.sizes == [%{width: 2000, height: 65}]
    assert result.tile == %{width: 512, height: 65}
  end

  # Invariants that hold for ALL valid inputs. Deliberately does NOT assert the
  # `round(W/size.width) == sf` round-trip — that is FALSE for some inputs (round
  # then inverse-round can land on sf±1); OSD treats sizes as an optional hint and
  # falls back gracefully. Adoption is checked on fixtures below.
  #
  # Honesty note: the `sizes_match_factors` clause in ok?/4 recomputes
  # `round(w/sf)` exactly as the implementation does, so it is an algorithm-SHAPE
  # pin (catches floor/ceil/trunc or wrong-dimension regressions), NOT an
  # independent oracle of round-vs-floor correctness. The independent correctness
  # anchors are the hardcoded Cantaloupe reference-value tests above and the
  # tautology self-check below — not this clause.
  property "scale factors and sizes obey the universal invariants" do
    check all(
            w <- integer(1..8000),
            h <- integer(1..8000),
            t <- integer(1..2048),
            max_runs: 200
          ) do
      assert ok?(Tiling.tiles_and_sizes(w, h, t), w, h, t)
    end
  end

  test "tautology self-check: a floor-computed ladder is REJECTED by the invariants" do
    # Proves the invariant predicate can actually fail (not vacuously true): a
    # deliberately-wrong (floor instead of round) sizes list must not pass ok?/4.
    %{scale_factors: factors, tile: tile} = Tiling.tiles_and_sizes(1500, 1200, 512)

    wrong =
      %{
        scale_factors: factors,
        tile: tile,
        sizes:
          factors
          |> Enum.reverse()
          |> Enum.map(fn sf -> %{width: floor(1500 / sf), height: floor(1200 / sf)} end)
      }

    # floor gives 93x75 for sf=16 where round gives 94x75 -> invariant rejects it.
    refute ok?(wrong, 1500, 1200, 512)

    # A wrong (non-power-of-two) scale ladder is also rejected.
    bad_factors = %{Tiling.tiles_and_sizes(1500, 1200, 512) | scale_factors: [1, 3, 9]}
    refute ok?(bad_factors, 1500, 1200, 512)
  end

  test "OSD levelSizes adoption holds for representative sources" do
    for {w, h} <- [{1500, 1200}, {1024, 768}, {4000, 3000}] do
      assert osd_adopts?(Tiling.tiles_and_sizes(w, h, 512), w, h),
             "OSD would reject levelSizes for #{w}x#{h}"
    end
  end

  # --- helpers -------------------------------------------------------------

  # The universal invariants (see property doc above).
  defp ok?(%{scale_factors: factors, tile: tile, sizes: sizes}, w, h, t) do
    powers_of_two_from_one = factors == for(i <- 0..(length(factors) - 1), do: Integer.pow(2, i))
    same_length = length(sizes) == length(factors)
    widths_strictly_ascending = strictly_ascending?(Enum.map(sizes, & &1.width))
    largest_is_full = List.last(sizes) == %{width: w, height: h}
    tile_clamped = tile == %{width: min(t, w), height: min(t, h)}

    # Algorithm-SHAPE pin only (recomputes round(w/sf) identically to the
    # implementation): catches floor/ceil/trunc/wrong-dimension regressions.
    # Independent round-vs-floor correctness is pinned by the hardcoded reference
    # tests and the tautology self-check, NOT by this clause.
    sizes_match_factors =
      sizes ==
        factors
        |> Enum.reverse()
        |> Enum.map(fn sf -> %{width: round(w / sf), height: round(h / sf)} end)

    powers_of_two_from_one and same_length and widths_strictly_ascending and
      largest_is_full and tile_clamped and sizes_match_factors
  end

  defp strictly_ascending?(list), do: list == Enum.sort(list) and list == Enum.dedup(list)

  # OSD adopts `sizes` as levelSizes only if len == maxLevel+1, len(scaleFactors)
  # == len(sizes), and BOTH axes round-trip to the scale factor (factors reversed,
  # since sizes are smallest-first).
  defp osd_adopts?(%{scale_factors: factors, sizes: sizes}, w, h) do
    max_level = round(:math.log2(List.last(factors)))
    reversed = Enum.reverse(factors)

    length(sizes) == max_level + 1 and length(factors) == length(sizes) and
      sizes
      |> Enum.zip(reversed)
      |> Enum.all?(fn {s, sf} ->
        round(w / s.width) == sf and round(h / s.height) == sf
      end)
  end
end
