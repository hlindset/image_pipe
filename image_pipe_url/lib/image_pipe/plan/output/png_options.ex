defmodule ImagePipe.Plan.Output.PngOptions do
  @moduledoc """
  PNG encoder options, set with `png_options:` in `ImagePipe.URL.output/2`
  or [`png-options`](https://hexdocs.pm/image_pipe/output.html#png-options)
  in a URL. A field left `nil` keeps the encoder's default.
  """
  defstruct [:interlace, :palette, :bitdepth, :filter]

  @type t :: %__MODULE__{
          interlace: nil | boolean(),
          palette: nil | boolean(),
          bitdepth: nil | 1 | 2 | 4 | 8 | 16,
          filter: nil | :none | :sub | :up | :avg | :paeth | :all
        }

  use ImagePipe.Plan.Output.EncoderOptions

  @doc false
  def schema do
    [
      interlace: [type: :boolean],
      palette: [type: :boolean],
      bitdepth: [type: {:in, [1, 2, 4, 8, 16]}],
      filter: [type: {:in, [:none, :sub, :up, :avg, :paeth, :all]}]
    ]
  end
end
