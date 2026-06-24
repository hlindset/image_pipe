defmodule ImagePipe.Plan.Output.QualitySearch.Butteraugli do
  @moduledoc """
  Butteraugli distance-target autoquality search. `target` is a butteraugli
  distance (lower = better; ~1.0 is visually lossless; valid range 0.0–25.0,
  validated at resolve). On WebP/AVIF/JPEG the search walks the encoder quality
  knob within `[min_quality, max_quality]` to land within `[target − allowed_error,
  target + allowed_error]`. On JPEG XL it drives libvips' native `distance` knob
  directly (resolve picks `Output.ResolvedQualitySearch.NativeJxlButteraugli`),
  where the bracket clamps the target via the libjxl Q→distance mapping.
  `max_resolution` skips the search on oversized results.
  """
  @enforce_keys [:target, :min_quality, :max_quality]
  defstruct @enforce_keys ++
              [allowed_error: 0, format_min: %{}, format_max: %{}, max_resolution: 0]

  @type format :: ImagePipe.Format.output_format()
  @type t :: %__MODULE__{
          target: number(),
          min_quality: 1..100,
          max_quality: 1..100,
          allowed_error: number(),
          format_min: %{optional(format()) => 1..100},
          format_max: %{optional(format()) => 1..100},
          max_resolution: non_neg_integer()
        }
end
