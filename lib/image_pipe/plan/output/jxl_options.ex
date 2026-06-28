defmodule ImagePipe.Plan.Output.JxlOptions do
  @moduledoc """
  libvips `jxlsave` encoder options (neutral). `effort` is optional; when unset
  the encoder applies libvips' default (7) — see `ImagePipe.Output.Encoder`.
  """
  defstruct [:effort]

  @type t :: %__MODULE__{effort: nil | 1..9}

  use ImagePipe.Plan.Output.EncoderOptions
end
