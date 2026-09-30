defmodule ImagePipe.Transform.Operation.Monochrome do
  @moduledoc """
  Executable single-color luminance tint operation.
  """

  use ImagePipe.Transform

  alias ImagePipe.Transform.Operation.Duotone
  alias ImagePipe.Transform.State

  @enforce_keys [:intensity, :color]
  defstruct [:intensity, :color]

  @type t :: %__MODULE__{
          intensity: float(),
          color: [0..255]
        }

  @impl ImagePipe.Transform
  def name(%__MODULE__{}), do: :monochrome

  @impl ImagePipe.Transform
  def execute(%__MODULE__{intensity: intensity, color: color}, %State{} = state) do
    operation = %Duotone{intensity: intensity, shadow: [0, 0, 0], highlight: color}

    case Duotone.execute(operation, state) do
      {:ok, state} -> {:ok, state}
      {:error, {_module, error}} -> {:error, {__MODULE__, error}}
    end
  end
end
