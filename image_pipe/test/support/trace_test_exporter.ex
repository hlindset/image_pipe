defmodule ImagePipe.Telemetry.Trace.TestExporter do
  @moduledoc """
  Test-only exporter. Spans are exported from MULTIPLE processes (the delivery
  producer and coordinator), so the receiver pid must be reachable globally — we use
  :persistent_term. REQUIREMENT: every test module using this must be `async: false`
  (ExUnit runs async:false modules with no concurrent test), and must clear the
  receiver in on_exit to keep the global key from leaking across modules.
  """
  @behaviour ImagePipe.Telemetry.Trace.Exporter

  @key {__MODULE__, :receiver}

  @doc "Attach the tracer with this exporter and route spans to `test_pid`."
  def attach(test_pid, opts \\ []) do
    set_receiver(test_pid)
    ImagePipe.Telemetry.attach_tracer(Keyword.merge([exporter: __MODULE__], opts))
  end

  def set_receiver(pid), do: :persistent_term.put(@key, pid)
  def clear_receiver, do: :persistent_term.put(@key, nil)

  @impl true
  def export(span) do
    case :persistent_term.get(@key, nil) do
      nil -> :ok
      pid -> send(pid, {:span, span})
    end

    :ok
  end
end
