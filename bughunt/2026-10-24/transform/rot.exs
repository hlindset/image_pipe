Code.require_file("h.exs", __DIR__)
alias Vix.Vips.Operation, as: O
{w, h} = {2003, 1401}
{:ok, xyz} = O.xyz(w, h)
{:ok, x} = O.extract_band(xyz, 0)
{:ok, y} = O.extract_band(xyz, 1)
{:ok, r} = O.linear(x, [255.0 / w], [0.0])
{:ok, g} = O.linear(y, [255.0 / h], [0.0])
{:ok, b} = O.linear(x, [0.0], [128.0])
{:ok, img} = O.bandjoin([r, g, b])
{:ok, img} = O.cast(img, :VIPS_FORMAT_UCHAR)
{:ok, display} = O.copy(img, interpretation: :VIPS_INTERPRETATION_sRGB)
jpeg = Image.write!(display, :memory, suffix: ".jpg", quality: 100)
png = Image.write!(Image.open!(jpeg, access: :random), :memory, suffix: ".png")
for g <- ["rotate=30/w=100", "rotate=30/w=300", "rotate=90/rotate=30/w=100"] do
path = "/#{g}/format=png/src/x.jpg"
{:ok, a} = H.request(path, H.opts(jpeg, "image/jpeg")) |> H.decoded()
{:ok, b} = H.request(path, H.opts(png)) |> H.decoded()
IO.inspect({g, Image.width(a), Image.height(a), Image.width(b), Image.height(b), Image.bands(a)})
{:ok, d} = O.subtract(a, b)
{:ok, d} = O.abs(d)
{:ok, big} = O.relational_const(d, :VIPS_OPERATION_RELATIONAL_MORE, [20.0])
{:ok, cnt} = O.avg(big)
IO.inspect(cnt * Image.width(a) * Image.height(a) * Image.bands(a) / 255, label: "count >20")
for band <- 0..3 do
  {:ok, db} = O.extract_band(d, band)
  {:ok, {m, info}} = O.max(db)
  IO.inspect({band, m, info.x, info.y, Image.get_pixel!(a, info.x, info.y), Image.get_pixel!(b, info.x, info.y)})
end
end
