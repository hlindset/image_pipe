defmodule ImagePipe.Telemetry.Trace.Stack do
  @moduledoc false
  alias ImagePipe.Telemetry.Trace.{Context, Span}

  @key :"$image_pipe_trace_stack"

  @spec current() :: Span.t() | nil
  def current, do: List.first(stack())

  @spec push(Span.t()) :: :ok
  def push(%Span{} = span), do: put([span | stack()])

  @spec pop() :: Span.t() | nil
  def pop do
    case stack() do
      [top | rest] ->
        put(rest)
        top

      [] ->
        nil
    end
  end

  @spec context() :: Context.t() | nil
  def context do
    case current() do
      nil ->
        nil

      %Span{trace_id: t, span_id: s, trace_flags: f} ->
        %Context{trace_id: t, span_id: s, trace_flags: f}
    end
  end

  # Seed the far side of a process hop with a synthetic remote-parent frame.
  @spec adopt(Context.t() | nil) :: :ok
  def adopt(nil), do: :ok

  def adopt(%Context{trace_id: t, span_id: s, trace_flags: f}) do
    push(%Span{trace_id: t, span_id: s, name: "remote_parent", start_time: nil, trace_flags: f})
  end

  @spec clear() :: :ok
  def clear, do: put([])

  defp stack, do: Process.get(@key, [])

  defp put(stack) do
    Process.put(@key, stack)
    :ok
  end
end
