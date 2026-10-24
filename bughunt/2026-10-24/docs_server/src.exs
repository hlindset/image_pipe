for m <- [ImagePipe.Source.File, ImagePipe.Source.HTTP] do
  IO.puts("##### #{inspect(m)}")
  for {k, spec} <- m.options_schema() do
    IO.puts("#{k} | default=#{inspect(spec[:default])} | type=#{inspect(spec[:type]) |> String.slice(0,80)} | #{String.replace(spec[:doc] || "", "\n", " ")}\n")
  end
end
