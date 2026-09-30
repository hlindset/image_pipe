defmodule ImagePipeServer.Application do
  @moduledoc false

  use Application

  alias ImagePipe.Cache.FileSystem
  alias ImagePipeServer.Config

  @listener __MODULE__.Listener

  @impl Application
  def start(_type, _args) do
    config =
      Config.load!(
        System.get_env(),
        Application.fetch_env!(:image_pipe_server, :default_config_path)
      )

    if config.telemetry, do: ImagePipe.Telemetry.attach_default_logger(config.telemetry)

    Supervisor.start_link(children(config),
      strategy: :one_for_one,
      name: ImagePipeServer.Supervisor
    )
  end

  @doc false
  def listener, do: @listener

  # Children stop in reverse order, so the listener, started last, drains
  # in-flight requests before the pool and caches stop.
  @doc false
  @spec children(Config.t()) :: [Supervisor.child_spec() | {module(), term()}]
  def children(%Config{} = config) do
    router_opts = [
      mount_path: Keyword.fetch!(config.server, :mount_path),
      image_pipe: config.image_pipe
    ]

    pool(config.pool) ++
      caches(config.image_pipe) ++
      detector_warmup(config.detector_warmup) ++
      Enum.map(config.credential_warmups, &{ImagePipe.Source.S3.CredentialWarmup, &1}) ++
      [http_child(config, {ImagePipeServer.Router, router_opts})]
  end

  @doc false
  @spec http_child(Config.t(), {module(), term()}) :: {module(), keyword()}
  def http_child(%Config{server: server}, plug) do
    {Bandit,
     plug: plug,
     port: Keyword.fetch!(server, :port),
     ip: Keyword.fetch!(server, :ip),
     thousand_island_options: [
       shutdown_timeout: Keyword.fetch!(server, :shutdown_timeout),
       supervisor_options: [name: @listener]
     ]}
  end

  defp pool(nil), do: []
  defp pool(options), do: [{ImagePipe.ProcessingPool, options}]

  # A bounded file-system cache needs its own processes; an unbounded one
  # returns :ignore.
  defp caches(image_pipe) do
    for key <- [:cache, :input_cache],
        {FileSystem, options} <- [Keyword.get(image_pipe, key)],
        spec = FileSystem.child_spec(options),
        spec != :ignore,
        do: spec
  end

  defp detector_warmup(nil), do: []
  defp detector_warmup(options), do: [{ImagePipe.Transform.Detector.Warmup, options}]
end
