defmodule ImagePipe.Test.Autoquality.TileSelectionTest do
  @moduledoc """
  Unit tests for the benchmark-only tile selectors (`--part f`). The experiment's
  conclusions about whether saliency selection can retire the full-frame confirm
  hinge on these selectors picking the tiles they claim to, so the non-trivial
  logic (spatial suppression, mixed dedup, signal ranking) is pinned here.
  """
  use ExUnit.Case, async: true

  alias ImagePipe.Test.Autoquality.TileSelection

  # A regular 4×4 grid of 10×10 tiles (16 tiles). `signals` overrides per-cell.
  defp grid(signals \\ %{}) do
    for row <- 0..3, col <- 0..3 do
      sig = Map.get(signals, {col, row}, %{})

      %{
        x: col * 10,
        y: row * 10,
        w: 10,
        h: 10,
        source_detail: Map.get(sig, :source_detail, 0.0),
        diff: Map.get(sig, :diff, 0.0),
        diff_detail: Map.get(sig, :diff_detail, 0.0)
      }
    end
  end

  defp coords(tiles), do: Enum.map(tiles, &{&1.x, &1.y})

  describe "n <= k" do
    test "every strategy returns all tiles when k >= n" do
      tiles = grid()

      for strategy <- [:even, :source_detail, :mixed, :diff_aware] do
        assert length(TileSelection.select(tiles, 16, strategy)) == 16
        assert length(TileSelection.select(tiles, 20, strategy)) == 16
      end
    end
  end

  describe "common invariants" do
    test "every strategy returns exactly k unique tiles for k < n" do
      tiles =
        grid(%{
          {0, 0} => %{source_detail: 9.0, diff: 9.0},
          {3, 3} => %{source_detail: 8.0, diff: 1.0},
          {2, 1} => %{source_detail: 7.0, diff: 8.0}
        })

      for strategy <- [:even, :source_detail, :mixed, :diff_aware], k <- [4, 8, 12] do
        selected = TileSelection.select(tiles, k, strategy)
        assert length(selected) == k, "#{strategy} k=#{k} returned #{length(selected)}"
        assert length(Enum.uniq(coords(selected))) == k, "#{strategy} k=#{k} had duplicates"
      end
    end
  end

  describe ":even" do
    test "spans both endpoints (first and last tile included)" do
      tiles = grid()
      selected = coords(TileSelection.select(tiles, 4, :even))
      assert {0, 0} in selected
      assert {30, 30} in selected
    end

    test "matches the existing index-spanning subsample semantics" do
      tiles = grid()
      # K=4 over 16 → indices 0, 5, 10, 15 (div(i*15, 3)).
      expected = [0, 5, 10, 15] |> Enum.map(&Enum.at(tiles, &1)) |> coords()
      assert coords(TileSelection.select(tiles, 4, :even)) == expected
    end
  end

  describe ":source_detail" do
    test "picks the highest-source-detail tile first" do
      tiles = grid(%{{2, 2} => %{source_detail: 100.0}})
      assert {20, 20} in coords(TileSelection.select(tiles, 1, :source_detail))
    end

    test "spatial suppression skips an adjacent runner-up for a distant tile" do
      # Two orthogonally-adjacent hot tiles and one distant warm tile. With k=2 and
      # suppression, the distant warm tile beats the adjacent runner-up.
      tiles =
        grid(%{
          {0, 0} => %{source_detail: 100.0},
          {1, 0} => %{source_detail: 90.0},
          {3, 3} => %{source_detail: 50.0}
        })

      selected = coords(TileSelection.select(tiles, 2, :source_detail))
      assert {0, 0} in selected
      assert {30, 30} in selected
      refute {10, 0} in selected
    end
  end

  describe ":mixed" do
    test "includes both coverage (endpoints) and a high-detail tile" do
      tiles = grid(%{{2, 1} => %{source_detail: 100.0}})
      selected = coords(TileSelection.select(tiles, 4, :mixed))
      # Coverage half spans endpoints; detail half pulls in the hot tile.
      assert {0, 0} in selected
      assert {20, 10} in selected
    end
  end

  describe ":diff_aware" do
    test "pulls in a high-diff tile that source-detail alone would ignore" do
      # A smooth tile (no source detail) with a large encode difference — the
      # banding-in-smooth case source-only selection misses.
      tiles =
        grid(%{
          {0, 0} => %{source_detail: 50.0},
          {3, 0} => %{source_detail: 50.0},
          {0, 3} => %{source_detail: 50.0},
          {2, 2} => %{source_detail: 0.0, diff: 100.0, diff_detail: 100.0}
        })

      source_only = coords(TileSelection.select(tiles, 4, :source_detail))
      diff_aware = coords(TileSelection.select(tiles, 6, :diff_aware))

      refute {20, 20} in source_only
      assert {20, 20} in diff_aware
    end
  end
end
