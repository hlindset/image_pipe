defmodule ImagePipe.Output.Ssim2Metric.CropScoreTest do
  use ExUnit.Case, async: true

  alias ImagePipe.Output.Ssim2Metric.CropScore
  alias Vix.Vips.Operation

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

  describe "tile_count/2" do
    test "is the number of sub-sampled tiles actually scored (<= k)" do
      # 7 MP square (~2646px) tiles into a 6x6 grid = 36 tiles, sub-sampled to 16.
      assert CropScore.tile_count(2646, 2646) == 16
      # A small frame just over one tile on one axis: full count below k.
      assert CropScore.tile_count(1100, 600) == 6
    end
  end

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
end
