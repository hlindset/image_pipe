rows =
  for {m, _} <- :code.all_loaded() do
    size = case :code.get_object_code(m) do {_, b, _} -> byte_size(b); _ -> 0 end
    {m, size}
  end
rows |> Enum.sort_by(&(-elem(&1, 1))) |> Enum.take(30) |> Enum.each(fn {m, s} -> IO.puts("#{div(s, 1024)} KB #{inspect(m)}") end)
IO.puts("total #{div(rows |> Enum.map(&elem(&1, 1)) |> Enum.sum(), 1024)} KB in #{length(rows)} modules")
