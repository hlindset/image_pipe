defmodule ImagePipe.Plan.Output.QualitySearch do
  @moduledoc """
  Declarative encode-quality search objective (imgproxy `autoquality`), before
  format negotiation. `target` is a SSIMULACRA2 score (0–100) for `:ssim2` or a
  byte count for `:size`. The bracket (`min_quality`/`max_quality`) bounds the
  encoder quality knob; `format_min`/`format_max` clamp it per output format and
  are resolved away in `ImagePipe.Output.Policy`. `max_resolution` (megapixels,
  0 = off) skips the search on oversized results.
  """

  @enforce_keys [:objective, :target, :min_quality, :max_quality]
  defstruct @enforce_keys ++
              [allowed_error: 0, format_min: %{}, format_max: %{}, max_resolution: 0]

  @type objective :: :size | :ssim2
  @type format :: ImagePipe.Format.output_format()
  @type t :: %__MODULE__{
          objective: objective(),
          target: number(),
          min_quality: 1..100,
          max_quality: 1..100,
          allowed_error: number(),
          format_min: %{optional(format()) => 1..100},
          format_max: %{optional(format()) => 1..100},
          max_resolution: non_neg_integer()
        }
end
