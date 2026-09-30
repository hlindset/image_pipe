defmodule ImagePipe.Telemetry.Trace.Span do
  @moduledoc """
  A captured span handed to an `ImagePipe.Telemetry.Trace.Exporter`.

  OTel-shaped so a Jaeger/Tempo/OTLP mapping is mechanical. `duration_native` is the
  honest timing source (raw monotonic units from `:telemetry.span/3`); `start_time`/
  `end_time` are wall-clock (`system_time`) for export.

  `root` marks the span that opened its trace in this node (set even when an inbound W3C
  parent gives it a remote `parent_span_id`).
  """

  @enforce_keys [:trace_id, :span_id, :name, :start_time]
  defstruct [
    :trace_id,
    :span_id,
    :parent_span_id,
    :name,
    :kind,
    :start_time,
    :end_time,
    :duration_native,
    :status,
    :status_message,
    :pid,
    :node,
    trace_flags: 1,
    root: false,
    attributes: %{},
    events: [],
    links: []
  ]

  @type t :: %__MODULE__{
          trace_id: String.t(),
          span_id: String.t(),
          parent_span_id: String.t() | nil,
          name: String.t(),
          kind: :internal | :server | :client | nil,
          start_time: integer() | nil,
          end_time: integer() | nil,
          duration_native: integer() | nil,
          status: :unset | :ok | :error | nil,
          status_message: String.t() | nil,
          pid: pid() | nil,
          node: node() | nil,
          trace_flags: non_neg_integer(),
          root: boolean(),
          attributes: map(),
          events: [map()],
          links: [map()]
        }
end
