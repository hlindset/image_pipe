[t] = for t <- :ets.all(), is_atom(t), String.contains?(Atom.to_string(t), "Memo."), do: t
rows = :ets.tab2list(t)
words = fn x -> :erts_debug.flat_size(x) end
n = length(rows)
total = rows |> Enum.map(words) |> Enum.sum()
debug = rows |> Enum.map(fn {_k, {e, _m}, _} -> words.(e.debug) end) |> Enum.sum()
entry = rows |> Enum.map(fn {_k, {e, _m}, _} -> words.(e) end) |> Enum.sum()
meta = rows |> Enum.map(fn {_k, {_e, m}, _} -> words.(m) end) |> Enum.sum()
mem = :ets.info(t, :memory) * 8
IO.puts("rows=#{n} ets_bytes=#{mem} ets_bytes/row=#{div(mem, n)} flat_words/row=#{div(total, n)} (bytes #{div(total * 8, n)}) entry=#{div(entry * 8, n)}B debug=#{div(debug * 8, n)}B meta=#{div(meta * 8, n)}B")
# Compare against an empty table with the same options
e = :ets.new(:probe, [:public, :set, read_concurrency: true, write_concurrency: true])
IO.puts("empty table bytes=#{:ets.info(e, :memory) * 8}")
for r <- rows, do: :ets.insert(e, r)
IO.puts("copy bytes=#{:ets.info(e, :memory) * 8}")
:ets.delete_all_objects(e)
for {k, {en, m}, ep} <- rows, do: :ets.insert(e, {k, {%{en | debug: nil}, m}, ep})
IO.puts("copy without debug bytes=#{:ets.info(e, :memory) * 8}")
:ets.delete_all_objects(e)
for {k, {en, m}, ep} <- rows, do: :ets.insert(e, {k, {%{en | debug: :erlang.term_to_binary(en.debug)}, m}, ep})
IO.puts("copy with debug as term_to_binary bytes=#{:ets.info(e, :memory) * 8}")
[s] = for t <- :ets.all(), is_atom(t), String.contains?(Atom.to_string(t), "SourceRecords"), do: t
srows = :ets.tab2list(s)
:ets.delete_all_objects(e)
for i <- 1..2000, r <- [Enum.at(srows, rem(i, length(srows)))], do: :ets.insert(e, put_elem(r, 0, :crypto.strong_rand_bytes(32) |> Base.encode16(case: :lower)))
IO.puts("source records: 2000 rows bytes=#{:ets.info(e, :memory) * 8} per_row=#{div(:ets.info(e, :memory) * 8, 2000)}")
