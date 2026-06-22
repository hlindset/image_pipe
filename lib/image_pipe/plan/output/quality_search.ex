defmodule ImagePipe.Plan.Output.QualitySearch do
  @moduledoc """
  Declarative encode-quality search objective (imgproxy `autoquality`), before
  format negotiation. `target` is a SSIMULACRA2 score (0–100) for `:ssim2` or a
  byte count for `:size`. The bracket (`min_quality`/`max_quality`) bounds the
  encoder quality knob; `format_min`/`format_max` clamp it per output format and
  are resolved away in `ImagePipe.Output.Policy`. `max_resolution` (megapixels,
  0 = off) skips the search on oversized results.

  `allowed_error` is a tolerance band **on the SSIMULACRA2 scale** (points on
  0–100): the `:ssim2` objective accepts the lowest quality scoring
  `≥ target − allowed_error`. It is **not** imgproxy's DSSIM `allowed_error`
  (0–1, where `1.0` means "accept anything") — on this scale the same `1.0` is a
  strict one-point band. It applies only to `:ssim2`; the `:size` objective is a
  bare `bytes ≤ target` predicate with no band and ignores it.
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
