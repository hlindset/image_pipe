defmodule ImagePipe.Output.Resolved do
  @moduledoc false
  # `degraded?` marks pixels produced by a fallback after a failure (a crop that
  # used attention because detection errored). Such output is never stored and
  # gets no validator.

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
                quality_search: :none,
                max_bytes: nil,
                dpi: nil,
                encoder_options: nil,
                degraded?: false
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
          quality_search:
            :none
            | ImagePipe.Output.ResolvedQualitySearch.Ssimulacra2.t(),
          max_bytes: nil | pos_integer(),
          dpi: nil | 1..65_535,
          encoder_options:
            nil
            | ImagePipe.Plan.Output.JpegOptions.t()
            | ImagePipe.Plan.Output.PngOptions.t()
            | ImagePipe.Plan.Output.WebpOptions.t()
            | ImagePipe.Plan.Output.AvifOptions.t(),
          degraded?: boolean()
        }
end
