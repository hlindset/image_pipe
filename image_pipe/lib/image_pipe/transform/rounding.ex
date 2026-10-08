defmodule ImagePipe.Transform.Rounding do
  # Casts float pixel math back to the image's band format.
  #
  # libvips' cast truncates, so 119.9998 becomes 119 and a colour that went
  # through float math, such as premultiplied filtering or a blend, loses a
  # level. Rounding to the nearest integer first keeps it.
  @moduledoc false

  alias Vix.Vips.Image, as: VipsImage
  alias Vix.Vips.Operation

  @spec cast(VipsImage.t(), atom()) :: {:ok, VipsImage.t()} | {:error, term()}
  def cast(image, format) when format in [:VIPS_FORMAT_FLOAT, :VIPS_FORMAT_DOUBLE],
    do: Operation.cast(image, format)

  def cast(image, format) do
    case VipsImage.format(image) do
      float when float in [:VIPS_FORMAT_FLOAT, :VIPS_FORMAT_DOUBLE] ->
        with {:ok, rounded} <- Operation.round(image, :VIPS_OPERATION_ROUND_RINT),
             do: Operation.cast(rounded, format)

      _integer ->
        Operation.cast(image, format)
    end
  end
end
