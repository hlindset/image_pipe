defmodule ImagePipe.BitDepthTest do
  use ExUnit.Case, async: true

  alias ImagePipe.BitDepth
  alias Vix.Vips.Image, as: VixImage
  alias Vix.Vips.Operation

  test "narrows every 16-bit value to round(v / 257)" do
    expected = for v <- 0..65_535, into: <<>>, do: <<round(v / 257)::8>>

    for {bands, interpretation} <- [{1, :VIPS_INTERPRETATION_B_W}, {3, :VIPS_INTERPRETATION_sRGB}] do
      {:ok, narrow} = BitDepth.narrow_to_8_bits(every_value(bands))

      assert VixImage.format(narrow) == :VIPS_FORMAT_UCHAR
      assert VixImage.interpretation(narrow) == interpretation
      {:ok, band} = Operation.extract_band(narrow, bands - 1)
      assert VixImage.write_to_binary(band) == {:ok, expected}
    end
  end

  test "returns an 8-bit image unchanged" do
    {:ok, image} = Operation.black(4, 4, bands: 3)
    {:ok, image} = Operation.cast(image, :VIPS_FORMAT_UCHAR)
    assert BitDepth.narrow_to_8_bits(image) == {:ok, image}
  end

  # A 65536 × 1 image holding each 16-bit value once, in every band.
  defp every_value(bands) do
    row = for v <- 0..65_535, into: <<>>, do: <<v::native-16>>
    {:ok, image} = VixImage.new_from_binary(row, 65_536, 1, 1, :VIPS_FORMAT_USHORT)
    {:ok, image} = Operation.bandjoin(List.duplicate(image, bands))
    image
  end
end
