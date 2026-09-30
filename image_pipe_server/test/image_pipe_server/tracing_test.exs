defmodule ImagePipeServer.TracingTest do
  use ExUnit.Case, async: true

  alias ImagePipeServer.Tracing

  # ImagePipe checks for the OpenTelemetry API when it compiles; without it,
  # attaching the tracer at boot raises.
  test "the build includes the OpenTelemetry exporter" do
    assert ImagePipe.Telemetry.Trace.OpenTelemetryExporter.ready?()
  end

  test "is off without OTEL_* variables" do
    assert Tracing.settings(%{}) == %{enabled?: false, sdk: []}
  end

  test "an OTLP endpoint turns on OTLP export" do
    for var <- ["OTEL_EXPORTER_OTLP_ENDPOINT", "OTEL_EXPORTER_OTLP_TRACES_ENDPOINT"] do
      assert Tracing.settings(%{var => "http://collector:4318"}) ==
               %{enabled?: true, sdk: [traces_exporter: :otlp]}
    end
  end

  test "OTEL_TRACES_EXPORTER chooses the exporter, which the SDK reads itself" do
    assert Tracing.settings(%{"OTEL_TRACES_EXPORTER" => "console"}) == %{enabled?: true, sdk: []}

    assert Tracing.settings(%{
             "OTEL_TRACES_EXPORTER" => "none",
             "OTEL_EXPORTER_OTLP_ENDPOINT" => "http://collector:4318"
           }) == %{enabled?: false, sdk: []}
  end

  test "OTEL_SDK_DISABLED turns it off" do
    assert Tracing.settings(%{
             "OTEL_SDK_DISABLED" => "true",
             "OTEL_EXPORTER_OTLP_ENDPOINT" => "http://collector:4318"
           }) == %{enabled?: false, sdk: []}
  end
end
