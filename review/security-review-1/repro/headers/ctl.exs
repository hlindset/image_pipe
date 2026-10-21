require Logger
ImagePipe.Telemetry.attach_default_logger()

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


{:ok, _} = Bandit.start_link(plug: {ImagePipe.Plug, [sources: [local: [adapter: ImagePipe.Source.File, match: :path, options: [root: System.tmp_dir!(), root_id: "t"]]]]}, port: 4791, ip: {127,0,0,1})
Process.sleep(200)

for line <- [
  "GET /w=1/x\e[31mRED\e[0m/src/a.jpg HTTP/1.1",
  "GET /w=1\tlevel=error/src/a.jpg HTTP/1.1",
  "GET /w=1/\x01\x7f/src/a.jpg HTTP/1.1",
  "GET /w=1/x\xff\xfe/src/a.jpg HTTP/1.1",
  "GET /w=foo\e[2J HTTP/1.1"
] do
  r = Raw.req(4791, line)
  IO.puts("=== #{inspect(line)}\n#{inspect(r)}")
end
Process.sleep(300)
