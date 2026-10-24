Code.require_file("h.exs", __DIR__)
alias Vix.Vips.Operation, as: O
d = Path.join(__DIR__, "src")
img = H.noise(40, 30)
{:ok, f} = O.linear(img, [1/255], [0.0])
{:ok, f} = O.cast(f, :VIPS_FORMAT_FLOAT)
{:ok, f1} = O.copy(f, interpretation: :VIPS_INTERPRETATION_sRGB)
Vix.Vips.Image.write_to_file(f1, Path.join(d, "float_srgb.tif")) |> IO.inspect
{:ok, f2} = O.copy(f, interpretation: :VIPS_INTERPRETATION_scRGB)
Vix.Vips.Image.write_to_file(f2, Path.join(d, "float_scrgb.tif")) |> IO.inspect
{:ok, i32} = O.cast(img, :VIPS_FORMAT_UINT)
Vix.Vips.Image.write_to_file(i32, Path.join(d, "uint.tif")) |> IO.inspect
{:ok, two} = O.extract_band(img, 0, n: 2)
{:ok, two} = O.copy(two, interpretation: :VIPS_INTERPRETATION_MULTIBAND)
Vix.Vips.Image.write_to_file(two, Path.join(d, "twoband.tif")) |> IO.inspect
{:ok, a} = O.bandjoin_const(img, [128.0])
{:ok, cmyk} = O.copy(a, interpretation: :VIPS_INTERPRETATION_CMYK)
Vix.Vips.Image.write_to_file(cmyk, Path.join(d, "cmyk.tif")) |> IO.inspect
{:ok, a5} = O.bandjoin_const(a, [200.0])
{:ok, cmyka} = O.copy(a5, interpretation: :VIPS_INTERPRETATION_CMYK)
Vix.Vips.Image.write_to_file(cmyka, Path.join(d, "cmyka.tif")) |> IO.inspect
{:ok, s16} = O.cast(img, :VIPS_FORMAT_SHORT)
Vix.Vips.Image.write_to_file(s16, Path.join(d, "short.tif")) |> IO.inspect
for f <- File.ls!(d), do: IO.inspect({f, Image.open!(Path.join(d,f)) |> then(&{Vix.Vips.Image.format(&1), Vix.Vips.Image.interpretation(&1), Image.bands(&1)})})
