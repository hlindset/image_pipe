alias Vix.Vips.{Operation, MutableImage}
alias Vix.Vips.Image, as: VI
out = System.get_env("OUT")
{:ok, srgb} = Operation.profile_load("srgb")
{:ok, cmyk} = Operation.icc_transform(Image.new!(96, 64, color: [200, 30, 40]), "cmyk", input_profile: "srgb")
{:ok, cmyk} = VI.mutate(cmyk, &MutableImage.set(&1, "icc-profile-data", :VipsBlob, srgb))
:ok = VI.write_to_file(cmyk, out)
