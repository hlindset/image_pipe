Code.require_file("h.exs", __DIR__)
alias Vix.Vips.Operation, as: O
bytes = File.read!(Path.join(__DIR__, "src/cmyk_noicc.jpg"))
{:ok, j} = Image.open(bytes)
{:ok, ref} = O.colourspace(j, :VIPS_INTERPRETATION_sRGB)
IO.inspect(Vix.Vips.Image.header_value(ref, "icc-profile-data") |> then(fn {:ok, b} -> {:icc, byte_size(b), binary_part(b, 12, 8), binary_part(b, 16, 4)}; e -> e end), label: "libvips colourspace output icc")
for g <- System.argv() do
  conn = H.request("/#{g}/src/x", H.opts(bytes, "image/jpeg"))
  {:ok, out} = H.decoded(conn)
  icc = case Vix.Vips.Image.header_value(out, "icc-profile-data") do {:ok, b} -> {byte_size(b), binary_part(b, 16, 4)}; _ -> nil end
  IO.puts("#{g}: #{conn.status} icc=#{inspect(icc)} px=#{inspect(Image.get_pixel!(out, 5, 5))} ref=#{inspect(Image.get_pixel!(ref, 5, 5))}")
end
