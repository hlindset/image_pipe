defmodule ImagePipe.Plan.Output.WebpOptions do
  @moduledoc "libvips `webpsave` encoder options (neutral; imgproxy `webpo` translates here)."
  defstruct [:lossless, :near_lossless, :smart_subsample, :preset, :effort]

  @type t :: %__MODULE__{
          lossless: nil | boolean(),
          near_lossless: nil | boolean(),
          smart_subsample: nil | boolean(),
          preset: nil | :default | :photo | :picture | :drawing | :icon | :text,
          effort: nil | 0..6
        }

  use ImagePipe.Plan.Output.EncoderOptions
end
