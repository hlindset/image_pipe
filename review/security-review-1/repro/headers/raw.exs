defmodule Raw do
  def req(port, line, headers \\ "") do
    {:ok, s} = :gen_tcp.connect(~c"127.0.0.1", port, [:binary, active: false])
    :ok = :gen_tcp.send(s, line <> "\r\nHost: x\r\n" <> headers <> "Connection: close\r\n\r\n")
    resp = recv(s, "")
    :gen_tcp.close(s)
    resp
  end
  defp recv(s, acc) do
    case :gen_tcp.recv(s, 0, 3000) do
      {:ok, d} -> recv(s, acc <> d)
      _ -> acc
    end
  end
end
