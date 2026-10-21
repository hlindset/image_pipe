defmodule ImagePipe.BitDepth do
  # Workaround for libvips 8.18: it narrows 16-bit values to 8 bits by
  # shifting right 8, so 65400 (254.47 levels) becomes 255 and 64 × 257
  # becomes 63, one level off for about a quarter of values. Narrowing here
  # divides by 257 and rounds. Shared by input conditioning and the encoder.
  @moduledoc false

  use Boundary, top_level?: true, deps: [], exports: []

  alias Vix.Vips.Image, as: VixImage
  alias Vix.Vips.Operation

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

        with {:ok, scaled} <- Operation.linear(image, [1 / 257], [0.0]),
             {:ok, rounded} <- Operation.round(scaled, :VIPS_OPERATION_ROUND_RINT),
             {:ok, narrow} <- Operation.cast(rounded, :VIPS_FORMAT_UCHAR) do
          Operation.copy(narrow, interpretation: interpretation)
        end

      _other ->
        {:ok, image}
    end
  end
end
