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
              [flatten_background: Color.white(), quality_search: :none, max_bytes: nil]

  @type format :: ImagePipe.Format.output_format()
  @type quality :: :default | {:quality, 1..100}
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
            | ImagePipe.Output.ResolvedQualitySearch.Butteraugli.t(),
          max_bytes: nil | pos_integer()
        }
end
