defmodule ImagePipe.Plan.Output.QualitySearch.Ssimulacra2 do
  @moduledoc """
  SSIMULACRA2 quality-target autoquality search. `target` is a SSIMULACRA2 score
  (0–100, higher = better); the search walks the encoder quality knob within
  `[min_quality, max_quality]` to land within `[target − allowed_error, target +
  allowed_error]` (a symmetric band on the 0–100 scale). `format_min`/`format_max`
  clamp the bracket per output format; `max_resolution` skips the search on
  oversized results. See `docs/imgproxy_support_matrix.md` (Autoquality).
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
