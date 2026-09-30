import Config

if config_env() != :test do
  tracing = ImagePipeServer.Tracing.settings(System.get_env())

  config :image_pipe_server, tracing: tracing.enabled?
  if tracing.sdk != [], do: config(:opentelemetry, tracing.sdk)
end
