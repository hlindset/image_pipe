defmodule Premul16 do
  alias Vix.Vips.Operation, as: Op
  def run(i, scale) do
    {:ok, p} = Op.premultiply(i)
    {:ok, p} = Op.linear(p, [257.0], [0.0])
    {:ok, p} = Op.round(p, :VIPS_OPERATION_ROUND_RINT)
    {:ok, p} = Op.cast(p, :VIPS_FORMAT_USHORT)
    {:ok, r} = Op.resize(p, scale)
    {:ok, u} = Op.unpremultiply(r, max_alpha: 65535.0)
    {:ok, u} = Op.linear(u, [1 / 257], [0.0])
    {:ok, u} = Op.round(u, :VIPS_OPERATION_ROUND_RINT)
    Op.cast(u, :VIPS_FORMAT_UCHAR)
  end
end
[file, mode, w] = System.argv()
Vix.Vips.cache_set_max(0)
alias Vix.Vips.Image, as: V
alias Vix.Vips.Operation, as: Op
{:ok, i} = V.new_from_file(file <> "[access=sequential,fail_on=error]")
scale = String.to_integer(w) / Image.width(i)
mb = fn -> Float.round(Vix.Vips.tracked_get_mem_highwater() / 1_048_576, 1) end

{t, _} =
  :timer.tc(fn ->
    case mode do
      "thumb" ->
        {:ok, t} = Op.thumbnail(file, String.to_integer(w), height: 100_000)
        {:ok, _} = V.copy_memory(t)

      "resize" ->
        {:ok, r} = Op.resize(i, scale)
        {:ok, _} = V.copy_memory(r)

      "float" ->
        {:ok, f} = Op.cast(i, :VIPS_FORMAT_FLOAT)
        {:ok, r} = Op.resize(f, scale)
        {:ok, _} = V.copy_memory(r)

      "pipeline" ->
        {:ok, r} = ImagePipe.Transform.Operation.Resize.resample(i, scale, scale, :lanczos3)
        {:ok, _} = V.copy_memory(r)

      "buf_pipeline" ->
        {:ok, b} = ImagePipe.Transform.MemoryCopy.copy(i)
        {:ok, r} = ImagePipe.Transform.Operation.Resize.resample(b, scale, scale, :lanczos3)
        {:ok, _} = V.copy_memory(r)

      "random_pipeline" ->
        {:ok, b} = V.new_from_file(file <> "[access=random]")
        {:ok, r} = ImagePipe.Transform.Operation.Resize.resample(b, scale, scale, :lanczos3)
        {:ok, _} = V.copy_memory(r)

      "premul16" ->
        {:ok, r} = Premul16.run(i, scale)
        {:ok, _} = V.copy_memory(r)

      "premul8" ->
        {:ok, p} = Op.premultiply(i)
        {:ok, p} = Op.cast(p, :VIPS_FORMAT_UCHAR)
        {:ok, r} = Op.resize(p, scale)
        {:ok, r} = Op.unpremultiply(r)
        {:ok, r} = Op.cast(r, :VIPS_FORMAT_UCHAR)
        {:ok, _} = V.copy_memory(r)

      "diff" ->
        {:ok, a} = ImagePipe.Transform.Operation.Resize.resample(i, scale, scale, :lanczos3)
        {:ok, a} = V.copy_memory(a)
        {:ok, i2} = V.new_from_file(file)
        {:ok, b} = Premul16.run(i2, scale)
        {:ok, d} = Op.subtract(a, b)
        {:ok, d} = Op.abs(d)
        {:ok, {mx, _}} = Op.max(d)
        {:ok, nz} = Op.relational_const(d, :VIPS_OPERATION_RELATIONAL_MORE, [0.0])
        {:ok, frac} = Op.avg(nz)
        IO.puts("premul16 vs pipeline: max=#{mx} frac_nonzero=#{Float.round(frac / 255, 6)}")

      "decode" ->
        {:ok, _} = Op.avg(i)
    end
  end)

IO.puts("#{Path.basename(file)} #{mode} w=#{w}: #{div(t, 1000)}ms hw=#{mb.()}MiB")
