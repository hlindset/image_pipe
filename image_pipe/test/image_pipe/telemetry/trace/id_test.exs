defmodule ImagePipe.Telemetry.Trace.IdTest do
  use ExUnit.Case, async: true
  alias ImagePipe.Telemetry.Trace.Id

  test "trace_id is 32 lowercase hex chars and unique" do
    a = Id.trace_id()
    b = Id.trace_id()
    assert a =~ ~r/\A[0-9a-f]{32}\z/
    assert a != b
  end

  test "span_id is 16 lowercase hex chars and unique" do
    a = Id.span_id()
    assert a =~ ~r/\A[0-9a-f]{16}\z/
    assert a != Id.span_id()
  end
end
