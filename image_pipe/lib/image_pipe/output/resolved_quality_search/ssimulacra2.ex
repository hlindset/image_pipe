defmodule ImagePipe.Output.ResolvedQualitySearch.Ssimulacra2 do
  # Resolved SSIMULACRA2 quality-target search (higher = better).
  # `start_quality` is the search's first probe; nil starts at the bracket
  # midpoint.
  @moduledoc false
  @enforce_keys [:target, :min_quality, :max_quality]
  defstruct @enforce_keys ++ [start_quality: nil, allowed_error: 0]

  @type t :: %__MODULE__{
          target: number(),
          min_quality: 1..100,
          max_quality: 1..100,
          start_quality: nil | 1..100,
          allowed_error: number()
        }
end
