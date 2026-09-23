defmodule ImagePipe.Transform.Operation.Flush do
  @moduledoc """
  Applies pending orientation and copies the result to RAM.

  Delegates to `ImagePipe.Transform.Materializer.flush/1`, which applies EXIF
  orientation, user rotation, and user flips, then clears pending state.
  The flush prepares its own random access and buffers the display frame for
  downstream operations.
  """

  use ImagePipe.Transform

  alias ImagePipe.Transform.Materializer

  defstruct []

  @type t :: %__MODULE__{}

  @impl ImagePipe.Transform
  def name(%__MODULE__{}), do: :flush

  @impl ImagePipe.Transform
  def execute(%__MODULE__{}, state) do
    Materializer.flush(state)
  end
end
