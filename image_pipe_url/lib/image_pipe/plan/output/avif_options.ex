defmodule ImagePipe.Plan.Output.AvifOptions do
  @moduledoc "libvips `heifsave` (AVIF) encoder options (neutral; imgproxy `avifo`/`AVIF_SPEED` translate here)."
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
