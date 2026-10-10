defmodule ImagePipe.Source.Path do
  @moduledoc """
  Root-relative path source.

  `scheme` is set when the path was written with a custom scheme
  (`asset://catalog/42`), which the server routes like a path prefix. It is
  `nil` for bare paths.
  """

  @enforce_keys [:segments]
  defstruct [:segments, scheme: nil]

  @type t :: %__MODULE__{segments: [String.t()], scheme: String.t() | nil}
end
