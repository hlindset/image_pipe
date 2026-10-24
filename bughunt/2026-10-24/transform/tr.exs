Code.require_file("h.exs", __DIR__)
bytes = File.read!(Path.join(__DIR__, "src/cmyka.tif"))
logp = Path.join(__DIR__, "trace.log")
tracer = spawn(fn ->
  {:ok, fd} = :file.open(logp, [:write, :raw])
  loop = fn loop ->
    receive do
      {:trace, _pid, :call, {m, f, args}} ->
        a = Enum.map(args, fn x -> if is_binary(x) and byte_size(x) < 60, do: inspect(x), else: (if is_binary(x), do: "<bin #{byte_size(x)}>", else: inspect(x, limit: 3) |> String.slice(0, 60)) end)
        :file.write(fd, "#{inspect(m)}.#{f} #{Enum.join(a, ", ")}\n")
        :file.datasync(fd)
      _ -> :ok
    end
    loop.(loop)
  end
  loop.(loop)
end)
:erlang.trace_pattern({Vix.Nif, :_, :_}, true, [:local])
:erlang.trace_pattern({Vix.Vips.Image, :header_value, 2}, true, [:local])
:erlang.trace_pattern({ImagePipe.Output.Encoder, :_, :_}, true, [:local])
for i <- 1..30 do
  t = Task.async(fn ->
    :erlang.trace(self(), true, [:call, {:tracer, tracer}, :set_on_spawn])
    H.request("/progressive-blur=5,down,0,1/format=png/src/x", H.opts(bytes, "image/tiff")).status
  end)
  IO.puts("#{i} #{Task.await(t, :infinity)}")
  Process.sleep(200)
end
