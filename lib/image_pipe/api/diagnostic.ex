defmodule ImagePipe.API.Diagnostic do
  @moduledoc """
  A structured URL validation failure with byte spans.

  `ImagePipe.API.Path` and `ImagePipe.API.Parser` accumulate independent
  failures. `ImagePipe.API.DiagnosticRenderer` renders them as a caret
  display in the `400` response body.
  """

  @enforce_keys [:reason, :message, :spans]
  defstruct @enforce_keys

  @type span :: {byte_offset :: non_neg_integer(), byte_length :: non_neg_integer()}

  @type t :: %__MODULE__{
          # Stable across a release — tests match on it.
          reason: atom(),
          # One-line, human-readable label rendered under the diagnostic's
          # carets (e.g. "unknown option").
          message: String.t(),
          # Byte spans into the raw mount-relative path. Multiple spans identify
          # related segments, such as duplicate or mutually exclusive options.
          spans: [span(), ...]
        }
end
