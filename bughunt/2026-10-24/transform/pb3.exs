alias Vix.Vips.Operation, as: O
bytes = File.read!(Path.join(__DIR__, "src/cmyka.tif"))
{:ok, img} = Vix.Vips.Image.new_from_buffer(bytes, access: :VIPS_ACCESS_RANDOM)
{:ok, s} = O.colourspace(img, :VIPS_INTERPRETATION_sRGB)
sz = fn i -> case Vix.Vips.Image.header_value(i, "icc-profile-data") do {:ok, b} -> byte_size(b); e -> e end end
IO.inspect(sz.(s), label: "srgb")
case System.get_env("V", "1") do
  "1" ->
    {:ok, x} = O.xyz(Image.width(s), Image.height(s))
    {:ok, x} = O.extract_band(x, 0)
    {:ok, c} = O.relational_const(x, :VIPS_OPERATION_RELATIONAL_MORE, [3.0])
    {:ok, r} = O.ifthenelse(c, s, s)
    IO.inspect(sz.(r), label: "ifthenelse")
  "2" ->
    {:ok, r} = O.multiply(s, s)
    IO.inspect(sz.(r), label: "multiply")
  "3" ->
    {:ok, r} = O.linear(s, [1.0], [0.0])
    for _ <- 1..20, do: sz.(r)
    IO.inspect(sz.(r), label: "linear")
  "4" ->
    for _ <- 1..50, do: sz.(s)
    IO.inspect(sz.(s), label: "repeat")
end
