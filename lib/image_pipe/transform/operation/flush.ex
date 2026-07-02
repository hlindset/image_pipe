defmodule ImagePipe.Transform.Operation.Flush do
  @moduledoc """
  Executable flush operation that applies any pending orientation late.

  This operation delegates to `ImagePipe.Transform.Materializer.flush/1`,
  which applies pending EXIF auto-rotate and user-rotate/flip operations
  before copying the image to RAM and clearing the pending state.

  The operation is marked `requires_materialization?: false` because it
  self-manages: `OrientationFlush.flush/1` already performs its own
  random-access preparation and copy, so pre-materialization would be a
  redundant copy.
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
