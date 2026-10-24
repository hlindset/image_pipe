for t <- :ets.all(), info = :ets.info(t), info != :undefined, n = info[:name],
    s = Atom.to_string(n), String.contains?(s, "SourceRecords") or String.contains?(s, "Memo") or String.contains?(s, "Recent") or String.contains?(s, "WatermarkBytes") do
  size = info[:size]
  bytes = info[:memory] * 8
  IO.puts("#{s} rows=#{size} bytes=#{bytes} per_row=#{if size > 0, do: div(bytes, size), else: 0}")
  case :ets.first(t) do
    :"$end_of_table" -> :ok
    k ->
      [row] = :ets.lookup(t, k)
      IO.puts("  flat_size_words=#{:erts_debug.flat_size(row)} external_size=#{:erlang.external_size(row)}")
      IO.inspect(row, limit: :infinity, printable_limit: 200, width: 160)
  end
end
