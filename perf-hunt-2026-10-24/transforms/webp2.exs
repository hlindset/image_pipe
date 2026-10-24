[file, mode] = System.argv()
Vix.Vips.cache_set_max(0)
alias Vix.Vips.Image, as: V
mb = fn -> Float.round(Vix.Vips.tracked_get_mem_highwater() / 1_048_576, 1) end
cur = fn -> Float.round(Vix.Vips.tracked_get_mem() / 1_048_576, 1) end

{t, _} =
  :timer.tc(fn ->
    if mode in ["header_then_scaled", "header_gc_then_scaled"] do
      {:ok, h} = V.new_from_file(file <> "[access=sequential,fail_on=error]")
      _ = Image.width(h)
      IO.puts("after header open: hw=#{mb.()} cur=#{cur.()}")
      if mode == "header_gc_then_scaled", do: :erlang.garbage_collect()
    end

    {:ok, i} = V.new_from_file(file <> "[access=sequential,fail_on=error,scale=0.25]")
    {:ok, _} = V.copy_memory(i)
  end)

IO.puts("#{mode}: #{div(t, 1000)}ms hw=#{mb.()}MiB")
