defmodule ImagePipe.Telemetry.Trace.FinchHandlerTest do
  use ExUnit.Case, async: false
  alias ImagePipe.Test.Trace.{Span, TestExporter}

  setup do
    TestExporter.attach(self())
    parent = TestExporter.open_span()
    %{parent: parent, request: %{private: %{image_pipe_trace: :otel_tracer.current_span_ctx()}}}
  end

  test "records a Finch span under the client span in finch_private", ctx do
    :telemetry.execute(
      [:finch, :request, :stop],
      %{duration: 10},
      %{name: TestFinch, request: ctx.request, result: {:ok, %{status: 200}}}
    )

    trace_id = ctx.parent.trace_id
    parent_span_id = ctx.parent.span_id

    assert_receive {:span,
                    %Span{
                      name: "finch.request",
                      kind: :client,
                      trace_id: ^trace_id,
                      parent_span_id: ^parent_span_id,
                      status: :unset,
                      duration_native: 10
                    } = span}

    assert span.attributes[:"http.status_code"] == 200
  end

  test "maps a Finch exception to :error status", ctx do
    :telemetry.execute(
      [:finch, :connect, :exception],
      %{duration: 3},
      %{name: TestFinch, request: ctx.request, kind: :error, reason: %RuntimeError{message: "x"}}
    )

    assert_receive {:span, %Span{name: "finch.connect", status: :error}}
  end

  test "drops events with no client span in finch_private" do
    :telemetry.execute(
      [:finch, :request, :stop],
      %{duration: 10},
      %{name: TestFinch, request: %{private: %{}}, result: {:ok, %{status: 200}}}
    )

    refute_receive {:span, %Span{name: "finch.request"}}, 100
  end
end
