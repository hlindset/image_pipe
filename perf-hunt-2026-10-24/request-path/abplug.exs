Code.require_file(Path.join(__DIR__, "harness.exs"))
Logger.configure(level: :error)
%{mount: mount} = H.setup()
path = System.get_env("REQPATH", "/w=300/format=webp/src/image.jpg")
%{status: 200} = r = H.call(mount, :get, path)
etag = r |> Plug.Conn.get_resp_header("etag") |> hd()
flag = String.to_atom(System.get_env("FLAG", "proto_flag"))

modes =
  System.get_env("MODES", "head,304")
  |> String.split(",")
  |> Enum.map(fn
    "get" -> {"get", fn -> %{status: 200} = H.call(mount, :get, path) end}
    "head" -> {"head", fn -> %{status: 200} = H.call(mount, :head, path) end}
    "304" -> {"304", fn -> %{status: 304} = H.call(mount, :get, path, [{"if-none-match", etag}]) end}
  end)

n = String.to_integer(System.get_env("N", "1000"))
rounds = String.to_integer(System.get_env("ROUNDS", "6"))

results =
  for _round <- 1..rounds, {name, f} <- modes, variant <- Enum.shuffle([false, true]) do
    :persistent_term.put(flag, variant)
    Enum.each(1..100, fn _ -> f.() end)
    {:reductions, r0} = Process.info(self(), :reductions)
    {t, _} = :timer.tc(fn -> Enum.each(1..n, fn _ -> f.() end) end)
    {:reductions, r1} = Process.info(self(), :reductions)
    {{name, variant}, {t / n, div(r1 - r0, n)}}
  end

for {{name, variant}, ts} <- Enum.group_by(results, &elem(&1, 0), &elem(&1, 1)) |> Enum.sort() do
  sorted = ts |> Enum.map(&elem(&1, 0)) |> Enum.sort()
  med = Enum.at(sorted, div(length(sorted), 2))
  red = ts |> Enum.map(&elem(&1, 1)) |> Enum.sort() |> Enum.at(div(length(ts), 2))
  IO.puts("#{name} #{flag}=#{variant}: median #{Float.round(med, 1)} us  min #{Float.round(hd(sorted), 1)}  red #{red}")
end
