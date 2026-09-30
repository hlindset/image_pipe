defmodule ImagePipe.Transform.Operation.Brightness do
  @moduledoc """
  Executable brightness adjustment operation: additive offset on the 0–255 scale
  (imgproxy `brightness`, integer -255..255).
  """

  use ImagePipe.Transform

  import ImagePipe.Transform.State

  alias ImagePipe.Transform.State
  alias Vix.Vips.Image, as: VipsImage
  alias Vix.Vips.Operation

  @enforce_keys [:value]
  defstruct [:value]

  @type t :: %__MODULE__{value: integer()}

  @impl ImagePipe.Transform
  def name(%__MODULE__{}), do: :brightness

  @impl ImagePipe.Transform
  def execute(%__MODULE__{value: value}, %State{} = state) do
    case apply_brightness(state.image, value) do
      {:ok, image} -> {:ok, set_image(state, image)}
      {:error, error} -> {:error, {__MODULE__, error}}
    end
  end

  defp apply_brightness(%VipsImage{} = image, value) do
    Image.without_alpha_band(image, fn image ->
      with {:ok, shifted} <- Operation.linear(image, [1.0], [value * 1.0]) do
        Operation.cast(shifted, VipsImage.format(image))
      end
    end)
  end
end
