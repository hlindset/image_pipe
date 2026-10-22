defmodule ImagePipe.BitDepth do
  # Workaround for libvips 8.18: it narrows 16-bit values to 8 bits by
  # shifting right 8, so 65400 (254.47 levels) becomes 255 and 64 × 257
  # becomes 63, one level off for about a quarter of values. Narrowing here
  # divides by 257 and rounds, through a lookup table: 257 is odd, so no
  # value falls halfway between two levels. Shared by input conditioning and
  # the encoder.
  @moduledoc false

  use Boundary, top_level?: true, deps: [], exports: []

  alias Vix.Vips.Image, as: VixImage
  alias Vix.Vips.Operation

  @lut for v <- 0..65_535, into: <<>>, do: <<round(v / 257)::8>>

  @doc """
  Narrows a 16-bit image to 8 bits by rounding `v / 257`, tagging it sRGB, or
  B_W below 3 bands. Returns other band formats unchanged.
  """
  @spec narrow_to_8_bits(VixImage.t()) :: {:ok, VixImage.t()} | {:error, term()}
  def narrow_to_8_bits(image) do
    case VixImage.format(image) do
      :VIPS_FORMAT_USHORT ->
        interpretation =
          if VixImage.bands(image) < 3,
            do: :VIPS_INTERPRETATION_B_W,
            else: :VIPS_INTERPRETATION_sRGB

        with {:ok, lut} <- VixImage.new_from_binary(@lut, 65_536, 1, 1, :VIPS_FORMAT_UCHAR),
             {:ok, narrow} <- Operation.maplut(image, lut) do
          Operation.copy(narrow, interpretation: interpretation)
        end

      _other ->
        {:ok, image}
    end
  end
end
