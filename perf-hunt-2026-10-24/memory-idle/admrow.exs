for t <- :ets.all(), :ets.info(t, :name) in [:entries, :scan_changes] do
  n = :ets.info(t, :size)
  mem = :ets.info(t, :memory) * 8
  IO.puts("#{:ets.info(t, :name)} owner=#{inspect(:ets.info(t, :owner))} rows=#{n} bytes=#{mem} per_row=#{if n > 0, do: div(mem, n), else: 0}")
  case :ets.first(t) do
    :"$end_of_table" -> :ok
    k -> IO.inspect(:ets.lookup(t, k), limit: :infinity, printable_limit: 120, width: 160)
  end
end
# Admission process state size
for p <- Process.list(), {:dictionary, d} = Process.info(p, :dictionary), (d[:"$initial_call"] || {}) |> elem(0) |> to_string() |> String.contains?("Admission") do
  {:memory, m} = Process.info(p, :memory)
  IO.puts("admission proc #{inspect(p)} memory=#{m}")
  st = :sys.get_state(p)
  IO.puts("state flat bytes=#{:erts_debug.flat_size(st) * 8}")
  if is_map(st), do: IO.inspect(st |> Map.from_struct() |> Enum.map(fn {k, v} -> {k, :erts_debug.flat_size(v) * 8} end) |> Enum.sort_by(&(-elem(&1, 1))) |> Enum.take(8))
end
