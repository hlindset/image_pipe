defmodule ImagePipe.Execution.Watermark do
  @moduledoc false
  # One watermark asset acquired as an additional request input. `asset` is the
  # group intent's asset reference, `opacity` the host base opacity. `record`
  # and `input_key` are set when the input cache serves the source; `bytes`
  # holds the body once fetched or opened.
  @enforce_keys [:asset, :source, :opacity]
  defstruct [:asset, :source, :opacity, :input_key, :record, :bytes]

  def byte_identity(%__MODULE__{record: nil, source: source}),
    do: source.cache_semantics.byte_identity

  def byte_identity(%__MODULE__{record: record}), do: record.byte_identity
end
