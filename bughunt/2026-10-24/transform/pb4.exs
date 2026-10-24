alias Vix.Vips.Operation, as: O
alias ImagePipe.Transform.Operation.{AlphaPremultiply, GaussianBlur}
bytes = File.read!(Path.join(__DIR__, "src/cmyka.tif"))
{:ok, img} = Vix.Vips.Image.new_from_buffer(bytes, access: :VIPS_ACCESS_RANDOM)
{:ok, s} = O.colourspace(img, :VIPS_INTERPRETATION_sRGB)
{:ok, s} = Vix.Vips.Image.copy_memory(s)
sz = fn i -> case Vix.Vips.Image.header_value(i, "icc-profile-data") do {:ok, b} -> byte_size(b); e -> e end end
r = case System.get_env("V") do
  "pm" -> {:ok, r} = O.premultiply(s); r
  "pmu" -> {:ok, p} = O.premultiply(s); {:ok, r} = O.unpremultiply(p); r
  "gb" -> {:ok, r} = GaussianBlur.blur(s, 2.0); r
  "gb8" -> Enum.reduce(1..8, s, fn l, acc -> {:ok, b} = GaussianBlur.blur(s, l * 1.0); {:ok, a} = O.add(acc, b); a end)
  "apgb" -> {:ok, r} = AlphaPremultiply.with_alpha_premultiplied(s, &GaussianBlur.blur(&1, 2.0)); r
  "gbraw" -> Enum.reduce(1..8, s, fn l, acc -> {:ok, b} = O.gaussblur(s, l * 1.0, precision: :VIPS_PRECISION_FLOAT); {:ok, a} = O.add(acc, b); a end)
  "gbone" -> Enum.reduce(1..8, s, fn l, acc -> {:ok, b} = O.gaussblur(acc, 1.0); b end)
  "synth" ->
    {:ok, icc} = Vix.Vips.Image.header_value(s, "icc-profile-data")
    {:ok, n} = O.black(40, 30, bands: 3)
    {:ok, n} = O.copy(n, interpretation: :VIPS_INTERPRETATION_sRGB)
    {:ok, n} = Vix.Vips.Image.mutate(n, fn m -> Vix.Vips.MutableImage.set(m, "icc-profile-data", :VipsBlob, icc) end)
    Enum.reduce(1..8, n, fn l, acc -> {:ok, b} = O.gaussblur(n, l * 1.0); {:ok, a} = O.add(acc, b); a end)
  "strip" ->
    {:ok, n} = Image.remove_metadata(s, ["icc-profile-data"])
    Enum.reduce(1..8, n, fn _l, acc -> {:ok, b} = O.gaussblur(acc, 1.0); b end)
  "mul" -> Enum.reduce(1..8, s, fn _, acc -> {:ok, a} = O.multiply(acc, s); a end)
  "add20" -> Enum.reduce(1..20, s, fn _, acc -> {:ok, a} = O.add(acc, s); a end)
end
for _ <- 1..5, do: sz.(r)
IO.inspect(sz.(r), label: System.get_env("V"))
