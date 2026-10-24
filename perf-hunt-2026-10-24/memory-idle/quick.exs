mib = fn b -> Float.round(b / 1048576, 2) end
status = File.read!("/proc/#{:os.getpid()}/status")
field = fn name -> Regex.run(~r/#{name}:\s+(\d+)/, status) |> List.last() |> String.to_integer() |> Kernel.*(1024) |> mib.() end
IO.puts("node=#{node()} plimit=#{:erlang.system_info(:process_limit)} RSS=#{field.("VmRSS")} anon=#{field.("RssAnon")} shm=#{field.("RssShmem")} file=#{field.("RssFile")} " <>
  Enum.map_join(:erlang.memory(), " ", fn {k, v} -> "#{k}=#{mib.(v)}" end) <> " vips=#{mib.(Vix.Vips.tracked_get_mem())} vips_hw=#{mib.(Vix.Vips.tracked_get_mem_highwater())} threads=#{length(File.ls!("/proc/#{:os.getpid()}/task"))}")
