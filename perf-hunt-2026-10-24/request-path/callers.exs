Code.require_file(Path.join(__DIR__, "harness.exs"))
Logger.configure(level: :error)
%{mount: mount} = H.setup()
path = "/w=300/format=webp/src/image.jpg"
%{status: 200} = r = H.call(mount, :get, path)
etag = r |> Plug.Conn.get_resp_header("etag") |> hd()
Enum.each(1..10, fn _ -> H.call(mount, :head, path) end)

me = self()

tracer =
  spawn(fn ->
    loop = fn loop, acc ->
      receive do
        {:trace, _pid, :call, {m, f, a}, caller} ->
          loop.(loop, Map.update(acc, {m, f, length(a), caller}, 1, &(&1 + 1)))

        {:done, from} ->
          send(from, {:acc, acc})
      end
    end

    loop.(loop, %{})
  end)

targets = [
  {:re, :run, 3},
  {:re, :import, 1},
  {:ets, :match_object, 2},
  {ImagePipe.SVG.Native, :versions, 0},
  {:erlang, :term_to_binary, 2},
  {:crypto, :hash, 2},
  {:erlang, :binary_to_atom, 2},
  {:erlang, :binary_to_atom, 1},
  {:prim_file, :read_link, 1},
  {:prim_file, :read_file_info, 2},
  {String, :downcase, 1},
  {:telemetry, :list_handlers, 1}
]

for t <- targets, do: :erlang.trace_pattern(t, [{:_, [], [{:message, {:caller}}]}], [:global])
:erlang.trace(self(), true, [:call, {:tracer, tracer}])
H.call(mount, :head, path)
H.call(mount, :get, path, [{"if-none-match", etag}])
:erlang.trace(self(), false, [:call])
send(tracer, {:done, me})

receive do
  {:acc, acc} ->
    acc |> Enum.sort() |> Enum.each(fn {k, c} -> IO.puts("#{inspect(k)} x#{c}") end)
end
