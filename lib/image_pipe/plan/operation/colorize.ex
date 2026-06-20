defmodule ImagePipe.Plan.Operation.Colorize do
  @moduledoc """
  Semantic solid-color overlay operation.
  """

  alias ImagePipe.Plan.Color

  @enforce_keys [:opacity, :color, :keep_alpha]
  defstruct [:opacity, :color, :keep_alpha]

  @type t :: %__MODULE__{
          opacity: Color.alpha(),
          color: Color.t(),
          keep_alpha: boolean()
        }
end
