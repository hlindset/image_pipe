defmodule ImagePipe.Plan.Output.JpegOptions do
  @moduledoc """
  libvips `jpegsave` encoder options (product-neutral; the imgproxy parser
  translates `jpgo` into this). Every field is optional (`nil` ⇒ emit no token,
  leaving libvips' default).
  """
  defstruct [
    :interlace,
    :subsample_mode,
    :trellis_quant,
    :overshoot_deringing,
    :optimize_scans,
    :quant_table
  ]

  @type t :: %__MODULE__{
          interlace: nil | boolean(),
          subsample_mode: nil | :auto | :on | :off,
          trellis_quant: nil | boolean(),
          overshoot_deringing: nil | boolean(),
          optimize_scans: nil | boolean(),
          quant_table: nil | 0..8
        }

  use ImagePipe.Plan.Output.EncoderOptions
end
