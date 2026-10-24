mib = fn b -> Float.round(b / 1048576, 3) end
rows =
  for p <- Process.list(), info = Process.info(p, [:memory, :registered_name, :initial_call, :dictionary, :heap_size, :total_heap_size, :stack_size, :message_queue_len]), info != nil do
    ic = info[:dictionary][:"$initial_call"] || info[:initial_call]
    anc = info[:dictionary][:"$ancestors"] |> List.wrap() |> Enum.take(1)
    {ic, anc, info[:memory], info[:total_heap_size]}
  end
rows
|> Enum.group_by(fn {ic, anc, _, _} -> {ic, anc} end)
|> Enum.map(fn {k, l} -> {k, length(l), l |> Enum.map(&elem(&1, 2)) |> Enum.sum()} end)
|> Enum.sort_by(&(-elem(&1, 2)))
|> Enum.take(25)
|> Enum.each(fn {k, n, m} -> IO.puts("#{mib.(m)} MiB  n=#{n}  #{inspect(k)}") end)
IO.puts("sum #{mib.(rows |> Enum.map(&elem(&1, 2)) |> Enum.sum())}")
