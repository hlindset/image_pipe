defmodule ImagePipe.Transform.Operation.Brightness do
  # Executable brightness adjustment operation: additive offset on the 0–255 scale
  # (imgproxy `brightness`, integer -255..255), scaled to the image's band format.
  @moduledoc false

  import ImagePipe.Transform.State

  alias ImagePipe.Transform.Alpha
  alias ImagePipe.Transform.Rounding
  alias ImagePipe.Transform.State
  alias Vix.Vips.Image, as: VipsImage
  alias Vix.Vips.Operation

  @enforce_keys [:value]
  defstruct [:value]

  @type t :: %__MODULE__{value: integer()}

  def execute(%__MODULE__{value: value}, %State{} = state) do
    case apply_brightness(state.image, value) do
      {:ok, image} -> {:ok, set_image(state, image)}
      {:error, error} -> {:error, {__MODULE__, error}}
    end
  end

  defp apply_brightness(%VipsImage{} = image, value) do
    Image.without_alpha_band(image, fn image ->
      format = VipsImage.format(image)
      offset = value * Alpha.opaque(format) / 255

      with {:ok, shifted} <- Operation.linear(image, [1.0], [offset]) do
        Rounding.cast(shifted, format)
      end
    end)
  end
end
