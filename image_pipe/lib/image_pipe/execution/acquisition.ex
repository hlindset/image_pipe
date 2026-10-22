defmodule ImagePipe.Execution.Acquisition do
  @moduledoc false
  @enforce_keys [:record]
  # `buffered` says why the original is held in memory instead of a staged
  # file: `:dir`, `:open`, or `:write`.
  # `processing_deadline` is the deadline of the pool turn an overlapped
  # decode ran in, which its encode continues with.
  defstruct [
    :record,
    :response,
    :lease,
    :source_bytes,
    :processing,
    :processing_deadline,
    :buffered
  ]
end
