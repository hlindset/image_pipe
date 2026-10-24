alias ImagePipe.API.{Parser, Path, OptionSpec}
keys = Enum.map(OptionSpec.all(), & &1.key)
bytes = [<<0xFF>>, <<0xC3>>, <<0xC3, 0xA9>>, <<0xE2, 0x82>>, <<0>>, <<0x80>>, "é", "́", "pct", "1", "0", ",", ":", ".", "-", "a", "unset", "=", " ", "\t", "\r\n", "́"]
:rand.seed(:exsss, {7, 8, 9})
gen_val = fn -> n = :rand.uniform(6); Enum.map_join(1..n, fn _ -> if :rand.uniform(2) == 1, do: Enum.random(bytes), else: Enum.random(~w(1 2 0 , : . pct auto red fff 10 0.5 a b)) end) end
crashes = Enum.reduce(1..200_000, 0, fn _, acc ->
  segs = Enum.map(1..:rand.uniform(4), fn _ -> if :rand.uniform(8)==1, do: gen_val.(), else: Enum.random(keys) <> "=" <> gen_val.() end)
  path = "/" <> Enum.join(segs, "/") <> "/src/" <> gen_val.()
  try do
    _ = Path.diagnostic_path(path)
    case Path.extract(path, "") do
      {:ok, lexed} -> Parser.parse(lexed, []); Parser.preset_names(lexed)
      _ -> :ok
    end
    acc
  rescue e ->
    if acc < 10, do: IO.puts("CRASH #{inspect path}: #{Exception.format(:error, e, __STACKTRACE__) |> String.slice(0, 700)}")
    acc + 1
  end
end)
IO.puts("crashes: #{crashes}")
