defmodule ImagePipe.Output.Resolved do
  @moduledoc false

  alias ImagePipe.Plan.Color

  @enforce_keys [
    :format,
    :quality,
    :response_headers,
    :strip_metadata,
    :keep_copyright,
    :color_profile
  ]
  defstruct @enforce_keys ++
              [
                flatten_background: Color.white(),
                quality_search: :none,
                max_bytes: nil,
                encoder_options: nil
              ]

  @type format :: ImagePipe.Format.output_format()
  @type quality :: ImagePipe.Plan.Output.quality()
  @type t :: %__MODULE__{
          format: format(),
          quality: quality(),
          response_headers: [{String.t(), String.t()}],
          strip_metadata: boolean(),
          keep_copyright: boolean(),
          color_profile: ImagePipe.Plan.Output.color_profile(),
          flatten_background: Color.t(),
          quality_search:
            :none
            | ImagePipe.Output.ResolvedQualitySearch.Size.t()
            | ImagePipe.Output.ResolvedQualitySearch.Ssimulacra2.t()
            | ImagePipe.Output.ResolvedQualitySearch.Butteraugli.t()
            | ImagePipe.Output.ResolvedQualitySearch.NativeJxlButteraugli.t(),
          max_bytes: nil | pos_integer(),
          encoder_options:
            nil
            | ImagePipe.Plan.Output.JpegOptions.t()
            | ImagePipe.Plan.Output.PngOptions.t()
            | ImagePipe.Plan.Output.WebpOptions.t()
            | ImagePipe.Plan.Output.AvifOptions.t()
            | ImagePipe.Plan.Output.JxlOptions.t()
        }

  @doc """
  The negotiated JPEG XL encode effort: `JxlOptions.effort`, defaulting to
  libvips `jxlsave`'s own default (7) when unset. Single source of truth for the
  lazy-encode and native-search JXL paths.
  """
  @spec jxl_effort(t()) :: 1..9
  def jxl_effort(%__MODULE__{encoder_options: %ImagePipe.Plan.Output.JxlOptions{effort: e}}),
    do: e || 7

  def jxl_effort(%__MODULE__{}), do: 7
end
