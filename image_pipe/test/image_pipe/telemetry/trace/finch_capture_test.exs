defmodule ImagePipe.Telemetry.Trace.FinchCaptureTest do
  use ExUnit.Case, async: false
  alias ImagePipe.Telemetry.Trace.{FinchCapture, Span}

  # A tiny in-test exporter module that forwards spans to the test process. The
  # production path is config-driven (`%{exporter: module}`); the test supplies a
  # module that sends to a pid stashed in :persistent_term so handle_event/4 can be
  # called directly without attaching to the real :finch telemetry events.
  defmodule SendExporter do
    @behaviour ImagePipe.Telemetry.Trace.Exporter
    @key {__MODULE__, :receiver}
    def set_receiver(pid), do: :persistent_term.put(@key, pid)
    @impl true
    def export(span) do
      send(:persistent_term.get(@key), {:span, span})
      :ok
    end
  end

  setup do
    SendExporter.set_receiver(self())
    :ok
  end

  test "builds a wire span parented from finch_private" do
    request = %{private: %{image_pipe_trace: {"trace123", "parentspan", 1}}}
    start_time = System.system_time()

    FinchCapture.handle_event(
      [:finch, :request, :stop],
      # system_time is in measurements (matching real Finch events), not metadata.
      %{duration: 10, system_time: start_time},
      %{name: TestFinch, request: request, result: {:ok, %{status: 200}}},
      %{exporter: SendExporter}
    )

    assert_receive {:span,
                    %Span{
                      name: "finch.request",
                      kind: :client,
                      trace_id: "trace123",
                      parent_span_id: "parentspan",
                      status: :ok,
                      duration_native: 10,
                      trace_flags: 1
                    } = span}

    assert span.attributes[:"http.status_code"] == 200
    assert is_integer(span.start_time) and span.start_time == start_time
  end

  test "carries the unsampled trace_flag from finch_private onto the wire span" do
    request = %{private: %{image_pipe_trace: {"trace123", "parentspan", 0}}}

    FinchCapture.handle_event(
      [:finch, :request, :stop],
      %{duration: 10, system_time: System.system_time()},
      %{name: TestFinch, request: request, result: {:ok, %{status: 200}}},
      %{exporter: SendExporter}
    )

    assert_receive {:span, %Span{name: "finch.request", trace_flags: 0}}
  end

  test "maps a finch error result to :error status" do
    request = %{private: %{image_pipe_trace: {"trace123", "parentspan", 1}}}

    FinchCapture.handle_event(
      [:finch, :request, :exception],
      # system_time in measurements, matching real Finch events.
      %{duration: 3, system_time: System.system_time()},
      %{name: TestFinch, request: request, kind: :error, reason: %RuntimeError{message: "x"}},
      %{exporter: SendExporter}
    )

    assert_receive {:span, %Span{name: "finch.request", status: :error}}
  end

  test "drops events with no image_pipe_trace in finch_private" do
    request = %{private: %{}}

    FinchCapture.handle_event(
      [:finch, :request, :stop],
      %{duration: 10, system_time: System.system_time()},
      %{name: TestFinch, request: request, result: {:ok, %{status: 200}}},
      %{exporter: SendExporter}
    )

    refute_receive {:span, _}
  end
end
