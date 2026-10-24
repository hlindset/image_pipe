root = Path.expand(Path.join(__DIR__, "root"))
t = Task.async(fn -> ImagePipe.SafePath.relative("a/x", root) end)
case Task.yield(t, 3000) do
  nil -> {:memory, mem} = Process.info(t.pid, :memory); IO.puts("HANG after 3s, task memory=#{mem}"); Task.shutdown(t, :brutal_kill)
  res -> IO.inspect(res, label: "result")
end
IO.inspect(Path.safe_relative("a/x", root) |> then(fn _ -> :skipped end))
