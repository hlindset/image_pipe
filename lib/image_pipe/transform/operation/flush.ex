defmodule ImagePipe.Transform.Operation.Flush do
  @moduledoc """
  Applies pending orientation and copies the result to RAM.

  Delegates to `ImagePipe.Transform.Materializer.flush/1`, which applies EXIF
  orientation, user rotation, and user flips, then clears pending state.
  `requires_materialization?: false` avoids a redundant copy: the flush prepares
  its own random access and materializes the result.
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
