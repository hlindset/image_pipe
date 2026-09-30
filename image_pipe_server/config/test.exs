import Config

config :image_pipe_server,
  default_config_path: Path.expand("../test/support/server.toml", __DIR__)
