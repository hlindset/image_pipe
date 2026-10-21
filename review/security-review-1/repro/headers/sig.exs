ImagePipe.Telemetry.attach_default_logger()
Code.require_file("raw.exs", __DIR__)
key = String.duplicate("ab", 32)
{:ok, _} = Bandit.start_link(plug: {ImagePipe.Plug, [keys: [key], sources: [local: [adapter: ImagePipe.Source.File, match: :path, options: [root: System.tmp_dir!(), root_id: "t"]]]]}, port: 4792, ip: {127,0,0,1})
Process.sleep(200)
for line <- [
  "GET /sig=AAAA/w=1/src/a.jpg HTTP/1.1",
  "GET /sig=AAAA/w=1/src/a\xff.jpg HTTP/1.1",
  "GET /sig=AAAA\xff/w=1/src/a.jpg HTTP/1.1",
] do
  r = Raw.req(4792, line)
  IO.puts("=== #{inspect(line, binaries: :as_binaries) |> String.slice(0, 80)} -> #{r |> String.split("\r\n") |> hd}")
  Process.sleep(100)
end
Process.sleep(300)
