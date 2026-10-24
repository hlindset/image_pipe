Code.require_file(Path.join(__DIR__, "harness.exs"))
Logger.configure(level: :error)
%{mount: mount} = H.setup()
path = "/w=300/format=webp/src/image.jpg"
%{status: 200} = r = H.call(mount, :get, path)
etag = r |> Plug.Conn.get_resp_header("etag") |> hd()
IO.inspect(r.resp_headers, label: "headers")

modes = %{
  "get" => fn -> %{status: 200} = H.call(mount, :get, path) end,
  "head" => fn -> %{status: 200} = H.call(mount, :head, path) end,
  "304" => fn -> %{status: 304} = H.call(mount, :get, path, [{"if-none-match", etag}]) end,
  "400" => fn -> %{status: s} = H.call(mount, :get, "/w=abc/src/image.jpg"); s end
}

for round <- 1..3, {name, f} <- modes do
  IO.puts("#{round} #{name} #{inspect(H.cost(f, 1000))}")
end

mode = System.get_env("PROF")

if mode do
  f = modes[mode]
  Enum.each(1..100, fn _ -> f.() end)
  type = String.to_atom(System.get_env("PTYPE", "call_time"))
  :tprof.profile(fn -> Enum.each(1..500, fn _ -> f.() end) end, %{type: type, report: {:total, :measurement}, set_on_spawn: true})
end
