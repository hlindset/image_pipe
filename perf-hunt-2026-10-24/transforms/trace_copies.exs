import Plug.Test
[dir, path] = System.argv()
Logger.configure(level: :error)
Vix.Vips.cache_set_max(0)

config =
  ImagePipe.Plug.init(
    allow_unsigned: true,
    max_body_bytes: 200_000_000,
    sources: [path: [adapter: ImagePipe.Source.File, match: :path, options: [root: dir, root_id: "perf"]]],
    watermarks: %{mark: [source: "alpha.png"]}
  )

req = fn -> ImagePipe.Plug.call(conn(:get, path), config) end
200 = req.().status

me = self()

tracer =
  spawn(fn ->
    loop = fn loop, acc ->
      receive do
        {:trace, _pid, :call, {Vix.Nif, f, args}, st} ->
          loop.(loop, [{f, args, st} | acc])

        {:trace, _pid, :return_from, {Vix.Nif, f, _}, ret} ->
          loop.(loop, [{:ret, f, ret} | acc])

        {:done, from} ->
          send(from, {:calls, Enum.reverse(acc)})
      end
    end

    loop.(loop, [])
  end)

:erlang.trace(:all, true, [:call, {:tracer, tracer}])
:erlang.trace_pattern({Vix.Nif, :nif_image_copy_memory, 1}, [{:_, [], [{:message, {:current_stacktrace}}, {:return_trace}]}], [:local])
:erlang.trace_pattern({Vix.Nif, :nif_vips_operation_call, 2}, [{:_, [], [{:message, {:current_stacktrace}}]}], [:local])
c = req.()
:erlang.trace(:all, false, [:call])
ref = :erlang.trace_delivered(:all)
receive do: ({:trace_delivered, :all, ^ref} -> :ok)
send(tracer, {:done, me})
calls = receive do: ({:calls, calls} -> calls)
IO.puts("status #{c.status}")

for call <- calls do
  case call do
    {:nif_image_copy_memory, [img], st} ->
      im = %Vix.Vips.Image{ref: img}
      {w, h} = {Vix.Vips.Image.width(im), Vix.Vips.Image.height(im)}
      frames =
        st
        |> Enum.reject(fn {m, _, _, _} -> m in [Vix.Nif, Vix.Vips.Image, Vix.Vips.MutableImage, GenServer, :gen, :gen_server, :proc_lib, :erlang] end)
        |> Enum.take(3)
        |> Enum.map(fn {m, f, a, loc} -> "#{inspect(m)}.#{f}/#{if is_list(a), do: length(a), else: a}:#{loc[:line]}" end)

      IO.puts("copy_memory #{w}x#{h} <- #{Enum.join(frames, " <- ")}")

    {:nif_vips_operation_call, [name | _], st} ->
      frames =
        st
        |> Enum.reject(fn {m, _, _, _} -> m in [Vix.Nif, Vix.Vips.Operation, Vix.Vips.Operation.Helper, Vix.Vips.Image, :erlang] end)
        |> Enum.take(2)
        |> Enum.map(fn {m, f, a, loc} -> "#{inspect(m)}.#{f}/#{if is_list(a), do: length(a), else: a}:#{loc[:line]}" end)

      IO.puts("op #{name} <- #{Enum.join(frames, " <- ")}")

    {:ret, :nif_image_copy_memory, _} -> :ok
    other ->
      IO.puts("other #{inspect(other, limit: 5)}")
  end
end
