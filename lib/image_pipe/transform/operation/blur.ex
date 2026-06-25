defmodule ImagePipe.Transform.Operation.Blur do
  @moduledoc """
  Executable Gaussian blur operation.
  """

  use ImagePipe.Transform

  import ImagePipe.Transform.State

  alias ImagePipe.Transform.Operation.AlphaPremultiply
  alias ImagePipe.Transform.State

  @enforce_keys [:sigma]
  defstruct [:sigma]

  @type t :: %__MODULE__{sigma: float()}

  @impl ImagePipe.Transform
  def name(%__MODULE__{}), do: :blur

  @impl ImagePipe.Transform
  def execute(%__MODULE__{sigma: sigma}, %State{} = state) do
    case AlphaPremultiply.with_alpha_premultiplied(state.image, &Image.blur(&1, sigma: sigma)) do
      {:ok, image} -> {:ok, set_image(state, image)}
      {:error, error} -> {:error, {__MODULE__, error}}
    end
  end
end
