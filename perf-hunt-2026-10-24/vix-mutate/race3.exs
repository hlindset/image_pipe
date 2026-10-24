alias Vix.Vips.{Image, MutableImage, Operation}
Vix.Vips.cache_set_max(0)
srgb = File.read!("priv/icc/sRGB.icc")
p3 = File.read!("priv/icc/DisplayP3.icc")
_ = ImagePipe.SrgbProfile.equivalent?(srgb)
{_lattice, imported} = :persistent_term.get({ImagePipe.SrgbProfile, :lattice})
set = fn img, p -> Image.mutate(img, fn m -> MutableImage.set(m, "icc-profile-data", :VipsBlob, p) end) end
export = fn img -> {:ok, o} = Operation.icc_export(img, depth: 8); {:ok, b} = Image.write_to_binary(o); b end
{:ok, a} = set.(imported, p3)
IO.inspect(a.ref == imported.ref, label: "same ref")
pa = export.(a)
{:ok, _} = set.(imported, srgb)
{:ok, hv} = Image.header_value(a, "icc-profile-data")
IO.inspect(hv == srgb, label: "A's handle now reports sRGB header")
pb = export.(a)
IO.inspect(pa == pb, label: "export of A identical before/after B's set (true = profile not re-read)")
