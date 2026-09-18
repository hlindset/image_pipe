import Config

config :image_pipe_fiddle, :loopback_http_source, true

# We don't run a server during test. If one is required,
# you can enable the server option below.
config :image_pipe_fiddle, ImagePipeFiddleWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4002],
  secret_key_base: "e1Yubizla9k4NeIckhHYsBzBHM3PSG1EyyIT/p/qOjxgW2TLGleXo5wkJZFRciR3",
  server: false

# Print only warnings and errors during test
config :logger, level: :warning

# Never export OpenTelemetry traces during tests.
config :opentelemetry, traces_exporter: :none

# Initialize plugs at runtime for faster test compilation
config :phoenix, :plug_init_mode, :runtime

# Enable helpful, but potentially expensive runtime checks
config :phoenix_live_view,
  enable_expensive_runtime_checks: true

# Sort query params output of verified routes for robust url comparisons
config :phoenix,
  sort_verified_routes_query_params: true
