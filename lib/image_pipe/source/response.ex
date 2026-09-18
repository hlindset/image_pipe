defmodule ImagePipe.Source.Response do
  @moduledoc """
  Source bytes returned by an `ImagePipe.Source` adapter.

  Exactly one of `stream` or `path` must be present. Streams are consumed
  lazily and must release their resources when enumeration halts.
  """

  defstruct stream: nil, path: nil

  @type t :: %__MODULE__{
          stream: Enumerable.t() | nil,
          path: Path.t() | nil
        }
end
