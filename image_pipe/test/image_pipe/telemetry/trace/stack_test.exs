defmodule ImagePipe.Telemetry.Trace.StackTest do
  use ExUnit.Case, async: true
  alias ImagePipe.Telemetry.Trace.{Context, Span, Stack}

  defp span(name), do: %Span{trace_id: "t", span_id: name, name: name, start_time: 0}

  setup do
    on_exit(fn -> Stack.clear() end)
    Stack.clear()
    :ok
  end

  test "push/current/pop are LIFO" do
    assert Stack.current() == nil
    Stack.push(span("a"))
    Stack.push(span("b"))
    assert Stack.current().span_id == "b"
    assert Stack.pop().span_id == "b"
    assert Stack.current().span_id == "a"
    assert Stack.pop().span_id == "a"
    assert Stack.pop() == nil
  end

  test "nested-then-sibling preserves parentage order" do
    Stack.push(span("root"))
    Stack.push(span("child1"))
    assert Stack.pop().span_id == "child1"
    # sibling: parent is root again
    assert Stack.current().span_id == "root"
    Stack.push(span("child2"))
    assert Stack.current().span_id == "child2"
  end

  test "context/0 snapshots the current span identity" do
    assert Stack.context() == nil
    Stack.push(%Span{trace_id: "abc", span_id: "def", name: "x", start_time: 0})
    assert %Context{trace_id: "abc", span_id: "def"} = Stack.context()
  end

  test "adopt/1 seeds a remote-parent frame; next span inherits it" do
    Stack.adopt(%Context{trace_id: "rt", span_id: "rs", trace_flags: 1})
    assert %Context{trace_id: "rt", span_id: "rs"} = Stack.context()
    # a child pushed now would read current() as its parent
    assert Stack.current().span_id == "rs"
  end

  test "adopt(nil) is a no-op" do
    Stack.adopt(nil)
    assert Stack.current() == nil
  end
end
