import Config

config :image_pipe_server,
  default_config_path: "/etc/image_pipe/config.toml",
  tracing: false

# Trace export stays off unless OTEL_* variables turn it on (see
# ImagePipeServer.Tracing); the SDK's OS variables override these.
config :opentelemetry,
  traces_exporter: :none,
  resource: [service: %{name: "image_pipe_server"}]

# `log_format` JSON goes through Elixir's own encoder, so the server needs
# no Jason.
config :logger_json, encoder: JSON

config :logger, :default_formatter,
  format: "$date $time $metadata[$level] $message\n",
  metadata: [:request_id]

# The sibling image_pipe_svg project builds its NIF from source; the Hex
# package downloads the precompiled one.
config :rustler_precompiled, :force_build,
  image_pipe_svg: System.get_env("IMAGE_PIPE_LIBS") != "hex"

import_config "#{config_env()}.exs"
