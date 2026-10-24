Code.require_file(Path.join(__DIR__, "harness.exs"))
Code.require_file(Path.join(__DIR__, "hbandit.exs"))
Logger.configure(level: :error)
%{mount: mount} = H.setup()
path = "/w=300/format=webp/src/image.jpg"
%{status: 200} = r = H.call(mount, :get, path)
etag = r |> Plug.Conn.get_resp_header("etag") |> hd()
port = H.Bandit.start(mount)

modes = [
  {"get", H.Bandit.client(port, "GET", path)},
  {"head", H.Bandit.client(port, "HEAD", path)},
  {"304", H.Bandit.client(port, "GET", path, [{"if-none-match", etag}])}
]

mods = [:prim_file, :file, :gen_tcp, :socket, :prim_socket, :ets, :persistent_term, :crypto, :re, :erlang]

for {name, f} <- modes do
  Enum.each(1..100, fn _ -> f.() end)
  for m <- mods, do: :erlang.trace_pattern({m, :_, :_}, true, [:call_count])
  :erlang.trace(:all, true, [:call])
  n = 200
  Enum.each(1..n, fn _ -> f.() end)
  :erlang.trace(:all, false, [:call])

  counts =
    for m <- mods, {fun, arity} <- m.module_info(:exports),
        {:call_count, c} = :erlang.trace_info({m, fun, arity}, :call_count),
        is_integer(c) and c > 0 do
      {"#{m}:#{fun}/#{arity}", c / n}
    end

  for m <- mods, do: :erlang.trace_pattern({m, :_, :_}, false, [:call_count])
  IO.puts("== #{name}")

  counts
  |> Enum.filter(fn {k, _} -> String.match?(k, ~r/nif|prim_file|crypto:hash|re:run|term_to_binary|binary_to_term|sendfile|ets:(lookup|insert|update|match|select)|persistent_term|erlang:(send|alias|monitor|spawn|binary_to_atom|phash2)/) end)
  |> Enum.sort_by(&(-elem(&1, 1)))
  |> Enum.each(fn {k, c} -> IO.puts("  #{String.pad_trailing(k, 45)} #{c}") end)
end
