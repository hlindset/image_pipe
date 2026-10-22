defmodule ImagePipe.Plan.Output.WebpOptions do
  @moduledoc """
  WebP encoder options, set with `webp_options:` in `ImagePipe.URL.output/2`
  or [`webp-options`](https://hexdocs.pm/image_pipe/output.html#webp-options)
  in a URL. A field left `nil` keeps the encoder's default.
  """
  defstruct [:lossless, :near_lossless, :smart_subsample, :preset, :effort]

  @type t :: %__MODULE__{
          lossless: nil | boolean(),
          near_lossless: nil | boolean(),
          smart_subsample: nil | boolean(),
          preset: nil | :default | :photo | :picture | :drawing | :icon | :text,
          effort: nil | 0..6
        }

  use ImagePipe.Plan.Output.EncoderOptions

  @doc false
  def schema do
    [
      lossless: [type: :boolean],
      near_lossless: [type: :boolean],
      smart_subsample: [type: :boolean],
      preset: [type: {:in, [:default, :photo, :picture, :drawing, :icon, :text]}],
      effort: [type: {:in, 0..6}]
    ]
  end
end
