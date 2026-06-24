import Config

# config :image_pipe, ImagePipe, ...

# No precompiled NIF is published for the pinned ssimulacra2 git ref, so build the
# Rust NIF from source via RustlerPrecompiled's force-build path.
config :ssimulacra2, :force_build, true

# No precompiled NIF is published for the pinned butteraugli git ref, so build the
# Rust NIF from source via RustlerPrecompiled's force-build path.
config :butteraugli, :force_build, true

if config_env() == :test do
  # Synchronous simple processor, no real exporter; tests swap in a pid exporter
  # per-test via :otel_simple_processor.set_exporter/2.
  config :opentelemetry,
    span_processor: :simple,
    traces_exporter: :none
end
