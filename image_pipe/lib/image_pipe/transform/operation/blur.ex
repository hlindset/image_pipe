defmodule ImagePipe.Transform.Operation.Blur do
  # Executable Gaussian blur operation.
  @moduledoc false

  import ImagePipe.Transform.State

  alias ImagePipe.Transform.Operation.AlphaPremultiply
  alias ImagePipe.Transform.Operation.GaussianBlur
  alias ImagePipe.Transform.State

  @enforce_keys [:sigma]
  defstruct [:sigma]

  @type t :: %__MODULE__{sigma: float()}

  def execute(%__MODULE__{sigma: sigma}, %State{} = state) do
    case AlphaPremultiply.with_alpha_premultiplied(state.image, &GaussianBlur.blur(&1, sigma)) do
      {:ok, image} -> {:ok, set_image(state, image)}
      {:error, error} -> {:error, {__MODULE__, error}}
    end
  end
end
