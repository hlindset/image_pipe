defmodule ImagePipe.Test.Trace.TestExporter do
  @moduledoc """
  Test-only OpenTelemetry SDK exporter. It converts each finished span to an
  `ImagePipe.Test.Trace.Span` and sends it to the receiver as
  `{:span, span}`.

  Spans end in several processes and the SDK exports them from its own
  process, so the receiver pid is global, kept in `:persistent_term`. Every
  test module using this must be `async: false`, and `attach/2` clears the
  receiver on exit.
  """
  @behaviour :otel_exporter_traces

  require Record

  alias ImagePipe.Test.Trace.Span

  Record.defrecordp(
    :span,
    Record.extract(:span, from_lib: "opentelemetry/include/otel_span.hrl")
  )

  Record.defrecordp(
    :event,
    Record.extract(:event, from_lib: "opentelemetry/include/otel_span.hrl")
  )

  Record.defrecordp(
    :status,
    Record.extract(:status, from_lib: "opentelemetry_api/include/opentelemetry.hrl")
  )

  @key {__MODULE__, :receiver}

  @doc """
  Attaches the tracer with `opts` and routes finished spans to `test_pid`.
  Must run inside a test or setup, which owns the `on_exit/1` it registers.
  """
  def attach(test_pid, opts \\ []) do
    :persistent_term.put(@key, test_pid)
    :ok = :otel_simple_processor.set_exporter(__MODULE__, [])
    ImagePipe.Telemetry.attach_tracer(opts)

    ExUnit.Callbacks.on_exit(fn ->
      ImagePipe.Telemetry.detach_tracer()
      :persistent_term.put(@key, nil)
    end)
  end

  @doc """
  Opens a span in the calling process and makes it current, as a host's own
  instrumentation would. Returns its hexadecimal `trace_id` and `span_id`.
  """
  def open_span(name \\ "test") do
    context = :otel_ctx.get_current()
    tracer = :opentelemetry.get_tracer(:image_pipe_test)
    span_ctx = :otel_tracer.start_span(context, tracer, name, %{})
    :otel_ctx.attach(:otel_tracer.set_current_span(context, span_ctx))
    %{trace_id: :otel_span.hex_trace_id(span_ctx), span_id: :otel_span.hex_span_id(span_ctx)}
  end

  @doc "Drains the `{:span, span}` messages sent to the calling process."
  def collect(timeout \\ 300) do
    receive do
      {:span, %Span{} = span} -> [span | collect(timeout)]
    after
      timeout -> []
    end
  end

  @impl true
  def init(_config), do: {:ok, nil}

  @impl true
  def export(table, _resource, _state) do
    case :persistent_term.get(@key, nil) do
      nil -> :ok
      pid -> :ets.foldl(fn record, acc -> send_span(pid, record, acc) end, :ok, table)
    end

    :ok
  end

  @impl true
  def shutdown(_state), do: :ok

  defp send_span(pid, record, acc) do
    send(pid, {:span, to_span(record)})
    acc
  end

  defp to_span(record) do
    start_time = span(record, :start_time)
    end_time = span(record, :end_time)

    %Span{
      trace_id: hex(span(record, :trace_id), 32),
      span_id: hex(span(record, :span_id), 16),
      parent_span_id: hex(span(record, :parent_span_id), 16),
      parent_span_is_remote: span(record, :parent_span_is_remote) == true,
      name: to_string(span(record, :name)),
      kind: span(record, :kind),
      start_time: start_time,
      end_time: end_time,
      duration_native: end_time - start_time,
      trace_flags: span(record, :trace_flags),
      attributes: :otel_attributes.map(span(record, :attributes)),
      events: Enum.map(:otel_events.list(span(record, :events)), &to_event/1),
      status: status_code(span(record, :status)),
      status_message: status_message(span(record, :status))
    }
  end

  defp to_event(record) do
    %{
      name: to_string(event(record, :name)),
      time: event(record, :system_time_native),
      attributes: :otel_attributes.map(event(record, :attributes))
    }
  end

  defp status_code(:undefined), do: :unset
  defp status_code(record), do: status(record, :code)

  defp status_message(:undefined), do: nil
  defp status_message(record), do: status(record, :message)

  defp hex(id, _width) when id in [nil, :undefined], do: nil

  defp hex(id, width),
    do: id |> Integer.to_string(16) |> String.downcase() |> String.pad_leading(width, "0")
end
