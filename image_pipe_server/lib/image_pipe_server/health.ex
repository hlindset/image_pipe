defmodule ImagePipeServer.Health do
  @moduledoc """
  Checks that the running server answers `GET /health`. The Docker image's
  `HEALTHCHECK` runs it in a separate VM:

      bin/image_pipe_server eval "ImagePipeServer.Health.check()"

  The check loads the same configuration as the server, so it finds the
  listener wherever `port` and `bind` are set. A wildcard `bind` is checked
  on loopback.
  """

  alias ImagePipeServer.Config
  alias ImagePipeServer.ConfigError

  @timeout 2_000

  @doc "Halts with status 0 when the server answers `/health` with 200, or 1 otherwise."
  @spec check() :: no_return()
  def check do
    config =
      Config.load!(
        System.get_env(),
        Application.fetch_env!(:image_pipe_server, :default_config_path)
      )

    case status(config.server) do
      :ok ->
        System.halt(0)

      {:error, reason} ->
        IO.puts(:stderr, "health check failed: #{inspect(reason)}")
        System.halt(1)
    end
  rescue
    error in ConfigError ->
      IO.puts(:stderr, Exception.message(error))
      System.halt(1)
  end

  @doc "Requests `/health` from the listener that `server` options describe."
  @spec status(keyword()) :: :ok | {:error, term()}
  def status(server) do
    address = address(Keyword.fetch!(server, :ip))
    port = Keyword.fetch!(server, :port)

    with {:ok, socket} <- :gen_tcp.connect(address, port, [:binary, active: false], @timeout) do
      try do
        request = "GET /health HTTP/1.1\r\nhost: localhost\r\nconnection: close\r\n\r\n"

        with :ok <- :gen_tcp.send(socket, request),
             {:ok, response} <- :gen_tcp.recv(socket, 0, @timeout) do
          case response do
            "HTTP/1.1 200 " <> _rest -> :ok
            _other -> {:error, :unhealthy}
          end
        end
      after
        :gen_tcp.close(socket)
      end
    end
  end

  defp address({0, 0, 0, 0}), do: {127, 0, 0, 1}
  defp address({0, 0, 0, 0, 0, 0, 0, 0}), do: {0, 0, 0, 0, 0, 0, 0, 1}
  defp address(ip), do: ip
end
