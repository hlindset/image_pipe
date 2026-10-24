mib = fn b -> Float.round(b / 1048576, 2) end
os_pid = :os.getpid()
status = File.read!("/proc/#{os_pid}/status")
field = fn name -> Regex.run(~r/#{name}:\s+(\d+)/, status) |> List.last() |> String.to_integer() |> Kernel.*(1024) end
IO.puts("RSS #{mib.(field.("VmRSS"))} RssShmem #{mib.(field.("RssShmem"))}  RssAnon #{mib.(field.("RssAnon"))}  RssFile #{mib.(field.("RssFile"))}  VmSize #{mib.(field.("VmSize"))}")
m = :erlang.memory()
IO.inspect(Enum.map(m, fn {k, v} -> {k, mib.(v)} end), label: "erlang.memory", limit: :infinity)

get = fn kv, key -> Enum.find_value(kv, 0, fn
  {^key, cur, _, _} -> cur
  {^key, cur} when is_integer(cur) -> cur
  _ -> nil end) end

per =
  for a <- :erlang.system_info(:alloc_util_allocators) do
    info = :erlang.system_info({:allocator, a}) || []
    {car, blk} =
      for {:instance, _, props} <- info, k <- [:mbcs, :sbcs], kv = props[k], kv != nil, reduce: {0, 0} do
        {c, b} ->
          blocks = case Keyword.get(kv, :blocks) do
            l when is_list(l) -> Enum.reduce(l, 0, fn {_t, bl}, acc -> acc + (Enum.find(bl, fn t -> elem(t, 0) == :size end) |> case do {:size, s, _, _} -> s; {s, _, _} -> s; {:size, s, _, _} -> s; s when is_integer(s) -> s; _ -> 0 end) end)
            _ -> get.(kv, :blocks_size)
          end
          {c + get.(kv, :carriers_size), b + blocks}
      end
    {a, car, blk}
  end
total_car = per |> Enum.map(&elem(&1, 1)) |> Enum.sum()
total_blk = per |> Enum.map(&elem(&1, 2)) |> Enum.sum()
IO.puts("alloc_util carriers #{mib.(total_car)} blocks #{mib.(total_blk)}")
IO.inspect(per |> Enum.sort_by(&(-elem(&1, 1))) |> Enum.take(10) |> Enum.map(fn {a, c, b} -> {a, mib.(c), mib.(b)} end), label: "alloc carriers/blocks")
IO.inspect({:vips_tracked, mib.(Vix.Vips.tracked_get_mem()), :highwater, mib.(Vix.Vips.tracked_get_mem_highwater()), :cache_max, Vix.Vips.cache_get_max(), :cache_max_mem, Vix.Vips.cache_get_max_mem(), :cache_max_files, Vix.Vips.cache_get_max_files()})
IO.inspect({:procs, :erlang.system_info(:process_count), :ports, :erlang.system_info(:port_count), :threads, File.ls!("/proc/#{os_pid}/task") |> length()})
ets = for t <- :ets.all(), info = :ets.info(t), info != :undefined, do: {info[:name], info[:memory] * 8, info[:size]}
IO.inspect(ets |> Enum.sort_by(&(-elem(&1, 1))) |> Enum.take(12) |> Enum.map(fn {n, b, s} -> {n, mib.(b), s} end), label: "top ets", limit: :infinity)
pt = :persistent_term.get() |> Enum.map(fn {k, v} -> {k, :erts_debug.flat_size(v) * 8} end) |> Enum.sort_by(&(-elem(&1, 1)))
IO.puts("persistent_term count #{length(pt)} words-sum #{mib.(pt |> Enum.map(&elem(&1, 1)) |> Enum.sum())}")
IO.inspect(Enum.take(pt, 8) |> Enum.map(fn {k, b} -> {k, mib.(b)} end), label: "top persistent_term", limit: 20, printable_limit: 80)
procs = for p <- Process.list(), info = Process.info(p, [:memory, :registered_name, :initial_call, :dictionary]), info != nil, do: {p, info[:memory], info[:registered_name], info[:dictionary][:"$initial_call"] || info[:initial_call]}
IO.inspect(procs |> Enum.sort_by(&(-elem(&1, 1))) |> Enum.take(12) |> Enum.map(fn {_p, m, n, c} -> {mib.(m), n, c} end), label: "top procs", limit: :infinity)
IO.puts("loaded modules #{length(:code.all_loaded())}")
