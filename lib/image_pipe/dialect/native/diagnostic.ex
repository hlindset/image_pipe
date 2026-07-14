defmodule ImagePipe.Dialect.Native.Diagnostic do
  @moduledoc """
  A single structured diagnostic for the native URL dialect's error
  reporting [native §Error diagnostics].

  Producers (`ImagePipe.Dialect.Native.Path`, `ImagePipe.Dialect.Native.Parser`)
  build one `%Diagnostic{}` per independent validation failure — errors
  accumulate across a request rather than stopping at the first one.
  `ImagePipe.Dialect.Native.DiagnosticRenderer` turns an accumulated list
  into the compiler-style caret display that becomes the `400` response
  body.
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
          # One or more byte spans into the raw mount-relative request
          # path. More than one span means the diagnostic is about a
          # relationship between multiple segments (a duplicate key, a
          # mutually exclusive pair), not a single segment.
          spans: [span(), ...]
        }
end
