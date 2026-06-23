defmodule ImagePipe.Output.ContentClassifierTest do
  use ExUnit.Case, async: true

  alias ImagePipe.Output.ContentClassifier
  alias Vix.Vips.Operation

  # A continuous-tone field: a full-range luminance ramp (high palette entropy)
  # plus softly-blurred noise (abundant mid-band gradient, high nat_var) → :photo.
  # Both features land near the photo extreme, well clear of any plausible
  # threshold, so the verdict is robust to the exact pinned constants.
  defp photo_image do
    side = 512
    {:ok, xyz} = Operation.xyz(side, side)
    {:ok, x} = Operation.extract_band(xyz, 0)
    {:ok, ramp} = Operation.linear(x, [255.0 / (side - 1)], [0.0])
    {:ok, noise} = Operation.gaussnoise(side, side, sigma: 35, mean: 0, seed: 1)
    {:ok, blurred} = Operation.gaussblur(noise, 1.2)
    {:ok, sum} = Operation.add(ramp, blurred)
    {:ok, uchar} = Operation.cast(sum, :VIPS_FORMAT_UCHAR)
    {:ok, gray} = Operation.copy(uchar, interpretation: :VIPS_INTERPRETATION_B_W)
    {:ok, rgb} = Operation.bandjoin([gray, gray, gray])
    {:ok, srgb} = Operation.copy(rgb, interpretation: :VIPS_INTERPRETATION_sRGB)
    srgb
  end

  # A hard-edged two-tone field (line-art surrogate): a white canvas overlaid with
  # a fine black line grid → two luminance values (low palette entropy) + all-hard
  # edges (near-zero mid-band) → :graphic. Built with Image.Draw, not Operation.grid.
  defp graphic_image do
    side = 512
    base = Image.new!(side, side, color: :white)

    drawn =
      Enum.reduce(0..(side - 1)//8, base, fn x, acc ->
        acc
        |> Image.Draw.rect!(x, 0, 1, side, color: :black)
        |> Image.Draw.rect!(0, x, side, 1, color: :black)
      end)

    Image.to_colorspace!(drawn, :srgb)
  end

  test "classifies a continuous-tone field as :photo" do
    assert {:photo, %{palette_ent: pe, nat_var: nv}} = ContentClassifier.classify(photo_image())
    assert is_float(pe) and is_float(nv)
  end

  test "classifies a hard-edged two-tone field as :graphic" do
    assert {:graphic, _features} = ContentClassifier.classify(graphic_image())
  end

  test "falls back to :graphic on a degenerate 1x1 input (no raise)" do
    {:ok, tiny} = Operation.black(1, 1)
    {:ok, srgb} = Operation.copy(tiny, interpretation: :VIPS_INTERPRETATION_sRGB)
    assert {:graphic, _features} = ContentClassifier.classify(srgb)
  end
end
