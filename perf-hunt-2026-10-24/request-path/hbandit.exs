defmodule H.Mounted do
  def init(mount), do: mount
  def call(conn, mount), do: ImagePipe.Plug.call(conn, mount)
end

defmodule H.Bandit do
  def start(mount) do
    {:ok, bandit} =
      Bandit.start_link(plug: {H.Mounted, mount}, port: 0, ip: :loopback, startup_log: false)

    {:ok, {_ip, port}} = ThousandIsland.listener_info(bandit)
    port
  end

  def client(port, method, path, headers \\ []) do
    {:ok, socket} = :gen_tcp.connect(~c"127.0.0.1", port, [:binary, active: false])
    hdrs = Enum.map_join(headers, "", fn {k, v} -> "#{k}: #{v}\r\n" end)
    request = "#{method} #{path} HTTP/1.1\r\nhost: localhost\r\n#{hdrs}\r\n"
    head? = method == "HEAD"

    fn ->
      :ok = :gen_tcp.send(socket, request)
      read_response(socket, "", head?)
    end
  end

  defp read_response(socket, acc, head?) do
    case :binary.split(acc, "\r\n\r\n") do
      [head, body] ->
        "HTTP/1.1 " <> <<status::binary-size(3), _::binary>> = head

        case {status, head?} do
          {"304", _} ->
            304

          {_, true} ->
            String.to_integer(status)

          _ ->
            [_, length] = Regex.run(~r/content-length: (\d+)/, head)
            read_body(socket, body, String.to_integer(length))
            String.to_integer(status)
        end

      [_partial] ->
        {:ok, data} = :gen_tcp.recv(socket, 0, 5_000)
        read_response(socket, acc <> data, head?)
    end
  end

  defp read_body(_socket, body, length) when byte_size(body) >= length, do: :ok

  defp read_body(socket, body, length) do
    {:ok, data} = :gen_tcp.recv(socket, 0, 5_000)
    read_body(socket, body <> data, length)
  end
end
