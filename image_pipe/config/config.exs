import Config

# config :image_pipe, ImagePipe, ...

# The sibling image_pipe_svg project has no released precompiled NIF to
# download yet, so build it from source.
config :image_pipe_svg, force_build: true

if config_env() == :test do
  # Simple processor, no real exporter; tests that read spans swap in
  # ImagePipe.Telemetry.Trace.TestExporter.
  config :opentelemetry,
    span_processor: :simple,
    traces_exporter: :none
end
