defmodule ImagePipe.Plan.Operation.Padding do
  @moduledoc """
  Semantic operation that expands the current image by edge padding.
  """

  @enforce_keys [:top, :right, :bottom, :left, :pixel_ratio, :fill]
  defstruct @enforce_keys

  @type side :: {:px, non_neg_integer()}
  @type ratio :: {:ratio, pos_integer(), pos_integer()}
  @type pixel_ratio :: ratio()
  @type fill :: :transparent | {:solid, ImagePipe.Plan.Color.t()}

  @type t :: %__MODULE__{
          top: side(),
          right: side(),
          bottom: side(),
          left: side(),
          pixel_ratio: pixel_ratio(),
          fill: fill()
        }
end
