defmodule ImagePipe.Plan.Operation.Gradient do
  @moduledoc """
  Semantic transparency→color gradient overlay operation.

  `angle` is canonical clockwise degrees (0=down, 90=left, 180=up, 270=right).
  """

  alias ImagePipe.Plan.Color

  @enforce_keys [:opacity, :color, :angle, :start, :stop]
  defstruct [:opacity, :color, :angle, :start, :stop]

  @type t :: %__MODULE__{
          opacity: Color.alpha(),
          color: Color.t(),
          angle: float(),
          start: float(),
          stop: float()
        }
end
