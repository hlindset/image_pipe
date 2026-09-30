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
  end
end
