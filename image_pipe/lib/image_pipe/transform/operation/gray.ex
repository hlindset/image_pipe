defmodule ImagePipe.Transform.Operation.Gray do
  @moduledoc """
  Executable true grayscale (desaturation) operation. Converts to the `:bw`
  colourspace, discarding hue and saturation; alpha is preserved.
  """

  use ImagePipe.Transform

  import ImagePipe.Transform.State

  alias ImagePipe.Transform.State

  defstruct []

  @type t :: %__MODULE__{}

  @impl ImagePipe.Transform
  def name(%__MODULE__{}), do: :gray

  @impl ImagePipe.Transform
  def execute(%__MODULE__{}, %State{} = state) do
    case Image.to_colorspace(state.image, :bw) do
      {:ok, image} -> {:ok, set_image(state, image)}
      {:error, error} -> {:error, {__MODULE__, error}}
    end
  end
end
