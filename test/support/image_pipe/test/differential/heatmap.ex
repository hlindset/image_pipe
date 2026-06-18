defmodule ImagePipe.Test.Differential.Heatmap do
  @moduledoc """
  Generic diff-image renderers for differential reports: given two SAME-dimension
  decoded images, produce banded-over-threshold and raw-amplified diff images.
  Informational only — never a gate. (The delta/outlier *metric* lives in
  `Differential.PixelCompare`; only the image-rendering half lives here.)
  """
  use Boundary, top_level?: true, deps: []

  alias Vix.Vips.Image, as: VixImage
  alias Vix.Vips.Operation

  @raw_amp 8

  # Banded: per-pixel max |Δ| across RGB → 256-entry LUT that dims pixels at/under
  # the case's own threshold and ramps over-threshold pixels hot.
  def banded_heatmap(a, b, threshold) do
    delta = abs_diff(a, b)
    maxd = band_max(delta)
    idx = ok!(Operation.cast(maxd, :VIPS_FORMAT_UCHAR))
    ok!(Operation.maplut(idx, heat_lut(threshold)))
  end

  # Raw: |Δ| amplified for visibility, clamped to uchar (no threshold).
  def raw_heatmap(a, b) do
    delta = abs_diff(a, b)
    amped = ok!(Operation.linear(delta, [@raw_amp * 1.0], [0.0]))
    ok!(Operation.cast(amped, :VIPS_FORMAT_UCHAR))
  end

  # Normalized: per-pixel max |Δ| contrast-stretched to THIS frame's own peak
  # (`Operation.scale` maps min→0, max→255), so a diffuse, low-magnitude divergence
  # (e.g. the scp0 colorspace case) fills the dynamic range and is visible where the
  # banded/raw maps render near-black. Magnitudes are NOT comparable across cards —
  # each is self-scaled. `scale` is safe on an all-equal frame (no divide-by-zero).
  def normalized_heatmap(a, b) do
    delta = abs_diff(a, b)
    maxd = band_max(delta)
    idx = ok!(Operation.cast(ok!(Operation.scale(maxd)), :VIPS_FORMAT_UCHAR))
    ok!(Operation.maplut(idx, heat_lut(0)))
  end

  def png(image), do: Image.write!(image, :memory, suffix: ".png")

  # subtract promotes uchar→signed short (no wrap); abs makes it non-negative.
  defp abs_diff(a, b), do: ok!(Operation.abs(ok!(Operation.subtract(a, b))))

  defp band_max(delta) do
    b0 = ok!(Operation.extract_band(delta, 0))
    b1 = ok!(Operation.extract_band(delta, 1))
    b2 = ok!(Operation.extract_band(delta, 2))
    ok!(Operation.maxpair(ok!(Operation.maxpair(b0, b1)), b2))
  end

  # 256×1 3-band uchar LUT: indices ≤ threshold → dim; above → cool→hot ramp.
  defp heat_lut(threshold) do
    bin =
      for i <- 0..255, into: <<>> do
        if i <= threshold do
          <<24, 24, 28>>
        else
          t = (i - threshold) / max(255 - threshold, 1)
          <<round(60 + t * 195), round(20 + t * 60), round(40 - t * 40)>>
        end
      end

    ok!(VixImage.new_from_binary(bin, 256, 1, 3, :VIPS_FORMAT_UCHAR))
  end

  defp ok!({:ok, value}), do: value
  defp ok!({:error, reason}), do: raise("vips operation failed: #{inspect(reason)}")
end
