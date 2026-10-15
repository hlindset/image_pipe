defmodule ImagePipeServer.Application do
  @moduledoc false

  use Application

  alias ImagePipeServer.Config
  alias ImagePipeServer.ConfigError
  alias ImagePipeServer.Health
  alias ImagePipeServer.Warmup

  @listener __MODULE__.Listener
  @health_listener __MODULE__.HealthListener
  @instance ImagePipeServer.ImagePipe

  @impl Application
  def start(_type, _args) do
    config = config!()

    Logger.configure(level: config.log_level)
    configure_log_format(config.log_format)

    # Each request decodes a new original, so libvips' operation cache rarely
    # hits and mostly keeps decoded images in memory.
    Vix.Vips.cache_set_max(0)
    if config.telemetry, do: ImagePipe.Telemetry.attach_default_logger(config.telemetry)

    if Application.fetch_env!(:image_pipe_server, :tracing) do
      ImagePipe.Telemetry.attach_tracer(tracer_options(config))
    end

    drain = Health.new()

    with {:ok, pid} <-
           Supervisor.start_link(children(config, drain),
             strategy: :one_for_one,
             name: ImagePipeServer.Supervisor
           ),
         do: {:ok, pid, {drain, Keyword.fetch!(config.server, :shutdown_delay)}}
  end

  # JSON formats replace the default handler's formatter. The request ID and
  # the request summary, which the default Logger puts under `:image_pipe`,
  # become JSON keys. Other metadata, such as Bandit's startup options, is
  # left out.
  @log_formatters %{
    json: LoggerJSON.Formatters.Basic,
    gcp: LoggerJSON.Formatters.GoogleCloud,
    datadog: LoggerJSON.Formatters.Datadog,
    elastic: LoggerJSON.Formatters.Elastic
  }

  defp configure_log_format(format) do
    case log_formatter(format) do
      nil -> :ok
      formatter -> :ok = :logger.update_handler_config(:default, :formatter, formatter)
    end
  end

  @doc false
  # The default handler's formatter for `format`, or nil to keep the text one.
  @spec log_formatter(Config.t() | atom()) :: {module(), term()} | nil
  def log_formatter(:text), do: nil

  def log_formatter(format) do
    Map.fetch!(@log_formatters, format).new(metadata: [:request_id, :image_pipe])
  end

  # Runs on shutdown before any child stops: readiness fails and responses
  # close their connections, while the listener keeps serving for the delay
  # so load balancers can move traffic away. Then the listener drains.
  @impl Application
  def prep_stop({drain, delay} = state) do
    Health.drain(drain)
    Process.sleep(delay)
    state
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
    [extract_inbound: config.trust_traceparent]
  end

  # Children stop in reverse order, so the listener, started last, drains
  # in-flight requests before the pool and the ImagePipe instance stop. The
  # health listener, started first, answers until the end. The warmup runs
  # before the listener starts, and readiness turns on after it.
  @doc false
  @spec children(Config.t(), Health.drain()) :: [Supervisor.child_spec() | {module(), term()}]
  def children(%Config{} = config, drain) do
    List.wrap(health_child(config, drain)) ++
      [
        {ImagePipe.ProcessingPool, config.pool},
        {ImagePipe,
         name: @instance, config: config.image_pipe, detector_warmup: config.detector_warmup}
      ] ++
      Enum.map(config.credential_warmups, &{ImagePipe.Source.S3.CredentialWarmup, &1}) ++
      [
        {Warmup, @instance},
        http_child(config, {ImagePipeServer.Router, router_options(config, drain)}),
        %{id: :serving, start: {__MODULE__, :serve, [drain]}, restart: :temporary}
      ]
  end

  @doc false
  def serve(drain) do
    Health.serve(drain)
    :ignore
  end

  @doc false
  @spec router_options(Config.t(), Health.drain()) :: keyword()
  def router_options(%Config{} = config, drain) do
    [
      drain: drain,
      mount_path: Keyword.fetch!(config.server, :mount_path),
      image_pipe: ImagePipe.Plug.init([instance: @instance] ++ config.http),
      auth_token_hash: Keyword.fetch!(config.server, :auth_token_hash),
      trust_request_id: config.trust_request_id
    ]
  end

  # A small listener for the health checks alone, outside the image
  # listener's connection cap.
  @doc false
  @spec health_child(Config.t(), Health.drain()) :: {module(), keyword()} | nil
  def health_child(%Config{server: server}, drain) do
    if port = Keyword.get(server, :health_port) do
      {Bandit,
       plug: {Health, drain: drain},
       port: port,
       ip: Keyword.fetch!(server, :ip),
       http_2_options: [enabled: false],
       thousand_island_options: [
         num_acceptors: 1,
         num_connections: 16,
         read_timeout: 5_000,
         supervisor_options: [name: @health_listener]
       ]}
    end
  end

  # Images are already compressed, and negotiating content encoding would add
  # `Vary: Accept-Encoding` to every response. HTTP/2 cleartext is off: Bandit
  # closes an HTTP/2 connection that is quiet for read_timeout, even while a
  # slow image is still being made, losing every stream on it.
  @doc false
  @spec http_child(Config.t(), {module(), term()}) :: {module(), keyword()}
  def http_child(%Config{server: server}, plug) do
    {Bandit,
     plug: plug,
     port: Keyword.fetch!(server, :port),
     ip: Keyword.fetch!(server, :ip),
     http_options: [compress: false],
     http_2_options: [enabled: false],
     thousand_island_options: [
       # ThousandIsland caps connections per acceptor, and an acceptor at its
       # cap closes new connections even when others have room. One acceptor
       # makes max_connections exact.
       num_acceptors: 1,
       num_connections: Keyword.fetch!(server, :max_connections),
       read_timeout: Keyword.fetch!(server, :read_timeout),
       shutdown_timeout: Keyword.fetch!(server, :shutdown_timeout),
       supervisor_options: [name: @listener]
     ]}
  end
end
