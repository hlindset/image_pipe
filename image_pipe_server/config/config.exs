import Config

config :image_pipe_server,
  default_config_path: "/etc/image_pipe/config.toml",
  tracing: false

# Trace export stays off unless OTEL_* variables turn it on (see
# ImagePipeServer.Tracing); the SDK's OS variables override these.
config :opentelemetry,
  traces_exporter: :none,
  resource: [service: %{name: "image_pipe_server"}],
  id_generator: ImagePipe.Telemetry.Trace.OtelIdGenerator

import_config "#{config_env()}.exs"
