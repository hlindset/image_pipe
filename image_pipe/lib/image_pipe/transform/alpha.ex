defmodule ImagePipe.Transform.Alpha do
  # Adds an opaque alpha band at the full scale of the image's band format.
  #
  # Workaround for `image` (0.72): `Image.add_alpha(image, :opaque)` writes 255
  # into the new band whatever the band format, so a 16-bit image gets alpha
  # 255/65535 and comes out 0.4% opaque. elixir-image/image#231 fixes it
  # upstream; until a release carries it, add the band directly.
  @moduledoc false

  alias Vix.Vips.Image, as: VipsImage
  alias Vix.Vips.Operation

  @spec ensure(VipsImage.t()) :: {:ok, VipsImage.t()} | {:error, term()}
  def ensure(image) do
    case Image.has_alpha?(image) do
      true -> {:ok, image}
      false -> Operation.bandjoin_const(image, [opaque(VipsImage.format(image))])
    end
  end

  @spec opaque(atom()) :: float()
  def opaque(:VIPS_FORMAT_USHORT), do: 65_535.0
  def opaque(format) when format in [:VIPS_FORMAT_FLOAT, :VIPS_FORMAT_DOUBLE], do: 1.0
  def opaque(_format), do: 255.0
end
