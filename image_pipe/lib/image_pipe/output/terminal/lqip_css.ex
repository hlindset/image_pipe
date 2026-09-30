defmodule ImagePipe.Output.Terminal.LqipCss do
  @moduledoc """
  Encodes a CSS-only placeholder as a packed `#rrggbbaa` value.

  Uses the shared sRGB, black-flattened, 8-bit placeholder pixel space and
  `Image.Lqip.Css`. The executor supplies a materialized 3×3 display frame.
  """

  alias Image.Lqip.Css
  alias ImagePipe.Output.Terminal.PixelSpace
  alias Vix.Vips.Image, as: Vimage
  alias Vix.Vips.MutableImage

  @spec identity() :: {:lqip_css, 1}
  def identity, do: {:lqip_css, 1}

  @spec compute(Vimage.t()) :: {:ok, String.t()} | {:error, term()}
  def compute(%Vimage{} = image) do
    with {:ok, image} <- clear_source_metadata(image),
         {:ok, normalized} <- PixelSpace.normalize(image) do
      Css.encode(normalized)
    end
  end

  # Pixels already reflect the executor's orientation and working-space import.
  # Image's thumbnail encoder must not apply the retained source tags again.
  defp clear_source_metadata(image) do
    Vimage.mutate(image, fn mutable ->
      _ = MutableImage.remove(mutable, "orientation")
      _ = MutableImage.remove(mutable, "icc-profile-data")
      :ok
    end)
  end
end
