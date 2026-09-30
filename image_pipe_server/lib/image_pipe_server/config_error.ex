defmodule ImagePipeServer.ConfigError do
  @moduledoc """
  Raised at boot for invalid server configuration.

  Messages name the offending setting or variable. The loader's own messages
  never quote a value. Messages from the library's validation may quote a
  non-secret value, such as an out-of-range quality or a cache root, but never
  a secret: signing and encryption keys, credentials, tokens, or the contents
  of a `_FILE`.
  """

  defexception [:message]
end
