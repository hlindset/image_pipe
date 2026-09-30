defmodule ImagePipe.Output.ResolvedQualitySearch.Size do
  @moduledoc "Resolved `:size` byte-budget search (bracket per-format clamped)."
  @enforce_keys [:target, :min_quality, :max_quality]
  defstruct @enforce_keys ++ [max_resolution: 0]

  @type t :: %__MODULE__{
          target: pos_integer(),
          min_quality: 1..100,
          max_quality: 1..100,
          max_resolution: non_neg_integer()
        }
end
