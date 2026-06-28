defmodule ImagePipe.Plan.Output.PngOptions do
  @moduledoc "libvips `pngsave` encoder options (neutral; imgproxy `pngo` translates here)."
  defstruct [:interlace, :palette, :bitdepth, :filter]

  @type t :: %__MODULE__{
          interlace: nil | boolean(),
          palette: nil | boolean(),
          bitdepth: nil | 1 | 2 | 4 | 8 | 16,
          filter: nil | :none | :sub | :up | :avg | :paeth | :all
        }

  use ImagePipe.Plan.Output.EncoderOptions
end
