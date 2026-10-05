defmodule ImagePipe.Transform.Operation.Contrast do
  # Executable contrast adjustment operation: scales each color channel around
  # 128 on the 0–255 scale, scaled to the image's band format like `brightness`.
  # Alpha is unchanged.
  @moduledoc false

  use ImagePipe.Transform

  import ImagePipe.Transform.State

  alias ImagePipe.Transform.Alpha
  alias ImagePipe.Transform.State
  alias Vix.Vips.Image, as: VipsImage
  alias Vix.Vips.Operation

  @enforce_keys [:value]
  defstruct [:value]

  @type t :: %__MODULE__{value: number()}

  @impl ImagePipe.Transform
  def name(%__MODULE__{}), do: :contrast

  @impl ImagePipe.Transform
  def execute(%__MODULE__{value: value}, %State{} = state) do
    case apply_contrast(state.image, value) do
      {:ok, image} -> {:ok, set_image(state, image)}
      {:error, error} -> {:error, {__MODULE__, error}}
    end
  end

  defp apply_contrast(%VipsImage{} = image, value) do
    Image.without_alpha_band(image, fn image ->
      format = VipsImage.format(image)
      pivot = 128 * Alpha.opaque(format) / 255

      with {:ok, scaled} <- Operation.linear(image, [value], [pivot * (1 - value)]) do
        Operation.cast(scaled, format)
      end
    end)
  end
end
