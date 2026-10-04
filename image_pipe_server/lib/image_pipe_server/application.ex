defmodule ImagePipeServer.Application do
  @moduledoc false

  use Application

  alias ImagePipeServer.Config
  alias ImagePipeServer.ConfigError

  @listener __MODULE__.Listener
  @instance ImagePipeServer.ImagePipe

  @impl Application
  def start(_type, _args) do
    config = config!()

    if config.telemetry, do: ImagePipe.Telemetry.attach_default_logger(config.telemetry)

    if Application.fetch_env!(:image_pipe_server, :tracing) do
      ImagePipe.Telemetry.attach_tracer(tracer_options(config))
    end

    Supervisor.start_link(children(config),
      strategy: :one_for_one,
      name: ImagePipeServer.Supervisor
    )
  end

  # An invalid configuration stops the node with its message alone, without
  # a crash report.
  defp config! do
    Config.load!(
      System.get_env(),
      Application.fetch_env!(:image_pipe_server, :default_config_path)
    )
  rescue
    error in ConfigError ->
      IO.puts(:stderr, Exception.message(error))
      System.halt(1)
  end

  @doc false
  def listener, do: @listener

  @doc false
  @spec tracer_options(Config.t()) :: keyword()
  def tracer_options(%Config{} = config) do
    [
      exporter: ImagePipe.Telemetry.Trace.OpenTelemetryExporter,
      extract_inbound: config.trust_traceparent
    ]
  end

  # Children stop in reverse order, so the listener, started last, drains
  # in-flight requests before the pool and the ImagePipe instance stop.
  @doc false
  @spec children(Config.t()) :: [Supervisor.child_spec() | {module(), term()}]
  def children(%Config{} = config) do
    pool(config.pool) ++
      [{ImagePipe, name: @instance, config: config.image_pipe}] ++
      Enum.map(config.credential_warmups, &{ImagePipe.Source.S3.CredentialWarmup, &1}) ++
      [http_child(config, {ImagePipeServer.Router, router_options(config)})]
  end

  @doc false
  @spec router_options(Config.t()) :: keyword()
  def router_options(%Config{} = config) do
    [
      mount_path: Keyword.fetch!(config.server, :mount_path),
      image_pipe: ImagePipe.Plug.init([instance: @instance] ++ config.http),
      auth_token_hash: Keyword.fetch!(config.server, :auth_token_hash)
    ]
  end

  # ThousandIsland caps connections per acceptor, so the cap is spread over
  # the acceptors and rounds up to a multiple of their count.
  @max_acceptors 100

  # Images are already compressed, and negotiating content encoding would add
  # `Vary: Accept-Encoding` to every response.
  @doc false
  @spec http_child(Config.t(), {module(), term()}) :: {module(), keyword()}
  def http_child(%Config{server: server}, plug) do
    max_connections = Keyword.fetch!(server, :max_connections)
    acceptors = min(@max_acceptors, max_connections)

    {Bandit,
     plug: plug,
     port: Keyword.fetch!(server, :port),
     ip: Keyword.fetch!(server, :ip),
     http_options: [compress: false],
     thousand_island_options: [
       num_acceptors: acceptors,
       num_connections: ceil(max_connections / acceptors),
       read_timeout: Keyword.fetch!(server, :read_timeout),
       shutdown_timeout: Keyword.fetch!(server, :shutdown_timeout),
       supervisor_options: [name: @listener]
     ]}
  end

  defp pool(nil), do: []
  defp pool(options), do: [{ImagePipe.ProcessingPool, options}]
end
