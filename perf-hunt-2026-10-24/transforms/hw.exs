[file, mode] = System.argv()
Vix.Vips.cache_set_max(0)
alias Vix.Vips.Image, as: V
alias Vix.Vips.{Operation, MutableImage}
{:ok, i} = V.new_from_file(file <> "[access=sequential,fail_on=error]")
mb = fn -> Float.round(Vix.Vips.tracked_get_mem_highwater() / 1_048_576, 1) end

case mode do
  "copy" ->
    {:ok, m} = V.copy_memory(i)
    IO.puts("copy hw=#{mb.()}")

  "copy_mutate" ->
    {:ok, m} = V.copy_memory(i)
    IO.puts("after copy hw=#{mb.()}")
    {:ok, m2} = V.mutate(m, &MutableImage.remove(&1, "vips-sequential"))
    IO.puts("after mutate hw=#{mb.()}")

  "copy_save" ->
    {:ok, m} = V.copy_memory(i)
    IO.puts("after copy hw=#{mb.()}")
    {:ok, _} = V.write_to_buffer(m, ".jpg[Q=80]")
    IO.puts("after save hw=#{mb.()}")

  "copy_mutate_save" ->
    {:ok, m} = V.copy_memory(i)
    {:ok, m} = V.mutate(m, &MutableImage.remove(&1, "vips-sequential"))
    IO.puts("after copy+mutate hw=#{mb.()}")
    {:ok, _} = V.write_to_buffer(m, ".jpg[Q=80]")
    IO.puts("after save hw=#{mb.()}")

  "copy_remove_meta_save" ->
    {:ok, m} = V.copy_memory(i)
    {:ok, m} = Image.remove_metadata(m, ["icc-profile-data"])
    IO.puts("after copy+remove hw=#{mb.()}")
    {:ok, _} = V.write_to_buffer(m, ".jpg[Q=80]")
    IO.puts("after save hw=#{mb.()}")
end
