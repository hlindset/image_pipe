dir = Path.join(System.tmp_dir!(), "fbench")
File.mkdir_p!(dir)
p = Path.join(dir, "body")
File.write!(p, :crypto.strong_rand_bytes(32_000))

bench = fn name, f, n ->
  Enum.each(1..500, fn _ -> f.() end)
  {t, _} = :timer.tc(fn -> Enum.each(1..n, fn _ -> f.() end) end)
  IO.puts("#{String.pad_trailing(name, 40)} #{Float.round(t / n, 2)} us")
end

for _ <- 1..3 do
  bench.("open raw + close", fn ->
    {:ok, io} = :file.open(p, [:read, :binary, :raw])
    :file.close(io)
  end, 20_000)

  bench.("open raw + fstat + close", fn ->
    {:ok, io} = :file.open(p, [:read, :binary, :raw])
    {:ok, _} = :file.read_file_info(io, time: :posix)
    :file.close(io)
  end, 20_000)

  bench.("read_file_info path raw", fn -> {:ok, _} = :file.read_file_info(p, [:raw, time: :posix]) end, 20_000)
  bench.("read_link_info path raw", fn -> {:ok, _} = :file.read_link_info(p, [:raw, time: :posix]) end, 20_000)
  bench.("prim_file.read_link (EINVAL)", fn -> :prim_file.read_link(p) end, 20_000)
  bench.("read_file 32KB raw", fn -> {:ok, _} = :file.read_file(p, [:raw]) end, 20_000)
end
