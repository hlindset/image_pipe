root = Path.expand(Path.join(__DIR__, "root"))

for {name, f} <- [
      port: fn -> ImagePipe.SafePath.relative("a/x", root) end,
      otp: fn -> Path.safe_relative("a/x", root) end
    ] do
  t = Task.async(f)

  case Task.yield(t, 3000) do
    nil ->
      {:memory, mem} = Process.info(t.pid, :memory)
      IO.puts("#{name}: HANG after 3s, task memory=#{mem}")
      Task.shutdown(t, :brutal_kill)

    res ->
      IO.inspect(res, label: "#{name} result")
  end
end
