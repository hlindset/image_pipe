Code.require_file(Path.join(__DIR__, "harness.exs"))
Code.require_file(Path.join(__DIR__, "hbandit.exs"))
Logger.configure(level: :error)
extra = if System.get_env("LOGGER"), do: [], else: []
%{mount: mount} = H.setup(extra: extra)

if System.get_env("LOGGER") do
  ImagePipe.Telemetry.attach_default_logger(level: :debug)
end

path = System.get_env("REQPATH", "/w=300/format=webp/src/image.jpg")
%{status: 200} = r = H.call(mount, :get, path)
etag = r |> Plug.Conn.get_resp_header("etag") |> hd()
port = H.Bandit.start(mount)

modes = [
  {"get", H.Bandit.client(port, "GET", path)},
  {"head", H.Bandit.client(port, "HEAD", path)},
  {"304", H.Bandit.client(port, "GET", path, [{"if-none-match", etag}])},
  {"400", H.Bandit.client(port, "GET", "/w=abc/src/image.jpg")}
]

for round <- 1..3, {name, f} <- modes do
  Enum.each(1..200, fn _ -> f.() end)
  n = 2000
  {t, _} = :timer.tc(fn -> Enum.each(1..n, fn _ -> f.() end) end)
  IO.puts("#{round} #{name} #{Float.round(t / n, 1)} us/req  status=#{f.()}")
end
