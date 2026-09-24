defmodule ImagePipe.Cache.Input.Snapshot do
  @moduledoc "An adapter-owned source revision and its validation evidence."
  @enforce_keys [:revision, :record]
  defstruct @enforce_keys

  @type t :: %__MODULE__{revision: term(), record: ImagePipe.Source.Record.t() | nil}
end
