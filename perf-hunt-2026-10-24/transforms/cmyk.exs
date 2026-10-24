[file, mode] = System.argv()
Vix.Vips.cache_set_max(0)
alias Vix.Vips.Image, as: V
alias Vix.Vips.Operation, as: Op
mb = fn -> Float.round(Vix.Vips.tracked_get_mem_highwater() / 1_048_576, 1) end
open = fn -> {:ok, i} = V.new_from_file(file <> "[access=sequential,fail_on=error]"); i end
crop = fn img -> {:ok, c} = Op.extract_area(img, 1736, 712, 2000, 2000); c end

current = fn ->
  i = open.()
  {:ok, i} = V.copy_memory(i)
  {:ok, prof} = V.header_value(i, "icc-profile-data")
  {:ok, imp} = Op.icc_import(i, embedded: true, pcs: ImagePipe.Transform.InputColorManagement.pcs(prof))
  {:ok, s} = Op.colourspace(imp, :VIPS_INTERPRETATION_sRGB)
  {:ok, s} = Image.remove_metadata(s, ["icc-profile-data"])
  {:ok, out} = V.copy_memory(crop.(s))
  out
end

lazy = fn ->
  i = open.()
  {:ok, s} = Op.icc_transform(i, "srgb", embedded: true)
  {:ok, out} = V.copy_memory(crop.(s))
  out
end

lazy_import = fn ->
  i = open.()
  {:ok, prof} = V.header_value(i, "icc-profile-data")
  {:ok, imp} = Op.icc_import(i, embedded: true, pcs: ImagePipe.Transform.InputColorManagement.pcs(prof))
  {:ok, s} = Op.colourspace(imp, :VIPS_INTERPRETATION_sRGB)
  {:ok, out} = V.copy_memory(crop.(s))
  out
end

lazy_export = fn ->
  i = open.()
  {:ok, prof} = V.header_value(i, "icc-profile-data")
  {:ok, imp} = Op.icc_import(i, embedded: true, pcs: ImagePipe.Transform.InputColorManagement.pcs(prof))
  {:ok, s} = Op.icc_export(imp, output_profile: "srgb", depth: 8)
  {:ok, out} = V.copy_memory(crop.(s))
  {:ok, p2} = V.header_value(out, "icc-profile-data")
  IO.puts("export profile srgb-equivalent? #{ImagePipe.SrgbProfile.equivalent?(p2)} interp=#{V.interpretation(out)}")
  out
end

case mode do
  "diff" ->
    a = current.()
    for {n, f} <- [lazy: lazy, lazy_import: lazy_import, lazy_export: lazy_export] do
      b = f.()
      {:ok, d} = Op.subtract(a, b)
      {:ok, d} = Op.abs(d)
      {:ok, {mx, _}} = Op.max(d)
      {:ok, av} = Op.avg(d)
      prof = V.header_value(b, "icc-profile-data")
      eq = case prof do
        {:ok, p} -> "profile bytes=#{byte_size(p)}"
        _ -> "no profile"
      end
      IO.puts("diff #{n}: max=#{mx} avg=#{Float.round(av, 4)} #{eq}")
    end

  m ->
    f = %{"current" => current, "lazy" => lazy, "lazy_import" => lazy_import, "lazy_export" => lazy_export}[m]
    {t, _} = :timer.tc(f)
    IO.puts("#{m}: #{div(t, 1000)}ms hw=#{mb.()}MiB")
end
