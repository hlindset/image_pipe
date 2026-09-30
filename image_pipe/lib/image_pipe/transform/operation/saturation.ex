defmodule ImagePipe.Transform.Operation.Saturation do
  @moduledoc """
  Executable saturation adjustment operation.
  """

  use ImagePipe.Transform

  import ImagePipe.Transform.State

  alias ImagePipe.Transform.State

  @enforce_keys [:value]
  defstruct [:value]

  @type t :: %__MODULE__{value: number()}

  @impl ImagePipe.Transform
  def name(%__MODULE__{}), do: :saturation

  @impl ImagePipe.Transform
  def execute(%__MODULE__{value: value}, %State{} = state) do
    case Image.saturation(state.image, value) do
      {:ok, image} -> {:ok, set_image(state, image)}
      {:error, error} -> {:error, {__MODULE__, error}}
    end
  end
end
