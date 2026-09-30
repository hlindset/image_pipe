defmodule ImagePipe.Plan.Source.Reference do
  @moduledoc """
  Immutable external source reference.

  Fetching references is intentionally deferred; this struct exists so parsers
  and custom translators can target the planned shape.
  """

  @enforce_keys [:adapter, :id]
  defstruct [:adapter, :id, :revision, metadata: []]

  @type t :: %__MODULE__{
          adapter: atom(),
          id: String.t(),
          revision: String.t() | nil,
          metadata: keyword()
        }
end
