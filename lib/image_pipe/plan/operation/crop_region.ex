defmodule ImagePipe.Plan.Operation.CropRegion do
  @moduledoc """
  Semantic crop operation that crops an explicit region.

  `on_out_of_bounds` is the declarative policy for a region whose origin lies
  wholly outside the source image: `:clamp` (default) clips it to the nearest
  in-bounds edge, `:reject` fails the request with a client error. Only a
  dialect whose contract requires it (IIIF's spec-mandated 400) sets `:reject`;
  others keep the default clamp.
  """

  @enforce_keys [:x, :y, :width, :height]
  defstruct @enforce_keys ++ [on_out_of_bounds: :clamp]

  @type coordinate :: {:px, non_neg_integer()} | {:ratio, non_neg_integer(), pos_integer()}
  @type dimension :: {:px, pos_integer()} | {:ratio, pos_integer(), pos_integer()}
  @type out_of_bounds_policy :: :clamp | :reject

  @type t :: %__MODULE__{
          x: coordinate(),
          y: coordinate(),
          width: dimension(),
          height: dimension(),
          on_out_of_bounds: out_of_bounds_policy()
        }
end
