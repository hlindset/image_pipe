defmodule ImagePipe.Transform.GrayFrame do
  # Grayscale frames meeting color. A color that isn't a neutral gray (an opaque
  # background, a color watermark) promotes a B_W frame to sRGB and a GREY16
  # frame to RGB16, keeping its alpha band, so the color survives instead of
  # being reduced to its gray value.
  @moduledoc false

  alias Vix.Vips.Image, as: VipsImage
  alias Vix.Vips.Operation

  @gray [:VIPS_INTERPRETATION_B_W, :VIPS_INTERPRETATION_GREY16]

  @spec gray?(VipsImage.t()) :: boolean()
  def gray?(image), do: VipsImage.interpretation(image) in @gray

  @spec promote(VipsImage.t()) :: {:ok, VipsImage.t()} | {:error, term()}
  def promote(image) do
    case VipsImage.interpretation(image) do
      :VIPS_INTERPRETATION_B_W -> Operation.colourspace(image, :VIPS_INTERPRETATION_sRGB)
      :VIPS_INTERPRETATION_GREY16 -> Operation.colourspace(image, :VIPS_INTERPRETATION_RGB16)
      _other -> {:ok, image}
    end
  end
end
