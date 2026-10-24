alias ImagePipe.API.{Parser, Path, OptionSpec}
{:ok, %{presets: presets, request_defaults: defaults}} = ImagePipe.API.Presets.compile(%{
  "a" => "w=100/h=100/fit=cover/anchor=top",
  "b" => "blur=2/q=80/format-q=webp:70",
  "p" => "w=10/-/blur=1",
  "u" => "anchor=unset/q=unset/crop=unset",
  "n" => "preset=a/h=50/crop=10,10",
  "e" => "",
  "r" => "region=0,0,10,10/extend/bg=fff",
  "j" => "jpeg-options=unset,progressive/format-q=unset,avif:50"
}, "q=75/sharpen=1/crop-ratio=1:1/anchor-offset=1,1")
keys = Enum.map(OptionSpec.all(), & &1.key)
names = ["a","b","p","u","n","e","r","j"]
chars = String.graphemes(",:.-0123456789abcdefxyzunsetpcqhvlrgwtuo=!_") ++ ["unset,", "unset", "pct", "auto", "info", "jpeg", "webp", "all", "red", "-", "keep-alpha", "left", "false", "smart", "cover", "10", "10,10"]
:rand.seed(:exsss, {4, 5, 6})
gen_val = fn -> n = :rand.uniform(4); Enum.map_join(1..n, fn _ -> Enum.random(chars) end) end
gen_seg = fn ->
  case :rand.uniform(12) do
    1 -> "-"
    2 -> Enum.random(keys)
    n when n in 3..5 -> "preset=" <> Enum.join(Enum.take_random(names, :rand.uniform(3)), ",")
    6 -> Enum.random(keys) <> "=unset"
    _ -> Enum.random(keys) <> "=" <> gen_val.()
  end
end
crashes = Enum.reduce(1..200_000, 0, fn _, acc ->
  segs = Enum.map(1..:rand.uniform(6), fn _ -> gen_seg.() end)
  path = "/" <> Enum.join(segs, "/") <> "/src/a"
  try do
    case Path.extract(path, "") do
      {:ok, lexed} ->
        Parser.parse(lexed, [presets: presets])
        Parser.parse(lexed, [presets: presets, request_defaults: defaults])
      _ -> :ok
    end
    acc
  rescue e ->
    if acc < 10, do: IO.puts("CRASH #{path}: #{Exception.format(:error, e, __STACKTRACE__) |> String.slice(0, 900)}")
    acc + 1
  end
end)
IO.puts("crashes: #{crashes}")
