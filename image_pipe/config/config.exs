import Config

# config :image_pipe, ImagePipe, ...

if config_env() == :test do
  # Simple processor, no real exporter; tests that read spans swap in
  # ImagePipe.Telemetry.Trace.TestExporter.
  config :opentelemetry,
    span_processor: :simple,
    traces_exporter: :none
end
