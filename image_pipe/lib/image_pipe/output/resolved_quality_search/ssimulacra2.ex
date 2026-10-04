defmodule ImagePipe.Output.ResolvedQualitySearch.Ssimulacra2 do
  # Resolved SSIMULACRA2 quality-target search (higher = better).
  # `start_quality` is the search's first probe; nil starts at the bracket
  # midpoint. Carries the per-content-class confirm-skipped crop offset (#380),
  # populated for both `:photo` and `:graphic` so the `:crop` path's
  # `Map.fetch!` is total.
  @moduledoc false
  @type content_class :: :photo | :graphic
  @enforce_keys [:target, :min_quality, :max_quality]
  defstruct @enforce_keys ++
              [
                start_quality: nil,
                allowed_error: 0,
                quality_search_offsets: %{}
              ]

  @type t :: %__MODULE__{
          target: number(),
          min_quality: 1..100,
          max_quality: 1..100,
          start_quality: nil | 1..100,
          allowed_error: number(),
          quality_search_offsets: %{optional(content_class()) => number()}
        }
end
