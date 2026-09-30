defmodule ImagePipe.Plan.Output.QualitySearch.Size do
  @moduledoc """
  Byte-budget autoquality search (imgproxy `autoquality:size`). `target` is a byte
  count; the search finds the highest quality in `[min_quality, max_quality]` whose
  encode is `<= target`. `format_min`/`format_max` clamp the bracket per output
  format (resolved away in `ImagePipe.Output.Policy`); `max_resolution` (megapixels,
  0 = off) skips the search on oversized results. No perceptual metric, no band.
  """
  @enforce_keys [:target, :min_quality, :max_quality]
  defstruct @enforce_keys ++
              [
                url_min_quality: nil,
                url_max_quality: nil,
                format_min: %{},
                format_max: %{},
                max_resolution: 0
              ]

  @type format :: ImagePipe.Format.output_format()
  @type t :: %__MODULE__{
          target: pos_integer(),
          min_quality: 1..100,
          max_quality: 1..100,
          url_min_quality: nil | 1..100,
          url_max_quality: nil | 1..100,
          format_min: %{optional(format()) => 1..100},
          format_max: %{optional(format()) => 1..100},
          max_resolution: non_neg_integer()
        }
end
