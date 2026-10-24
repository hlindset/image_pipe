dir = System.argv() |> hd()
File.mkdir_p!(dir)
alias Vix.Vips.Image, as: V
alias Vix.Vips.{Operation, MutableImage}

src = Image.open!("priv/static/images/mountain.jpg", access: :random)
Image.write!(src, Path.join(dir, "plain.jpg"), quality: 90)

# exif6: store pixels rotated -90 so that orientation 6 restores the display frame
{:ok, stored} = Operation.rot(src, :VIPS_ANGLE_D270)
{:ok, stored} = V.mutate(stored, fn m -> MutableImage.set(m, "orientation", :gint, 6) end)
Image.write!(stored, Path.join(dir, "exif6.jpg"), quality: 90)

p3 = Image.open!("test/support/image_pipe/test/sources/icc_p3.png")
{:ok, prof} = V.header_value(p3, "icc-profile-data")
{:ok, tagged} = V.mutate(src, fn m -> MutableImage.set(m, "icc-profile-data", :VipsBlob, prof) end)
Image.write!(tagged, Path.join(dir, "p3.jpg"), quality: 90)

{:ok, cmyk} = Operation.icc_export(src, output_profile: "cmyk")
Image.write!(cmyk, Path.join(dir, "cmyk.jpg"), quality: 90)

Image.write!(Image.open!("priv/static/images/cooking.png"), Path.join(dir, "alpha.png"))
Image.write!(src, Path.join(dir, "plain.webp"), quality: 90)
Image.write!(src, Path.join(dir, "plain.png"))
{:ok, src16} = Operation.cast(src, :VIPS_FORMAT_USHORT)
{:ok, src16} = Operation.linear(src16, [257.0], [0.0])
{:ok, src16} = Operation.cast(src16, :VIPS_FORMAT_USHORT)
{:ok, src16} = Operation.copy(src16, interpretation: :VIPS_INTERPRETATION_RGB16)
Image.write!(src16, Path.join(dir, "rgb16.png"))
IO.puts("ok")
