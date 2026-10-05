defmodule ImagePipe.Execution.Acquisition do
  @moduledoc false
  @enforce_keys [:record]
  defstruct [:record, :response, :lease, :source_bytes, :source_sha256, :processing]
end
