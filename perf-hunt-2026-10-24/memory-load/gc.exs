# bin_leak-style: per-process refc binary bytes and heap before/after a forced GC of every process.
node = :"memload@localhost"
true = Node.connect(node)

code = """
info = fn p ->
  case Process.info(p, [:binary, :memory, :registered_name, :dictionary, :initial_call, :message_queue_len]) do
    nil -> nil
    i ->
      bin = (i[:binary] || []) |> Enum.map(&elem(&1, 1)) |> Enum.sum()
      label = case i[:registered_name] do
        [] -> inspect(i[:dictionary][:"$initial_call"] || i[:initial_call])
        n -> inspect(n)
      end
      {bin, i[:memory], label, i[:message_queue_len]}
  end
end
before_mem = :erlang.memory()
before = for p <- Process.list(), i = info.(p), i != nil, into: %{}, do: {p, i}
Enum.each(Process.list(), &:erlang.garbage_collect/1)
Process.sleep(500)
after_mem = :erlang.memory()
deltas =
  for {p, {b0, m0, l, q}} <- before do
    {b1, m1} = case info.(p) do nil -> {0, 0}; {b, m, _, _} -> {b, m} end
    {b0 - b1, m0 - m1, b0, m0, l, q}
  end
  |> Enum.sort_by(fn {db, dm, _, _, _, _} -> -(db + dm) end)
  |> Enum.take(8)
{Keyword.take(before_mem, [:total, :processes, :binary, :ets]), Keyword.take(after_mem, [:total, :processes, :binary, :ets]), deltas, length(Process.list())}
"""

{{b, a, d, n}, _} = :rpc.call(node, Code, :eval_string, [code], 60_000)
mb = fn x -> Float.round(x / 1_048_576, 2) end
IO.puts("procs=#{n} before: #{inspect(Enum.map(b, fn {k, v} -> {k, mb.(v)} end))}")
IO.puts("        after: #{inspect(Enum.map(a, fn {k, v} -> {k, mb.(v)} end))}")
for {db, dm, b0, m0, l, q} <- d, do: IO.puts("  freed bin=#{mb.(db)} heap=#{mb.(dm)} (had bin=#{mb.(b0)} mem=#{mb.(m0)} q=#{q}) #{l}")
