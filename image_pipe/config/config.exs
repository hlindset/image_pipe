import Config

# config :image_pipe, ImagePipe, ...

if config_env() == :test do
  # Synchronous simple processor, no real exporter; tests swap in a pid exporter
  # per-test via :otel_simple_processor.set_exporter/2.
  config :opentelemetry,
    span_processor: :simple,
    traces_exporter: :none
end
