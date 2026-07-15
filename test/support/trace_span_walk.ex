defmodule ImagePipe.Test.Trace.SpanWalk do
  @moduledoc """
  Test-only helpers for collecting `TestExporter`-forwarded spans and
  asserting one is a transitive descendant of a request root, walking
  `parent_span_id` links.

  Shared by the delivery-primitive and native-dialect trace-parentage tests
  (`ImagePipe.Delivery.TraceParentageTest`,
  `ImagePipe.Telemetry.NativeDeliverySpanParentageTest`). The framework's own
  D3 topology-gate baseline
  (`ImagePipe.Telemetry.DeliverySpanParentageBaselineTest`) is IMMUTABLE and
  deliberately keeps its own private copy rather than depending on this
  module — it must not be able to change out from under that gate.
  """

  alias ImagePipe.Telemetry.Trace.Span

  @doc "Drain all `{:span, %Span{}}` messages sent to the calling process."
  @spec collect(timeout()) :: [Span.t()]
  def collect(timeout \\ 300) do
    receive do
      {:span, %Span{} = s} -> [s | collect(timeout)]
    after
      timeout -> []
    end
  end

  @doc """
  True if `span` is a transitive descendant of `root`, walking
  `parent_span_id` links through `by_span_id` (a map of span_id => span).
  """
  @spec descendant_of_root?(Span.t(), Span.t(), %{optional(term()) => Span.t()}) :: boolean()
  def descendant_of_root?(%Span{} = span, %Span{span_id: root_id}, by_span_id),
    do: walk_to_root(span.parent_span_id, root_id, by_span_id)

  defp walk_to_root(nil, _root_id, _by_span_id), do: false
  defp walk_to_root(id, root_id, _by_span_id) when id == root_id, do: true

  defp walk_to_root(id, root_id, by_span_id) do
    case Map.fetch(by_span_id, id) do
      {:ok, %Span{parent_span_id: parent_id}} -> walk_to_root(parent_id, root_id, by_span_id)
      :error -> false
    end
  end
end
