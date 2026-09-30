import Config

config :image_pipe_server,
  port: 8080,
  bind: "0.0.0.0",
  mount_path: "/",
  image_pipe: []

import_config "#{config_env()}.exs"
