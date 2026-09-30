defmodule ImagePipe.Telemetry.Trace.AttachTest do
  use ExUnit.Case, async: false
  alias ImagePipe.Telemetry
  alias ImagePipe.Telemetry.Trace.LogExporter
  alias ImagePipe.Telemetry.Trace.TestExporter

  defmodule NotReadyExporter do
    @behaviour ImagePipe.Telemetry.Trace.Exporter
    @impl true
    def export(_span), do: :ok
    @impl true
    def ready?, do: false
  end

  setup do
    on_exit(fn -> Telemetry.detach_tracer() end)
    :ok
  end

  test "attach_tracer succeeds with a valid exporter" do
    assert Telemetry.attach_tracer(exporter: LogExporter) == :ok
  end

  test "reattaching applies disabled and reenabled Finch capture" do
    prefix = [:attach_test, :finch_toggle]
    on_exit(&TestExporter.clear_receiver/0)
    TestExporter.attach(self(), prefix: prefix)

    metadata = %{
      request: %{private: %{image_pipe_trace: {"attach-toggle", "parent", 1}}},
      result: {:ok, %{status: 200}}
    }

    measurements = %{duration: 10, system_time: System.system_time()}
    :telemetry.execute([:finch, :request, :stop], measurements, metadata)
    assert_received {:span, %{name: "finch.request", trace_id: "attach-toggle"}}

    TestExporter.attach(self(), prefix: prefix, finch_spans: false)
    :telemetry.execute([:finch, :request, :stop], measurements, metadata)
    refute_received {:span, %{name: "finch.request", trace_id: "attach-toggle"}}

    TestExporter.attach(self(), prefix: prefix, finch_spans: true)
    :telemetry.execute([:finch, :request, :stop], measurements, metadata)
    assert_received {:span, %{name: "finch.request", trace_id: "attach-toggle"}}
  end

  test "attach_tracer raises on unknown option" do
    assert_raise ArgumentError, fn ->
      Telemetry.attach_tracer(exporter: LogExporter, bogus: 1)
    end
  end

  test "attach_tracer raises when exporter is missing" do
    assert_raise ArgumentError, fn -> Telemetry.attach_tracer([]) end
  end

  test "attach_tracer raises when exporter module is not loadable" do
    assert_raise ArgumentError, fn -> Telemetry.attach_tracer(exporter: NotARealModule) end
  end

  test "attach_tracer raises when module is loadable but does not export export/1" do
    assert_raise ArgumentError, fn -> Telemetry.attach_tracer(exporter: Enum) end
  end

  test "attach_tracer raises ArgumentError on a non-list argument" do
    assert_raise ArgumentError, fn -> Telemetry.attach_tracer(:not_a_list) end
  end

  test "attach_tracer raises when the exporter reports not ready" do
    assert_raise ArgumentError, ~r/not ready/, fn ->
      Telemetry.attach_tracer(exporter: NotReadyExporter)
    end
  end
end
