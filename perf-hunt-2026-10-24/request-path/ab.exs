Code.require_file(Path.join(__DIR__, "harness.exs"))
Code.require_file(Path.join(__DIR__, "hbandit.exs"))
Logger.configure(level: :error)
%{mount: mount} = H.setup()
path = "/w=300/format=webp/src/image.jpg"
%{status: 200} = r = H.call(mount, :get, path)
etag = r |> Plug.Conn.get_resp_header("etag") |> hd()
port = H.Bandit.start(mount)
flag = String.to_atom(System.get_env("FLAG", "proto_flag"))

modes =
  System.get_env("MODES", "get,head")
  |> String.split(",")
  |> Enum.map(fn
    "get" -> {"get", H.Bandit.client(port, "GET", path)}
    "head" -> {"head", H.Bandit.client(port, "HEAD", path)}
    "304" -> {"304", H.Bandit.client(port, "GET", path, [{"if-none-match", etag}])}
  end)

n = String.to_integer(System.get_env("N", "1000"))
rounds = String.to_integer(System.get_env("ROUNDS", "8"))

results =
  for round <- 1..rounds, {name, f} <- modes, variant <- Enum.shuffle([false, true]) do
    :persistent_term.put(flag, variant)
    Enum.each(1..100, fn _ -> f.() end)
    {t, _} = :timer.tc(fn -> Enum.each(1..n, fn _ -> f.() end) end)
    _ = round
    {{name, variant}, t / n}
  end

for {{name, variant}, ts} <- Enum.group_by(results, &elem(&1, 0), &elem(&1, 1)) |> Enum.sort() do
  sorted = Enum.sort(ts)
  med = Enum.at(sorted, div(length(sorted), 2))
  IO.puts("#{name} #{flag}=#{variant}: median #{Float.round(med, 1)} us  min #{Float.round(hd(sorted), 1)}  all #{inspect(Enum.map(ts, &Float.round(&1, 0)))}")
end
