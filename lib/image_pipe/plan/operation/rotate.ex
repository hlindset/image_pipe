defmodule ImagePipe.Plan.Operation.Rotate do
  @moduledoc """
  Semantic request to rotate the image clockwise by `angle` degrees, optionally
  mirrored (horizontal flip) first.

  `angle` is any number in `[0, 360)` (degrees, clockwise; the parser/constructor
  accepts the closed interval `[0, 360]` and folds `360` to `0`); whole-number
  angles are stored as integers so that right-angle multiples route to the lossless
  rotate path. `mirror` applies a horizontal flip *before* the rotation (IIIF `!`
  semantics).
  """

  @enforce_keys [:angle]
  defstruct [:angle, mirror: false]

  @type t :: %__MODULE__{angle: number(), mirror: boolean()}
end
