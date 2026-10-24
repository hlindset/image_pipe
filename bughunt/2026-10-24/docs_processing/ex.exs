files = System.argv()
for f <- files do
  text = File.read!(f)
  re = ~r/### URL\n\n```text\n(.*?)\n```\n\n### Elixir\n\n```elixir\n(.*?)\n```/s
  for [_, url, code] <- Regex.scan(re, text) do
    for u <- String.split(url, "\n"), String.contains?(u, "/src/") or true do
      :ok
    end
    builder = ImagePipe.URL.new()
    res =
      try do
        {val, _} = Code.eval_string(code, [builder: builder, url_config: ImagePipe.URL.config()])
        urls = String.split(url, "\n")
        u1 = hd(urls)
        src = case String.split(u1, "/src/", parts: 2) do [_, s] -> s; _ -> "photos/beach.jpg" end
        vals = if is_list(val), do: val, else: [val]
        got = Enum.map(vals, fn
          %ImagePipe.URL{} = b ->
            case ImagePipe.URL.url(b, src) do
              {:ok, u} -> u
              other -> inspect(other)
            end
          s when is_binary(s) -> s
          o -> inspect(o)
        end)
        {urls, got}
      rescue e -> {url, "RAISE " <> Exception.message(e)}
      end
    case res do
      {urls, got} when is_list(got) ->
        norm = fn s -> s |> String.split("/") |> Enum.sort() end
        same = length(urls) == length(got) and Enum.all?(Enum.zip(urls, got), fn {a, b} -> norm.(a) == norm.(b) or String.ends_with?(b, a) end)
        unless same, do: IO.puts("MISMATCH #{Path.basename(f)}\n  doc:  #{inspect urls}\n  code: #{String.replace(code, "\n", " ")}\n  got:  #{inspect got}")
      {u, err} -> IO.puts("MISMATCH #{Path.basename(f)}\n  doc: #{u}\n  #{err}\n  code: #{String.replace(code, "\n", " ")}")
    end
  end
end
