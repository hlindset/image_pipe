defmodule ImagePipeServer.Application do
  @moduledoc false

  use Application

  @listener __MODULE__.Listener

  @impl Application
  def start(_type, _args) do
    config =
      ImagePipeServer.Config.load!(
        System.get_env(),
        Application.fetch_env!(:image_pipe_server, :default_config_path)
      )

    router_opts = [
      mount_path: Keyword.fetch!(config.server, :mount_path),
      image_pipe: config.image_pipe
    ]

    children = [
      {Bandit,
       plug: {ImagePipeServer.Router, router_opts},
       port: Keyword.fetch!(config.server, :port),
       ip: Keyword.fetch!(config.server, :ip),
       thousand_island_options: [supervisor_options: [name: @listener]]}
    ]

    Supervisor.start_link(children, strategy: :one_for_one, name: ImagePipeServer.Supervisor)
  end

  @doc false
  def listener, do: @listener
end
