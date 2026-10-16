defmodule ImagePipe.Execution.Acquisition do
  @moduledoc false
  @enforce_keys [:record]
  # `buffered` says why the original is held in memory instead of a staged
  # file: `:dir`, `:open`, or `:write`.
  defstruct [:record, :response, :lease, :source_bytes, :source_sha256, :processing, :buffered]
end
