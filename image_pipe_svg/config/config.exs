import Config

# Build the NIF from source while developing the crate. A published package,
# and the release workflow's publish step (IMAGE_PIPE_SVG_PUBLISH=1), download
# the precompiled NIF instead.
config :image_pipe_svg,
  force_build: config_env() in [:dev, :test] and System.get_env("IMAGE_PIPE_SVG_PUBLISH") != "1"
