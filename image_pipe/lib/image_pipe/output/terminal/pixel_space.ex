defmodule ImagePipe.Output.Terminal.PixelSpace do
  # Fixed pixel space for placeholders: profile-aware sRGB, tone-mapped,
  # flattened on white, and cast to 8-bit channels. The result carries no ICC
  # profile, so placeholder encoders don't convert the sRGB pixels again.
  @moduledoc false

  alias ImagePipe.SrgbProfile
  alias Vix.Vips.Image, as: Vimage

  @spec normalize(Vimage.t()) :: {:ok, Vimage.t()} | {:error, term()}
  def normalize(%Vimage{} = image) do
    with {:ok, srgb} <- to_srgb(image),
         {:ok, srgb} <- Image.remove_metadata(srgb, ["icc-profile-data"]),
         {:ok, flattened} <- Image.flatten(srgb, background: :white) do
      Image.cast(flattened, {:u, 8})
    end
  end

  # An sRGB-equivalent profile converts like no profile.
  defp to_srgb(image) do
    if embedded_icc_profile?(image) do
      Image.to_colorspace(image, :srgb, [])
    else
      Image.to_colorspace(image, :srgb)
    end
  end

  defp embedded_icc_profile?(image) do
    case Vimage.header_value(image, "icc-profile-data") do
      {:ok, profile} when is_binary(profile) -> not SrgbProfile.equivalent?(profile)
      _not_present -> false
    end
  end
end
