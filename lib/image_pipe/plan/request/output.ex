defmodule ImagePipe.Plan.Request.Output do
  @moduledoc """
  Terminal selection and sparse output intent from a request.

  Host defaults and format negotiation resolve this intent into
  `ImagePipe.Output.Policy` for image encoding.
  """

  defstruct terminal: :image,
            format: nil,
            quality: nil,
            metadata: nil,
            color_profile: nil,
            hdr: nil,
            format_qualities: %{},
            autoquality: nil,
            max_bytes: nil,
            encoder_options: %{}

  @type t :: %__MODULE__{
          terminal: :image | :blurhash | :info,
          format: nil | :avif | :webp | :jpeg | :png | :jpeg_xl,
          quality: nil | 1..100,
          metadata: nil | :strip | :copyright | :keep,
          color_profile:
            nil
            | :strip
            | :preserve_source
            | {:convert, :srgb | :display_p3 | :adobe_rgb},
          hdr: nil | :tone_map | :preserve,
          format_qualities: %{optional(atom()) => {:quality, 1..100}},
          autoquality:
            nil
            | :none
            | {:size | :ssimulacra2 | :butteraugli, keyword(pos_integer() | float())},
          max_bytes: nil | pos_integer(),
          encoder_options: %{optional(atom()) => struct()}
        }
end
