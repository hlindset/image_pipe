defmodule ImagePipe.Output.ResolvedQualitySearch.NativeJxlButteraugli do
  @moduledoc """
  Resolved native-JXL butteraugli strategy: libvips drives `distance` directly, so
  there is no external measurement. `min_quality`/`max_quality` are Q-scale bracket
  bounds clamped into distance space (libjxl Q→distance) at execution; `max_bytes`
  is honored by raising `distance` from the clamped target until the bytes fit.
  """
  @enforce_keys [:target, :min_quality, :max_quality]
  defstruct @enforce_keys ++ [allowed_error: 0, max_resolution: 0]

  @type t :: %__MODULE__{
          target: number(),
          min_quality: 1..100,
          max_quality: 1..100,
          allowed_error: number(),
          max_resolution: non_neg_integer()
        }
end
