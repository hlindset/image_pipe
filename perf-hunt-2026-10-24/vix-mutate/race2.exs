alias Vix.Vips.{Image, MutableImage, Operation}
srgb = File.read!("priv/icc/sRGB.icc")
p3 = File.read!("priv/icc/DisplayP3.icc")
_ = ImagePipe.SrgbProfile.equivalent?(srgb)
{_lattice, imported} = :persistent_term.get({ImagePipe.SrgbProfile, :lattice})
{:ok, prof} = Image.header_value(imported, "icc-profile-data")
IO.inspect(prof == srgb, label: "cached lattice now carries the last checked profile (sRGB)")

set = fn img, p -> Image.mutate(img, fn m -> MutableImage.set(m, "icc-profile-data", :VipsBlob, p) end) end
{:ok, tagged_p3} = set.(imported, p3)     # process A tags for P3
{:ok, _tagged_srgb} = set.(imported, srgb) # process B tags for sRGB before A exports
{:ok, out} = Operation.icc_export(tagged_p3, depth: 8)
{:ok, bytes} = Image.write_to_binary(out)
{:ok, ref} = Operation.icc_export(elem(set.(imported, p3), 1), depth: 8)
{:ok, ref_bytes} = Image.write_to_binary(ref)
IO.inspect(bytes == ref_bytes, label: "A's export used P3 (expected true if isolated)")
