# This file is responsible for configuring your application
# and its dependencies with the aid of the Config module.
#
# This configuration file is loaded before any dependency and
# is restricted to this project.

# General application configuration
import Config

# No precompiled NIF is published for the pinned ssimulacra2/butteraugli git refs
# (pulled in transitively via the image_pipe path dependency), so build the Rust
# NIFs from source via RustlerPrecompiled's force-build path.
config :ssimulacra2, :force_build, true
config :butteraugli, :force_build, true

config :image_pipe_fiddle,
  generators: [timestamp_type: :utc_datetime]

config :image_pipe_fiddle, :imgproxy,
  signature: [
    keys: ["736563726574"],
    salts: ["68656c6c6f"],
    trusted_signatures: ["_", "unsafe"]
  ],
  smart_crop_face_detection: true

# Connection coordinates for the fiddle's S3 source type, served by the opt-in
# s3proxy compose service (see fiddle/docker-compose.yml). These mirror the
# s3proxy env: bucket "sources" == priv/static/images. Dev-only fake credentials.
config :image_pipe_fiddle, :s3_source,
  region: "us-east-1",
  endpoint: "http://localhost:8081",
  access_key_id: "fiddle",
  secret_access_key: "fiddlesecret"

# Configure the endpoint
config :image_pipe_fiddle, ImagePipeFiddleWeb.Endpoint,
  url: [host: "localhost"],
  adapter: Bandit.PhoenixAdapter,
  render_errors: [
    formats: [html: ImagePipeFiddleWeb.ErrorHTML, json: ImagePipeFiddleWeb.ErrorJSON],
    layout: false
  ],
  pubsub_server: ImagePipeFiddle.PubSub,
  live_view: [signing_salt: "xkAPZxMW"]

# Configure Elixir's Logger
config :logger, :default_formatter,
  format: "$time $metadata[$level] $message\n",
  metadata: [:request_id]

# Use Jason for JSON parsing in Phoenix
config :phoenix, :json_library, Jason

# OpenTelemetry → local Jaeger (see docker-compose.yml). Traces are only emitted
# when the tracer is attached at startup (FIDDLE_OTEL=1; see
# ImagePipeFiddle.Application) — with no spans the SDK never contacts the collector,
# so this is inert for a plain `mise run fiddle` with no Jaeger running.
config :opentelemetry,
  span_processor: :batch,
  traces_exporter: :otlp,
  resource: [service: %{name: "image_pipe_fiddle"}]

config :opentelemetry_exporter,
  otlp_protocol: :http_protobuf,
  otlp_endpoint: "http://localhost:4318"

# Import environment specific config. This must remain at the bottom
# of this file so it overrides the configuration defined above.
import_config "#{config_env()}.exs"
