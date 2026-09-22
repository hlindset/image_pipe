defmodule ImagePipe.Transform.Operation.Flush do
  @moduledoc """
  Applies pending orientation, preparing random access when needed.

  Delegates to `ImagePipe.Transform.OrientationFlush.flush/1`, which applies EXIF
  orientation, user rotation, and user flips, then clears pending state.
  The flush manages its own random access from runtime orientation data and
  preserves sequential execution for horizontal-only flips.
  """

  use ImagePipe.Transform

  alias ImagePipe.Transform.OrientationFlush

  defstruct []

  @type t :: %__MODULE__{}

  @impl ImagePipe.Transform
  def name(%__MODULE__{}), do: :flush

  @impl ImagePipe.Transform
  def execute(%__MODULE__{}, state) do
    case OrientationFlush.flush(state) do
      {:ok, state} -> {:ok, state}
      {:error, reason} -> {:error, {:materialize_error, reason}}
    end
  end
end
