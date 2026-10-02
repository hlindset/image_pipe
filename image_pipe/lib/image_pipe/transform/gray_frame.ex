defmodule ImagePipe.Transform.GrayFrame do
  # Grayscale frames meeting color. A color that isn't a neutral gray (an opaque
  # background, a color watermark) promotes a B_W frame to sRGB and a GREY16
  # frame to RGB16, keeping its alpha band, so the color survives instead of
  # being reduced to its gray value.
  @moduledoc false

  alias ImagePipe.Transform.WorkingColor
  alias Vix.Vips.Image, as: VipsImage
  alias Vix.Vips.Operation

  @gray [:VIPS_INTERPRETATION_B_W, :VIPS_INTERPRETATION_GREY16]

  @spec gray?(VipsImage.t()) :: boolean()
  def gray?(image), do: VipsImage.interpretation(image) in @gray

  @doc "Promotes a gray image for a color that isn't a neutral gray."
  @spec for_color(VipsImage.t(), [number()]) :: {:ok, VipsImage.t()} | {:error, term()}
  def for_color(image, rgb) do
    if gray?(image) and not WorkingColor.neutral?(rgb), do: promote(image), else: {:ok, image}
  end

  # A gray profile can't describe RGB values, so a tagged gray image converts
  # through its profile instead.
  @spec promote(VipsImage.t()) :: {:ok, VipsImage.t()} | {:error, term()}
  def promote(image) do
    cond do
      not gray?(image) ->
        {:ok, image}

      match?({:ok, _profile}, VipsImage.header_value(image, "icc-profile-data")) ->
        WorkingColor.to_srgb(image)

      true ->
        promote_untagged(image)
    end
  end

  defp promote_untagged(image) do
    case VipsImage.interpretation(image) do
      :VIPS_INTERPRETATION_B_W -> Operation.colourspace(image, :VIPS_INTERPRETATION_sRGB)
      :VIPS_INTERPRETATION_GREY16 -> Operation.colourspace(image, :VIPS_INTERPRETATION_RGB16)
    end
  end
end
