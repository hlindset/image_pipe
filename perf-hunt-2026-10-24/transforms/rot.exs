[file, mode] = System.argv()
Vix.Vips.cache_set_max(0)
alias Vix.Vips.Image, as: V
mb = fn -> Float.round(Vix.Vips.tracked_get_mem_highwater() / 1_048_576, 1) end
{:ok, i} = V.new_from_file(file <> "[access=sequential,fail_on=error]")

{t, _} =
  :timer.tc(fn ->
    {:ok, m} = V.copy_memory(i)
    {:ok, {r, _}} = Image.autorotate(m)

    r =
      case mode do
        "copy_after" ->
          {:ok, r} = V.copy_memory(r)
          r

        "lazy" ->
          r
      end

    {:ok, _} = V.write_to_buffer(r, ".jpg[Q=80]")
  end)

IO.puts("#{mode}: #{div(t, 1000)}ms hw=#{mb.()}MiB")
