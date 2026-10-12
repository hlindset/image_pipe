import Config

# config :image_pipe, ImagePipe, ...

# image_pipe_svg is the sibling project here, which has no precompiled NIF to
# download, so build it from source.
config :rustler_precompiled, :force_build, image_pipe_svg: true

if config_env() == :test do
  # Simple processor, no real exporter; tests that read spans swap in
  # ImagePipe.Telemetry.Trace.TestExporter.
  config :opentelemetry,
    span_processor: :simple,
    traces_exporter: :none
end
