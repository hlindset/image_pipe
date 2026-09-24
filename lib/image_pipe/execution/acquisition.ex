defmodule ImagePipe.Execution.Acquisition do
  @moduledoc false
  @enforce_keys [:record]
  defstruct [:record, :source_revision, :response, :lease, :source_bytes, :processing]
end
