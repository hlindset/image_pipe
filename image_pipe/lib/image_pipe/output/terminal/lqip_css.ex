defmodule ImagePipe.Output.Terminal.LqipCss do
  # Encodes a CSS-only placeholder as a packed `#rrggbbaa` value.
  #
  # Uses the shared sRGB, black-flattened, 8-bit placeholder pixel space and
  # `Image.Lqip.Css`. The executor supplies a materialized 3×3 display frame.
  @moduledoc false

  alias Image.Lqip.Css
  alias ImagePipe.Output.Terminal.PixelSpace
  alias Vix.Vips.Image, as: Vimage

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
    Image.remove_metadata(image, ["orientation", "icc-profile-data"])
  end
end
