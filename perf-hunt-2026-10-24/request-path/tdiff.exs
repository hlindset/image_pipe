Code.require_file(Path.join(__DIR__, "harness.exs"))
Logger.configure(level: :error)
%{mount: mount} = H.setup()
path = "/w=300/format=webp/src/image.jpg"
%{status: 200} = r = H.call(mount, :get, path)
etag = r |> Plug.Conn.get_resp_header("etag") |> hd()
:persistent_term.put(:proto_noopen, true)

modes = %{
  "head" => fn -> %{status: 200} = H.call(mount, :head, path) end,
  "304" => fn -> %{status: 304} = H.call(mount, :get, path, [{"if-none-match", etag}]) end
}

n = 500

prof = fn f ->
  Enum.each(1..200, fn _ -> f.() end)
  {:ok, {:call_time, rows}} =
    :tprof.profile(fn -> Enum.each(1..n, fn _ -> f.() end) end, %{type: :call_time, report: :return, set_on_spawn: true})

  Map.new(rows, fn {m, fun, a, per_proc} ->
    {"#{inspect(m)}.#{fun}/#{a}",
     {Enum.sum(Enum.map(per_proc, &elem(&1, 1))), Enum.sum(Enum.map(per_proc, &elem(&1, 2)))}}
  end)
end

a = prof.(modes["304"])
b = prof.(modes["head"])
keys = Enum.uniq(Map.keys(a) ++ Map.keys(b))

keys
|> Enum.map(fn k ->
  {ca, ta} = Map.get(a, k, {0, 0})
  {cb, tb} = Map.get(b, k, {0, 0})
  {k, (tb - ta) / n, (cb - ca) / n}
end)
|> Enum.sort_by(&(-elem(&1, 1)))
|> Enum.take(45)
|> Enum.each(fn {k, dt, dc} -> IO.puts("#{String.pad_trailing(k, 80)} #{Float.round(dt, 2)} us  #{dc} calls") end)

ta = a |> Map.values() |> Enum.map(&elem(&1, 1)) |> Enum.sum()
tb = b |> Map.values() |> Enum.map(&elem(&1, 1)) |> Enum.sum()
IO.puts("total traced per req: 304 #{ta / n}  head #{tb / n}")
