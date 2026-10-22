import Config

config :image_pipe_server, tracing: false

# Trace export stays off unless OTEL_* variables turn it on (see
# ImagePipeServer.Tracing); the SDK's OS variables override these.
config :opentelemetry,
  traces_exporter: :none,
  resource: [service: %{name: "image_pipe_server"}]

# `log_format` JSON goes through Elixir's own encoder, so the server needs
# no Jason.
config :logger_json, encoder: JSON

# Colors are off unless `log_colors` turns them on.
config :logger, :default_formatter,
  format: "$date $time $metadata[$level] $message\n",
  metadata: [:request_id],
  colors: [enabled: false]

# A request logs its line from its connection process, so the handler never
# makes that process wait: past 10,000 queued lines it drops new ones until it
# catches up, and logs when it starts and stops dropping. Sync mode starts at
# the same queue length as drop mode, so it never applies. A queued line costs
# its length plus about 300 bytes, so 10,000 lines of about 500 bytes hold
# about 8 MB. Past 20,000 the handler discards its whole queue. Under
# sustained overload the handler switches in and out of drop mode as the
# queue crosses the limit. OTP's burst limit, which drops lines past 500 a
# second without saying so, is off.
config :logger, :default_handler,
  config: [
    burst_limit_enable: false,
    sync_mode_qlen: 10_000,
    drop_mode_qlen: 10_000,
    flush_qlen: 20_000
  ]

# The sibling image_pipe_svg project builds its NIF from source; the Hex
# package downloads the precompiled one.
config :rustler_precompiled, :force_build,
  image_pipe_svg: System.get_env("IMAGE_PIPE_LIBS") != "hex"

import_config "#{config_env()}.exs"
