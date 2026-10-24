[t] = for t <- :ets.all(), :ets.info(t, :name) == :entries, do: t
st = :sys.get_state(:ets.info(t, :owner))
IO.inspect({st.sketch.depth, st.sketch.width, :atomics.info(st.sketch.counters)}, label: "sketch")
IO.inspect(st.doorkeeper, label: "doorkeeper", limit: 5)
dk = st.doorkeeper
for {k, v} <- (if is_map(dk), do: Map.to_list(dk), else: []), is_reference(v) do
  IO.inspect({k, (try do :atomics.info(v) rescue _ -> :not_atomics end)})
end
