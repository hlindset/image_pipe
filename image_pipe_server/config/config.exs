import Config

config :image_pipe_server,
  default_config_path: "/etc/image_pipe/config.toml",
  tracing: false

# Trace export stays off unless OTEL_* variables turn it on (see
# ImagePipeServer.Tracing); the SDK's OS variables override these.
config :opentelemetry,
  traces_exporter: :none,
  resource: [service: %{name: "image_pipe_server"}]

config :logger, :default_formatter, metadata: [:request_id]

# The sibling image_pipe_svg project builds its NIF from source; the Hex
# package downloads the precompiled one.
config :image_pipe_svg, force_build: System.get_env("IMAGE_PIPE_LIBS") != "hex"

import_config "#{config_env()}.exs"
