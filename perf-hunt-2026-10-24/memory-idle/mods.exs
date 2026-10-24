loaded = :code.all_loaded() |> Enum.map(&elem(&1, 0)) |> MapSet.new()
apps = for {app, _, _} <- Application.loaded_applications(), do: app
started = for {app, _, _} <- Application.started_applications(), do: app
rows =
  for app <- apps do
    mods = Application.spec(app, :modules) || []
    l = Enum.filter(mods, &MapSet.member?(loaded, &1))
    size = l |> Enum.map(fn m -> case :code.get_object_code(m) do {_, b, _} -> byte_size(b); _ -> 0 end end) |> Enum.sum()
    {app, length(l), length(mods), size, app in started}
  end
rows |> Enum.sort_by(&(-elem(&1, 3))) |> Enum.take(40) |> Enum.each(fn {a, l, t, s, st} -> IO.puts("#{a} loaded=#{l}/#{t} beam_kb=#{div(s, 1024)} started=#{st}") end)
IO.inspect(started, limit: :infinity)
