defmodule ImagePipe.Output.Skipped do
  @moduledoc false

  # The output of a request whose source is delivered unchanged: its bytes
  # are the source bytes, so no encoder settings apply and nothing is stored
  # in the output cache.

  alias ImagePipe.Output.Policy

  @enforce_keys [:format, :response_headers]
  defstruct @enforce_keys

  @type t :: %__MODULE__{
          format: ImagePipe.Format.source_format(),
          response_headers: [{String.t(), String.t()}]
        }

  @spec new(Policy.t(), ImagePipe.Format.source_format()) :: t()
  def new(%Policy{headers: headers}, format) do
    %__MODULE__{
      format: format,
      response_headers: headers ++ [{"x-content-type-options", "nosniff"}]
    }
  end
end
