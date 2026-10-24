[file, opts, conc] = System.argv()
Vix.Vips.cache_set_max(0)
if conc != "default", do: Vix.Vips.concurrency_set(String.to_integer(conc))
alias Vix.Vips.Image, as: V
alias Vix.Vips.Operation, as: Op
{:ok, i} = V.new_from_file(file <> "[#{opts}]")
{t, _} = :timer.tc(fn -> {:ok, _} = V.copy_memory(i) end)
IO.puts("#{opts} conc=#{conc} #{Image.width(i)}x#{Image.height(i)}b#{V.bands(i)}: #{div(t, 1000)}ms hw=#{Float.round(Vix.Vips.tracked_get_mem_highwater() / 1_048_576, 1)}MiB")
