defmodule ImagePipe.Differential.PixelCompareTest do
  use ExUnit.Case, async: true

  alias ImagePipe.Test.Differential.PixelCompare
  alias Vix.Vips.Operation

  defp img(w, h, color), do: Image.new!(w, h, color: color)

  # A 1-band USHORT image filled with a single value, for exact 16-bit-delta control.
  defp u16_const(w, h, value) do
    {:ok, base} = Operation.black(w, h)
    base |> Operation.linear!([0.0], [value * 1.0]) |> Image.cast!({:u, 16})
  end

  describe "dims/1" do
    test "returns width and height" do
      assert PixelCompare.dims(img(7, 3, :black)) == {7, 3}
    end
  end

  describe "same_dims?/2" do
    test "true for equal dims, false otherwise" do
      assert PixelCompare.same_dims?(img(4, 4, :black), img(4, 4, :white))
      refute PixelCompare.same_dims?(img(4, 4, :black), img(5, 4, :white))
    end
  end

  describe "outliers/3" do
    test "identical images have zero outliers" do
      a = img(16, 16, [10, 20, 30])
      assert PixelCompare.outliers(a, a, 0) == 0
    end

    test "a uniform per-channel offset below threshold is not an outlier" do
      a = img(16, 16, [10, 20, 30])
      b = img(16, 16, [12, 22, 32])
      assert PixelCompare.outliers(a, b, 2) == 0
      # 16x16 pixels x 3 bands; every band-byte exceeds Δ1 here.
      assert PixelCompare.outliers(a, b, 1) == 16 * 16 * 3
    end

    test "raises on mismatched dims" do
      assert_raise ArgumentError, fn ->
        PixelCompare.outliers(img(4, 4, :black), img(5, 4, :black), 0)
      end
    end
  end

  describe "fraction_over/3" do
    test "fraction of band-bytes exceeding the threshold" do
      a = img(16, 16, [10, 20, 30])
      b = img(16, 16, [12, 22, 32])
      # every band-byte differs by exactly 2: none exceed Δ2, all exceed Δ1
      assert PixelCompare.fraction_over(a, b, 2) == 0.0
      assert PixelCompare.fraction_over(a, b, 1) == 1.0
    end

    test "identical images have zero fraction" do
      a = img(16, 16, [10, 20, 30])
      assert PixelCompare.fraction_over(a, a, 0) == 0.0
    end
  end

  describe "spatial_contrast/1" do
    test "a spatially uniform image is zero regardless of its colour" do
      assert PixelCompare.spatial_contrast(img(16, 16, [0, 0, 0])) == 0.0

      # The load-bearing property: a uniform [200,180,60] fill has a *band-byte*
      # range of 140 (the cross-channel gamut) but zero spatial variation, so it must
      # read as 0 — proving we measure per-band spatial range, not band-byte range.
      assert PixelCompare.spatial_contrast(img(16, 16, [200, 180, 60])) == 0.0
    end

    test "a hard black/white edge reads near the full 0..255 range" do
      black = img(8, 16, [0, 0, 0])
      white = img(8, 16, [255, 255, 255])
      {:ok, edge} = Operation.join(black, white, :VIPS_DIRECTION_HORIZONTAL)

      assert_in_delta PixelCompare.spatial_contrast(edge), 255.0, 0.5
    end

    test "normalizes 16-bit images onto the same 0..255 scale" do
      # 255 cast to u16 stays 255; scale by 257 to reach the true 16-bit max (65535).
      to_u16 = fn image, scale ->
        image |> Operation.linear!([scale], [0.0]) |> Image.cast!({:u, 16})
      end

      lo = img(8, 16, [0, 0, 0]) |> to_u16.(1.0)
      hi = img(8, 16, [255, 255, 255]) |> to_u16.(257.0)
      {:ok, edge} = Operation.join(lo, hi, :VIPS_DIRECTION_HORIZONTAL)

      # a full-range 16-bit edge (Δ65535) normalizes to ~255, not ~65535
      assert_in_delta PixelCompare.spatial_contrast(edge), 255.0, 0.5
    end
  end

  describe "16-bit (USHORT) tolerance" do
    test "a sub-level 16-bit delta is judged in 8-bit-equivalent levels, not raw low bytes" do
      # raw Δ224/65535 ≈ 0.87 levels — the imgproxy opaque-alpha perturbation (#229).
      # The low byte differs by 224, which a byte-wise comparison flags as a massive
      # Δ224 outlier; reconstructed in USHORT space the sample is below Δ2.
      a = u16_const(16, 16, 30_000)
      b = u16_const(16, 16, 30_224)

      assert PixelCompare.outliers(a, b, 2) == 0
      assert PixelCompare.fraction_over(a, b, 2) == 0.0
    end

    test "a genuine 16-bit structural delta still trips the tolerance (anti-tautology)" do
      # raw Δ32768 ≈ 127 levels — a real blow-out must stay visible, so the 16-bit
      # path cannot pass simply by ignoring high bytes. One band → one sample per
      # pixel, so the count is per-sample (256), not per-byte (512).
      a = u16_const(16, 16, 20_000)
      b = u16_const(16, 16, 52_768)

      assert PixelCompare.outliers(a, b, 2) == 16 * 16
      assert PixelCompare.fraction_over(a, b, 2) == 1.0
    end

    test "diagnose reports a sub-level 16-bit delta in 8-bit-equivalent levels" do
      a = u16_const(8, 8, 10_000)
      b = u16_const(8, 8, 10_224)
      d = PixelCompare.diagnose(a, b)

      # round(224 / 257) == 1 level; nothing exceeds Δ2.
      assert d.max_delta == 1
      assert d.over == %{2 => 0, 16 => 0, 32 => 0}
    end

    test "diagnose surfaces a structural 16-bit delta above every level threshold" do
      a = u16_const(8, 8, 10_000)
      b = u16_const(8, 8, 42_768)
      d = PixelCompare.diagnose(a, b)

      # round(32768 / 257) == 128 levels; every sample exceeds Δ2/Δ16/Δ32.
      assert d.max_delta == 128
      assert d.over == %{2 => 8 * 8, 16 => 8 * 8, 32 => 8 * 8}
    end
  end

  describe "structural_outliers/3" do
    # A 1-band grayscale image from horizontally-joined solid column blocks, each
    # `{width, value}`. Lets us author exact vertical-edge geometry for the
    # neighborhood-range math.
    defp columns(blocks, height) do
      blocks
      |> Enum.map(fn {w, v} -> img(w, height, [v]) end)
      |> Enum.reduce(fn block, acc -> Operation.join!(acc, block, :VIPS_DIRECTION_HORIZONTAL) end)
    end

    test "identical images have no structural outliers" do
      a = columns([{4, 50}, {4, 200}], 8)
      assert PixelCompare.structural_outliers(a, a) == 0
    end

    test "a haloed (antialiased) edge is neighborhood-explainable → ~0" do
      # reference: sharp vertical edge between col 3 and 4 (50 | 200)
      ref = columns([{4, 50}, {4, 200}], 8)
      # test image: the two boundary columns are a 125 blend of their neighbours —
      # every differing sample lies inside [local_min, local_max] of the reference.
      test = columns([{3, 50}, {2, 125}, {3, 200}], 8)

      assert PixelCompare.structural_outliers(test, ref) == 0
    end

    test "a ≥2px hard shift produces out-of-range samples → non-zero" do
      # reference edge between col 3 and 4; test edge shifted 3px right (between 6 and 7).
      # The interior shifted columns (5, 6) are wholly the wrong colour: their reference
      # neighborhood is uniformly 200, so a value of 50 falls outside it.
      ref = columns([{4, 50}, {4, 200}], 8)
      test = columns([{7, 50}, {1, 200}], 8)

      assert PixelCompare.structural_outliers(test, ref) > 0
    end

    test "overshoot within ε is not structural; beyond ε is" do
      ref = columns([{4, 50}, {4, 200}], 8)
      # a single boundary column that overshoots the neighborhood max (200) by 6 levels
      within = columns([{3, 50}, {1, 206}, {4, 200}], 8)
      assert PixelCompare.structural_outliers(within, ref, overshoot: 8) == 0
      # tighten ε below the overshoot → the same sample now reads as structural
      assert PixelCompare.structural_outliers(within, ref, overshoot: 2) > 0
    end
  end

  describe "classify_divergence/3" do
    # out=[10,20,30] vs fixture=[30,40,50]: every band-sample differs by exactly 20,
    # so max_delta == 20 and over[2] == 16*16*3 == 768.
    defp diverging_pair, do: {img(16, 16, [10, 20, 30]), img(16, 16, [30, 40, 50])}

    test ":ok when both metrics fall inside their bands" do
      {out, fixture} = diverging_pair()

      assert PixelCompare.classify_divergence(out, fixture, %{
               reason: "test",
               max_delta: 10..30,
               outliers: 700..800
             }) == :ok
    end

    test "max_delta below the floor → :below_floor (promote signal)" do
      {out, fixture} = diverging_pair()

      assert {:error, :below_floor, %{metric: :max_delta, value: 20, band: 50..100}} =
               PixelCompare.classify_divergence(out, fixture, %{
                 reason: "test",
                 max_delta: 50..100,
                 outliers: 700..800
               })
    end

    test "max_delta above the ceiling → :above_ceiling (regression)" do
      {out, fixture} = diverging_pair()

      assert {:error, :above_ceiling, %{metric: :max_delta, value: 20, band: 0..10}} =
               PixelCompare.classify_divergence(out, fixture, %{
                 reason: "test",
                 max_delta: 0..10,
                 outliers: 700..800
               })
    end

    test "outlier count out of band is reported with the outliers metric" do
      {out, fixture} = diverging_pair()

      assert {:error, :below_floor, %{metric: :outliers, value: 768, band: 1000..2000}} =
               PixelCompare.classify_divergence(out, fixture, %{
                 reason: "test",
                 max_delta: 10..30,
                 outliers: 1000..2000
               })
    end
  end

  describe "diagnose/3" do
    test "identical images: comparable, zero max delta, empty histogram" do
      a = img(16, 16, [10, 20, 30])
      d = PixelCompare.diagnose(a, a)

      assert d.comparable
      assert d.dims == {{16, 16}, {16, 16}}
      assert d.bands == {3, 3}
      assert d.max_delta == 0
      assert d.over == %{2 => 0, 16 => 0, 32 => 0}
    end

    test "reports max delta and per-threshold band-byte counts" do
      a = img(16, 16, [10, 20, 30])
      b = img(16, 16, [30, 40, 50])
      d = PixelCompare.diagnose(a, b)

      # every band-byte differs by exactly 20
      assert d.max_delta == 20
      assert d.over == %{2 => 16 * 16 * 3, 16 => 16 * 16 * 3, 32 => 0}
    end

    test "honors a custom threshold list" do
      a = img(8, 8, [10, 10, 10])
      b = img(8, 8, [25, 25, 25])
      d = PixelCompare.diagnose(a, b, [10, 20])

      assert d.max_delta == 15
      assert d.over == %{10 => 8 * 8 * 3, 20 => 0}
    end

    test "band-layout mismatch: not comparable, bands reported, no delta math" do
      rgb = img(4, 4, [0, 0, 0])
      rgba = Image.add_alpha!(rgb, :opaque)
      assert Image.bands(rgba) == 4

      d = PixelCompare.diagnose(rgb, rgba)

      refute d.comparable
      assert d.bands == {3, 4}
      assert d.dims == {{4, 4}, {4, 4}}
      assert d.max_delta == nil
      assert d.over == %{}
    end

    test "dimension mismatch: not comparable, dims reported, no delta math" do
      d = PixelCompare.diagnose(img(4, 4, :black), img(5, 4, :black))

      refute d.comparable
      assert d.dims == {{4, 4}, {5, 4}}
      assert d.max_delta == nil
    end
  end
end
