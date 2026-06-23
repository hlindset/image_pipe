defmodule ImagePipe.Output.ResolvedQualitySearch do
  @moduledoc """
  Encode-quality search objective resolved against the negotiated output format:
  the bracket is already per-format clamped, and the per-format maps have been
  consumed. `max_resolution` rides along for the encoder's skip check. Consumed by
  `ImagePipe.Output.EncodeSearch`.

  `quality_search_offsets` is the per-content-class confirm-skipped crop offset for
  the negotiated format (#380), collapsed from `Plan.Output.quality_search_offsets`.
  The default `%{}` is the resolved shape only for `:size`/`:none` (which never
  crop-score); the `:ssim2` resolver always populates both `:photo` and `:graphic`
  keys, so the `:crop` path's `Map.fetch!` trusts a fully-populated map.
  """

  @type content_class :: :photo | :graphic

  @enforce_keys [:objective, :target, :min_quality, :max_quality]
  defstruct @enforce_keys ++ [allowed_error: 0, max_resolution: 0, quality_search_offsets: %{}]

  @type t :: %__MODULE__{
          objective: :size | :ssim2,
          target: number(),
          min_quality: 1..100,
          max_quality: 1..100,
          allowed_error: number(),
          max_resolution: non_neg_integer(),
          quality_search_offsets: %{optional(content_class()) => number()}
        }
end
