defmodule ImagePipeServer.Application do
  @moduledoc false

  use Application

  @listener __MODULE__.Listener

  @impl Application
  def start(_type, _args) do
    env = Application.get_all_env(:image_pipe_server)

    router_opts = [
      mount_path: Keyword.fetch!(env, :mount_path),
      image_pipe: Keyword.fetch!(env, :image_pipe)
    ]

    children = [
      {Bandit,
       plug: {ImagePipeServer.Router, router_opts},
       port: Keyword.fetch!(env, :port),
       ip: parse_ip!(Keyword.fetch!(env, :bind)),
       thousand_island_options: [supervisor_options: [name: @listener]]}
    ]

    Supervisor.start_link(children, strategy: :one_for_one, name: ImagePipeServer.Supervisor)
  end

  @doc false
  def listener, do: @listener

  defp parse_ip!(bind) do
    case :inet.parse_address(String.to_charlist(bind)) do
      {:ok, ip} -> ip
      {:error, :einval} -> raise ArgumentError, "invalid bind address: #{inspect(bind)}"
    end
  end
end
