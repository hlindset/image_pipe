defmodule ImagePipe.Plan.Output.AvifOptions do
  @moduledoc """
  AVIF encoder options, set with `avif_options:` in `ImagePipe.URL.output/2`
  or [`avif-options`](https://hexdocs.pm/image_pipe/output.html#avif-options)
  in a URL. A field left `nil` keeps the encoder's default.
  """
  defstruct [:subsample_mode, :effort]

  @type t :: %__MODULE__{
          subsample_mode: nil | :auto | :on | :off,
          effort: nil | 0..9
        }

  use ImagePipe.Plan.Output.EncoderOptions

  @doc false
  def schema do
    [subsample_mode: [type: {:in, [:auto, :on, :off]}], effort: [type: {:in, 0..9}]]
  end
end
