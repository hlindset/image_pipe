import Config

config :image_pipe_server, default_config_path: "/etc/image_pipe/config.toml"

import_config "#{config_env()}.exs"
