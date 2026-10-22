defmodule ImagePipe.Plan.Output.JpegOptions do
  @moduledoc """
  JPEG encoder options, set with `jpeg_options:` in `ImagePipe.URL.output/2`
  or [`jpeg-options`](https://hexdocs.pm/image_pipe/output.html#jpeg-options)
  in a URL. A field left `nil` keeps the encoder's default.
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

  @doc false
  def schema do
    [
      interlace: [type: :boolean],
      subsample_mode: [type: {:in, [:auto, :on, :off]}],
      trellis_quant: [type: :boolean],
      overshoot_deringing: [type: :boolean],
      optimize_scans: [type: :boolean],
      quant_table: [type: {:in, 0..8}]
    ]
  end
end
