[file, opts] = System.argv()
Vix.Vips.cache_set_max(0)
rss = fn ->
  s = File.read!("/proc/self/status")
  [_, rss] = Regex.run(~r/VmRSS:\s+(\d+)/, s)
  [_, hwm] = Regex.run(~r/VmHWM:\s+(\d+)/, s)
  "rss=#{div(String.to_integer(rss), 1024)}MiB hwm=#{div(String.to_integer(hwm), 1024)}MiB"
end
IO.puts("before: #{rss.()}")
{:ok, h} = Vix.Vips.Image.new_from_file(file <> "[#{opts}]")
_ = Image.width(h)
IO.puts("after header #{opts}: #{rss.()} tracked_hw=#{Float.round(Vix.Vips.tracked_get_mem_highwater() / 1048576, 1)}")
