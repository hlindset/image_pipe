import Config

if config_env() != :test do
  tracing = ImagePipeServer.Tracing.settings(System.get_env())

  config :image_pipe_server, tracing: tracing.enabled?
  if tracing.sdk != [], do: config(:opentelemetry, tracing.sdk)

  # Dependencies log while they start, before the server applies the
  # configuration, so the log settings apply here too.
  case ImagePipeServer.Config.log_settings(
         System.get_env(),
         ImagePipeServer.Application.default_config_path()
       ) do
    nil ->
      :ok

    %{log_format: :text} = log ->
      config :logger, level: log.log_level
      config :logger, :default_formatter, colors: [enabled: log.log_colors]

    log ->
      config :logger, level: log.log_level

      config :logger, :default_handler,
        formatter: ImagePipeServer.Application.log_formatter(log.log_format, false)
  end
end
