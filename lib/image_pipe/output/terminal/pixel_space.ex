defmodule ImagePipe.Output.Terminal.PixelSpace do
  @moduledoc """
  Fixed pixel space for placeholders: profile-aware sRGB, tone-mapped,
  flattened on black, and cast to 8-bit channels.
  """

  alias Vix.Vips.Image, as: Vimage

  @spec normalize(Vimage.t()) :: {:ok, Vimage.t()} | {:error, term()}
  def normalize(%Vimage{} = image) do
    with {:ok, srgb} <- to_srgb(image),
         {:ok, flattened} <- Image.flatten(srgb, background: :black) do
      Image.cast(flattened, {:u, 8})
    end
  end

  defp to_srgb(image) do
    if embedded_icc_profile?(image) do
      Image.to_colorspace(image, :srgb, [])
    else
      Image.to_colorspace(image, :srgb)
    end
  end

  defp embedded_icc_profile?(image) do
    case Vimage.header_value(image, "icc-profile-data") do
      {:ok, profile} when is_binary(profile) -> true
      _not_present -> false
    end
  end
end
