defmodule ImagePipe.Telemetry.Trace.Context do
  @moduledoc """
  Immutable, serializable trace context that crosses process/node/HTTP seams.

  Carries the current span identity so a far-side process (or downstream service)
  can attach children under it. `span_id` becomes the child's `parent_span_id`.
  """

  @enforce_keys [:trace_id, :span_id]
  defstruct [:trace_id, :span_id, trace_flags: 1, baggage: %{}]

  @type t :: %__MODULE__{
          trace_id: String.t(),
          span_id: String.t(),
          trace_flags: non_neg_integer(),
          baggage: %{optional(String.t()) => String.t()}
        }
end
