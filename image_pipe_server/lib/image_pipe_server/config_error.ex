defmodule ImagePipeServer.ConfigError do
  @moduledoc """
  Raised by `ImagePipeServer.Config.load!/2` for invalid server configuration.
  At boot, the server prints the message and exits with status 1.

  Messages name the offending setting or variable. The loader's own messages
  never quote a value. Messages from the library's validation may quote a
  non-secret value, such as an out-of-range quality or a cache root, but never
  a secret: signing and encryption keys, credentials, tokens, or the contents
  of a `_FILE`.
  """

  defexception [:message]
end
