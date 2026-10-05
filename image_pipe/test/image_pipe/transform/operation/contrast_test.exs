defmodule ImagePipe.Transform.Operation.ContrastTest do
  use ExUnit.Case, async: true

  alias ImagePipe.Transform.Operation.Contrast
  alias ImagePipe.Transform.State
  alias Vix.Vips.Image, as: VipsImage
  alias Vix.Vips.Operation

  test "contrast of 1.0 is identity" do
    assert contrast([80, 80, 80], 1.0) == [80, 80, 80]
  end

  test "contrast pivots on the middle of the 0 to 255 scale" do
    assert contrast([128, 128, 128], 2.0) == [128, 128, 128]
    assert contrast([64, 64, 64], 2.0) == [0, 0, 0]
    assert contrast([192, 192, 192], 2.0) == [255, 255, 255]
    assert contrast([64, 128, 192], 1.25) == [48, 128, 208]
    assert contrast([64, 128, 192], 0.5) == [96, 128, 160]
  end

  test "contrast leaves alpha unchanged" do
    assert contrast([64, 128, 192, 100], 2.0) == [0, 128, 255, 100]
  end

  test "a 16-bit image pivots on the same fraction of its range" do
    {:ok, black} = Operation.black(4, 4, bands: 3)
    {:ok, image} = Operation.linear(black, [1.0], [16_448.0, 32_896.0, 49_344.0])
    {:ok, image} = Operation.cast(image, :VIPS_FORMAT_USHORT)
    {:ok, image} = Operation.copy(image, interpretation: :VIPS_INTERPRETATION_RGB16)

    {:ok, %State{image: out}} = Contrast.execute(%Contrast{value: 2.0}, %State{image: image})

    assert VipsImage.format(out) == :VIPS_FORMAT_USHORT
    assert List.flatten(VipsImage.get_pixel!(out, 0, 0)) == [0, 32_896, 65_535]
  end

  defp contrast(color, value) do
    image = Image.new!(4, 4, color: color, bands: length(color))
    {:ok, %State{image: out}} = Contrast.execute(%Contrast{value: value}, %State{image: image})
    List.flatten(VipsImage.get_pixel!(out, 0, 0))
  end
end
