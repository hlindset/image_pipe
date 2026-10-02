defmodule ImagePipe.Transform.Operation.Saturation do
  # Executable saturation adjustment operation.
  @moduledoc false

  use ImagePipe.Transform

  import ImagePipe.Transform.State

  alias ImagePipe.Transform.State

  @enforce_keys [:value]
  defstruct [:value]

  @type t :: %__MODULE__{value: number()}

  @impl ImagePipe.Transform
  def name(%__MODULE__{}), do: :saturation

  @impl ImagePipe.Transform
  # Workaround for `image` (0.72, unchanged on main as of 2026-10):
  # `Image.saturation/2` multiplies the LCh image by a 3-element vector, which
  # libvips rejects when an alpha band makes it 4 bands. Apply it to the color
  # bands only and rejoin the alpha.
  def execute(%__MODULE__{value: value}, %State{} = state) do
    case Image.without_alpha_band(state.image, &Image.saturation(&1, value)) do
      {:ok, image} -> {:ok, set_image(state, image)}
      {:error, error} -> {:error, {__MODULE__, error}}
    end
  end
end
