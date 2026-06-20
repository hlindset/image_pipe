defmodule ImagePipe.Output.ResolvedQualitySearch do
  @moduledoc """
  Encode-quality search objective resolved against the negotiated output format:
  the bracket is already per-format clamped, and the per-format maps have been
  consumed. `max_resolution` rides along for the encoder's skip check. Consumed by
  `ImagePipe.Output.EncodeSearch`.
  """

  @enforce_keys [:objective, :target, :min_quality, :max_quality]
  defstruct @enforce_keys ++ [allowed_error: 0, max_resolution: 0]

  @type t :: %__MODULE__{
          objective: :size | :ssim2,
          target: number(),
          min_quality: 1..100,
          max_quality: 1..100,
          allowed_error: number(),
          max_resolution: non_neg_integer()
        }
end
