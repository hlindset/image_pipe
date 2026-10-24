[file, mode, fmt, w] = System.argv()
Vix.Vips.cache_set_max(0)
alias Vix.Vips.Image, as: V

{t, _} =
  :timer.tc(fn ->
    {:ok, i} = V.new_from_file(file <> "[access=sequential,fail_on=error]")
    w = String.to_integer(w)
    i = if w > 0 do
      {:ok, i} = V.new_from_file(file <> "[access=sequential,fail_on=error,shrink=2]")
      {:ok, r} = Vix.Vips.Operation.resize(i, w / Image.width(i)); r
    else i end
    i = if mode == "copy", do: elem(V.copy_memory(i), 1), else: i
    {:ok, _} = V.write_to_buffer(i, fmt)
  end)

IO.puts("#{mode} #{fmt}: #{div(t, 1000)}ms hw=#{Float.round(Vix.Vips.tracked_get_mem_highwater() / 1_048_576, 1)}MiB")
