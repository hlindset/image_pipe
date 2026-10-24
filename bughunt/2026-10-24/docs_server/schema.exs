walk = fn walk, schema, prefix ->
  for {k, spec} <- schema do
    name = prefix <> to_string(k)
    doc = (spec[:doc] || "") |> String.replace("\n", " ")
    if Regex.match?(~r/[Dd]efault|[0-9]{3,}/, doc) or Keyword.has_key?(spec, :default) do
      IO.puts("#{name} | default=#{inspect(spec[:default], limit: 5)} | #{String.slice(doc, 0, 700)}\n")
    end
    case spec[:keys] do
      ks when is_list(ks) -> walk.(walk, ks, name <> ".")
      _ -> :ok
    end
  end
end
walk.(walk, ImagePipe.Config.processing_schema(), "")
