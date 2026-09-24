defmodule ImagePipe.Cache.Input.Snapshot do
  @moduledoc """
  An adapter-owned source revision and its validation evidence.

  `age_margin` is a conservative number of seconds added when evaluating retained
  evidence and response cache headers. Shared adapters use it for their supported
  inter-node clock skew. It never modifies the record or accumulates on adoption.
  """
  @enforce_keys [:revision, :record]
  defstruct @enforce_keys ++ [age_margin: 0]

  @type t :: %__MODULE__{
          revision: term(),
          record: ImagePipe.Source.Record.t() | nil,
          age_margin: non_neg_integer()
        }
end
