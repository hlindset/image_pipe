defmodule ImagePipe.Transform.Operation.AlphaPremultiply do
  @moduledoc """
  Shared helper for alpha-correct filtering.

  libvips filters such as blur and sharpen must run on premultiplied alpha to
  avoid bleeding fully-transparent pixel colour into visible edges. This wraps a
  filter callback so it runs premultiply → filter → unpremultiply, restoring the
  original band format. Images without an alpha band are filtered directly.
  """

  alias Vix.Vips.Image, as: VipsImage
  alias Vix.Vips.Operation

  @doc """
  Runs `callback` on `image` with alpha premultiplied when an alpha band is
  present, restoring the original band format afterward. Without an alpha band,
  `callback` runs on the image directly.
  """
  @spec with_alpha_premultiplied(
          VipsImage.t(),
          (VipsImage.t() -> {:ok, VipsImage.t()} | {:error, term()})
        ) :: {:ok, VipsImage.t()} | {:error, term()}
  def with_alpha_premultiplied(%VipsImage{} = image, callback) do
    if Image.has_alpha?(image) do
      band_format = VipsImage.format(image)

      with {:ok, premultiplied} <- Operation.premultiply(image),
           {:ok, cast} <- Operation.cast(premultiplied, band_format),
           {:ok, filtered} <- callback.(cast),
           {:ok, unpremultiplied} <- Operation.unpremultiply(filtered) do
        Operation.cast(unpremultiplied, band_format)
      end
    else
      callback.(image)
    end
  end
end
