defmodule ImagePipeServer.ConfigError do
  @moduledoc """
  Raised at boot for invalid server configuration.

  Messages name the offending setting or variable, never its value.
  """

  defexception [:message]
end
