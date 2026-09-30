defmodule ImagePipe.Output.ResolvedQualitySearch.Ssimulacra2 do
  @moduledoc """
  Resolved SSIMULACRA2 quality-target search (higher = better). Carries the
  per-content-class confirm-skipped crop offset (#380), populated for both
  `:photo` and `:graphic` so the `:crop` path's `Map.fetch!` is total.
  """
  @type content_class :: :photo | :graphic
  @enforce_keys [:target, :min_quality, :max_quality]
  defstruct @enforce_keys ++ [allowed_error: 0, max_resolution: 0, quality_search_offsets: %{}]

  @type t :: %__MODULE__{
          target: number(),
          min_quality: 1..100,
          max_quality: 1..100,
          allowed_error: number(),
          max_resolution: non_neg_integer(),
          quality_search_offsets: %{optional(content_class()) => number()}
        }
end
