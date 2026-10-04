defmodule ImagePipeServer.HealthTest do
  use ExUnit.Case, async: true

  alias ImagePipeServer.Application, as: App
  alias ImagePipeServer.Config
  alias ImagePipeServer.Health

  defp start_listener(bind) do
    config = Config.build!(server: [port: 0, bind: bind])
    {Bandit, opts} = App.http_child(config, {ImagePipeServer.Router, App.router_options(config)})
    name = :"listener_#{System.unique_integer([:positive])}"
    opts = put_in(opts, [:thousand_island_options, :supervisor_options], name: name)
    start_supervised!(Supervisor.child_spec({Bandit, opts}, id: name))
    {:ok, {_ip, port}} = ThousandIsland.listener_info(name)
    Keyword.put(config.server, :port, port)
  end

  test "passes when the configured listener answers /health" do
    assert Health.status(start_listener("127.0.0.1")) == :ok
  end

  test "checks a wildcard bind on loopback" do
    assert Health.status(start_listener("0.0.0.0")) == :ok
  end

  test "fails when nothing listens on the configured port" do
    server = Config.build!(server: [bind: "127.0.0.1"]).server
    {:ok, socket} = :gen_tcp.listen(0, ip: {127, 0, 0, 1})
    {:ok, closed_port} = :inet.port(socket)
    :ok = :gen_tcp.close(socket)

    assert {:error, :econnrefused} = Health.status(Keyword.put(server, :port, closed_port))
  end
end
