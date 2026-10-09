defmodule ImagePipe.Test.Trace.Span do
  @moduledoc """
  A finished OpenTelemetry span as `ImagePipe.Test.Trace.TestExporter`
  delivers it: hexadecimal IDs, attribute and event maps, and the status
  code (`:unset`, `:ok`, or `:error`). Times are native monotonic.
  """

  defstruct [
    :trace_id,
    :span_id,
    :parent_span_id,
    :parent_span_is_remote,
    :name,
    :kind,
    :start_time,
    :end_time,
    :duration_native,
    :trace_flags,
    :status,
    :status_message,
    attributes: %{},
    events: []
  ]

  @type t :: %__MODULE__{}
end
