[t] = for t <- :ets.all(), :ets.info(t, :name) == :entries, do: t
p = :ets.info(t, :owner)
IO.inspect(Process.info(p, [:memory, :total_heap_size, :message_queue_len, :dictionary]) |> Keyword.drop([:dictionary]), label: "admission")
st = :sys.get_state(p)
IO.puts("state flat bytes=#{:erts_debug.flat_size(st) * 8}")
if is_map(st) do
  st |> Map.to_list() |> Enum.map(fn {k, v} -> {k, :erts_debug.flat_size(v) * 8} end) |> Enum.sort_by(&(-elem(&1, 1))) |> Enum.take(10) |> IO.inspect()
end
