# elixir --sname sampler@localhost --cookie memhunt --hidden sampler.exs OUT.csv INTERVAL_MS
[out, interval] = System.argv()
interval = String.to_integer(interval)
node = :"memload@localhost"

wait = fn wait, n ->
  if Node.connect(node) == true or n == 0, do: :ok, else: (Process.sleep(500); wait.(wait, n - 1))
end

wait.(wait, 120)
os_pid = :rpc.call(node, :os, :getpid, []) |> List.to_string()
IO.puts("connected, os pid #{os_pid}")
{:ok, f} = File.open(out, [:write, :utf8])

IO.write(
  f,
  "t,rss_mb,rss_anon_mb,threads,erl_total,erl_proc,erl_bin,erl_ets,erl_code,erts_alloc_carriers,vips_mem,vips_hw,vips_conc,procs,ports,top\n"
)

mb = fn b -> Float.round(b / 1_048_576, 1) end
t0 = System.monotonic_time(:millisecond)

status = fn ->
  s = File.read!("/proc/#{os_pid}/status")
  get = fn k -> [_, v] = Regex.run(~r/#{k}:\s+(\d+)/, s); String.to_integer(v) end
  {get.("VmRSS") * 1024, get.("RssAnon") * 1024, get.("Threads")}
end

remote_code = """
  mem = :erlang.memory()

  carriers =
    for a <- :erlang.system_info(:alloc_util_allocators),
        {:instance, _, info} <- :erlang.system_info({:allocator, a}) || [],
        kind <- [:mbcs, :sbcs, :mbcs_pool],
        props = info[kind],
        props != nil,
        {:carriers_size, cur, _, _} <- props,
        reduce: 0 do
      acc -> acc + cur
    end

  top =
    Process.list()
    |> Enum.map(fn p ->
      case Process.info(p, [:memory, :registered_name, :initial_call, :dictionary, :binary]) do
        nil -> nil
        i ->
          bin = (i[:binary] || []) |> Enum.map(&elem(&1, 1)) |> Enum.sum()
          label = case i[:registered_name] do
            [] -> inspect(i[:dictionary][:"$initial_call"] || i[:initial_call])
            n -> inspect(n)
          end
          {i[:memory], bin, label}
      end
    end)
    |> Enum.reject(&is_nil/1)

  by_mem = top |> Enum.sort_by(&(-elem(&1, 0))) |> Enum.take(3)
  by_bin = top |> Enum.sort_by(&(-elem(&1, 1))) |> Enum.take(2)

  {mem, carriers, Vix.Vips.tracked_get_mem(), Vix.Vips.tracked_get_mem_highwater(),
   Vix.Vips.concurrency_get(), length(Process.list()), length(Port.list()), by_mem, by_bin}
"""

loop = fn loop ->
  {rss, anon, thr} = status.()

  case (case :rpc.call(node, Code, :eval_string, [remote_code], 10_000) do {:badrpc, _} = o -> o; {v, _} -> v end) do
    {mem, carriers, vm, vhw, vf, pc, ports, by_mem, by_bin} ->
      t = System.os_time(:millisecond) / 1000
      fmt = fn {m, b, l} -> "#{l}:#{mb.(m)}/#{mb.(b)}" end
      top = (Enum.map(by_mem, fmt) ++ ["BIN"] ++ Enum.map(by_bin, fmt)) |> Enum.join(" ") |> String.replace(",", ";")

      IO.write(
        f,
        "#{t},#{mb.(rss)},#{mb.(anon)},#{thr},#{mb.(mem[:total])},#{mb.(mem[:processes])},#{mb.(mem[:binary])},#{mb.(mem[:ets])},#{mb.(mem[:code])},#{mb.(carriers)},#{mb.(vm)},#{mb.(vhw)},#{vf},#{pc},#{ports},#{top}\n"
      )

    other ->
      IO.puts("rpc: #{inspect(other)}")
      if match?({:badrpc, :nodedown}, other), do: System.halt(0)
  end

  Process.sleep(interval)
  loop.(loop)
end

loop.(loop)
