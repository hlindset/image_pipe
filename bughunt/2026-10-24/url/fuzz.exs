alias ImagePipe.API.{Parser, Path, OptionSpec}
keys = Enum.map(OptionSpec.all(), & &1.key)
chars = String.graphemes(",:.-0123456789abcdefxyzunsetpcqhvlrgwtuo=!_") ++ ["unset,", "pct", "auto", "info", "jpeg", "webp", "all", "red", "1e5", "-", "keep-alpha", "left", "true", "false", "smart"]
:rand.seed(:exsss, {1, 2, 3})
gen_val = fn -> n = :rand.uniform(8); Enum.map_join(1..n, fn _ -> Enum.random(chars) end) end
gen_seg = fn ->
  case :rand.uniform(10) do
    1 -> "-"
    2 -> Enum.random(keys)
    _ -> Enum.random(keys) <> "=" <> gen_val.()
  end
end
presets = %{}
crashes = Enum.reduce(1..300_000, 0, fn _, acc ->
  segs = Enum.map(1..:rand.uniform(6), fn _ -> gen_seg.() end)
  path = "/" <> Enum.join(segs, "/") <> "/src/a"
  try do
    case Path.extract(path, "") do
      {:ok, lexed} ->
        Parser.parse(lexed, [presets: presets])
        Parser.parse(lexed, [presets: presets, request_defaults: nil])
      _ -> :ok
    end
    acc
  rescue e ->
    if acc < 15, do: IO.puts("CRASH #{path}: #{Exception.format(:error, e, __STACKTRACE__) |> String.slice(0, 600)}")
    acc + 1
  end
end)
IO.puts("crashes: #{crashes}")
