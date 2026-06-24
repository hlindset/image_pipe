defmodule ImagePipe.Output.ResolvedQualitySearch.Butteraugli do
  @moduledoc """
  Resolved butteraugli distance-target search for the **external-measure** path
  (non-JXL formats), lower = better. Full-frame only this cycle (no crop offsets).
  """
  @enforce_keys [:target, :min_quality, :max_quality]
  defstruct @enforce_keys ++ [allowed_error: 0, max_resolution: 0]

  @type t :: %__MODULE__{
          target: number(),
          min_quality: 1..100,
          max_quality: 1..100,
          allowed_error: number(),
          max_resolution: non_neg_integer()
        }
end
