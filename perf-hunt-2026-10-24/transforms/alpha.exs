[file, reps] = System.argv()
reps = String.to_integer(reps)
Vix.Vips.cache_set_max(0)
alias Vix.Vips.Operation, as: Op
alias Vix.Vips.Image, as: V

open = fn -> {:ok, i} = V.new_from_file(file <> "[access=sequential,fail_on=error]"); i end
{:ok, h} = V.new_from_file(file)
scale = 800 / Image.width(h)

variants = %{
  "thumbnail" => fn ->
    {:ok, t} = Op.thumbnail(file, 800, height: 100_000)
    {:ok, _} = V.copy_memory(t)
  end,
  "pipeline_resample" => fn ->
    i = open.()
    {:ok, i} = Op.colourspace(i, :VIPS_INTERPRETATION_sRGB)
    {:ok, r} = ImagePipe.Transform.Operation.Resize.resample(i, scale, scale, :lanczos3)
    {:ok, _} = V.copy_memory(r)
  end,
  "premul_resize_unpremul_cast" => fn ->
    i = open.()
    {:ok, p} = Op.premultiply(i)
    {:ok, r} = Op.resize(p, scale, vscale: scale)
    {:ok, u} = Op.unpremultiply(r)
    {:ok, c} = Op.cast(u, :VIPS_FORMAT_UCHAR)
    {:ok, _} = V.copy_memory(c)
  end,
  "premul_uchar_libvips" => fn ->
    i = open.()
    {:ok, p} = Op.premultiply(i)
    {:ok, p} = Op.cast(p, :VIPS_FORMAT_UCHAR)
    {:ok, r} = Op.resize(p, scale, vscale: scale)
    {:ok, u} = Op.unpremultiply(r)
    {:ok, c} = Op.cast(u, :VIPS_FORMAT_UCHAR)
    {:ok, _} = V.copy_memory(c)
  end,
  "premul_ushort" => fn ->
    i = open.()
    {:ok, w} = Op.linear(i, [257.0], [0.0])
    {:ok, w} = Op.cast(w, :VIPS_FORMAT_USHORT)
    {:ok, p} = Op.premultiply(w, max_alpha: 65535.0)
    {:ok, p} = Op.cast(p, :VIPS_FORMAT_USHORT)
    {:ok, r} = Op.resize(p, scale, vscale: scale)
    {:ok, u} = Op.unpremultiply(r, max_alpha: 65535.0)
    {:ok, u} = Op.linear(u, [1/257], [0.0])
    {:ok, u} = Op.round(u, :VIPS_OPERATION_ROUND_RINT)
    {:ok, c} = Op.cast(u, :VIPS_FORMAT_UCHAR)
    {:ok, _} = V.copy_memory(c)
  end,
  "premul_only_avg" => fn ->
    i = open.()
    {:ok, p} = Op.premultiply(i)
    {:ok, _} = Op.avg(p)
  end,
  "resize_float_noprem" => fn ->
    i = open.()
    {:ok, p} = Op.cast(i, :VIPS_FORMAT_FLOAT)
    {:ok, r} = Op.resize(p, scale, vscale: scale)
    {:ok, _} = V.copy_memory(r)
  end,
  "resize_ushort_noprem" => fn ->
    i = open.()
    {:ok, p} = Op.cast(i, :VIPS_FORMAT_USHORT)
    {:ok, r} = Op.resize(p, scale, vscale: scale)
    {:ok, _} = V.copy_memory(r)
  end,
  "plain_resize_uchar" => fn ->
    i = open.()
    {:ok, r} = Op.resize(i, scale, vscale: scale)
    {:ok, _} = V.copy_memory(r)
  end,
  "decode_only" => fn ->
    i = open.()
    {:ok, _} = Op.avg(i)
  end
}

names = Map.keys(variants) |> Enum.sort()
Enum.each(names, fn n -> variants[n].() end)

res =
  Enum.reduce(1..reps, %{}, fn _, acc ->
    Enum.reduce(names, acc, fn n, acc ->
      {t, _} = :timer.tc(variants[n])
      Map.update(acc, n, [t / 1000], &[t / 1000 | &1])
    end)
  end)

for n <- names do
  l = Enum.sort(res[n])
  IO.puts("#{n}: median=#{Float.round(Enum.at(l, div(length(l), 2)), 1)}ms")
end

# pixel comparison vs pipeline_resample
{:ok, ref} = variants["pipeline_resample"].()
for n <- ~w(premul_uchar_libvips premul_ushort thumbnail) do
  {:ok, o} = variants[n].()
  if Image.width(o) == Image.width(ref) and Image.height(o) == Image.height(ref) do
    {:ok, o} = Op.premultiply(o)
    {:ok, ref} = Op.premultiply(ref)
    {:ok, d} = Op.subtract(o, ref)
    {:ok, d} = Op.abs(d)
    {:ok, {mx, _}} = Op.max(d)
    {:ok, av} = Op.avg(d)
    # restrict to alpha>0 colour bands? report overall
    {:ok, hist} = Op.relational_const(d, :VIPS_OPERATION_RELATIONAL_MORE, [1.0])
    {:ok, frac} = Op.avg(hist)
    IO.puts("premultiplied diff #{n} vs pipeline: max=#{mx} avg=#{Float.round(av, 4)} frac>1level=#{Float.round(frac/255, 5)}")
  else
    IO.puts("diff #{n}: size #{Image.width(o)}x#{Image.height(o)} vs #{Image.width(ref)}x#{Image.height(ref)}")
  end
end
