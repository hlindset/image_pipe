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

geoms =
  System.get_env("GEOMS", "") |> String.split(";", trim: true) |> case do
    [] ->
      [
        "w=100",
        "crop=1000,700/w=100",
        "crop=1000,700/anchor=top-left/w=100",
        "crop=1000,700/anchor=bottom-right/w=100",
        "crop=1000,700/anchor=right/anchor-offset=100,50/w=100",
        "crop=1000,700/anchor=top-left/anchor-offset=100,50/w=100",
        "crop=1000,700/focus=0.2,0.8/w=100",
        "crop=1000,700/focus=0.9,0.1/anchor-offset=30,40/w=100",
        "crop=1000,700/anchor=left/anchor-offset=10pct,5pct/w=100",
        "region=100,200,800,600/w=100",
        "region=1500,1000,800,600/w=100",
        "w=100/h=100/fit=cover",
        "w=100/h=100/fit=cover/anchor=top-left",
        "w=100/h=100/fit=cover/anchor=right/anchor-offset=5,0",
        "w=100/h=100/fit=cover/focus=0.9,0.5",
        "w=100/h=100/fit=cover/anchor=left/anchor-offset=10pct,0",
        "crop=50pct,50pct/anchor=bottom-left/w=100/h=100/fit=cover/anchor=top-right",
        "crop=100pct,100pct/crop-ratio=1:1/anchor=left/w=100",
        "rotate=90/crop=1000,700/anchor=top-left/w=100",
        "flip=h/crop=1000,700/anchor=top-left/w=100",
        "rotate=30/crop=1000,700/anchor=top-left/w=100",
        "rotate=30/w=100",
        "crop=1000,700/anchor=top-left/w=100/-/crop=50,50/anchor=bottom-right",
        "w=100/h=100/fit=stretch",
        "w=100/h=50/fit=stretch/crop=500,700/anchor=right",
        "w=100/dpr=2",
        "w=100/h=100/fit=cover/dpr=2/anchor=bottom-right/anchor-offset=3,3"
      ]
    l -> l
  end

jpeg = Image.write!(display, :memory, suffix: ".jpg", quality: 100)
ref_pixels = Image.open!(jpeg, access: :random)
png = Image.write!(ref_pixels, :memory, suffix: ".png")

orients = System.get_env("ORIENTS", "1") |> String.split(",") |> Enum.map(&String.to_integer/1)

for n <- orients do
  # stored jpeg tagged n whose autorotated display equals the decoded jpeg pixels approx
  stored = H.stored_for(ref_pixels, n)
  sj = stored |> Image.set_orientation!(n) |> Image.write!(:memory, suffix: ".jpg", quality: 100)

  for g <- geoms do
    path = "/#{g}/format=png/src/x.jpg"
    a = H.request(path, H.opts(sj, "image/jpeg")) |> H.decoded()
    b = H.request(path, H.opts(png)) |> H.decoded()

    case {a, b} do
      {{:ok, a}, {:ok, b}} ->
        if {Image.width(a), Image.height(a)} != {Image.width(b), Image.height(b)} do
          IO.puts("DIM n=#{n} #{g}: #{Image.width(a)}x#{Image.height(a)} vs #{Image.width(b)}x#{Image.height(b)}")
        else
          {:ok, a3} = O.extract_band(a, 0, n: 2)
          {:ok, b3} = O.extract_band(b, 0, n: 2)
          {:ok, d} = O.subtract(a3, b3)
          {:ok, ra} = O.extract_band(d, 0)
          {:ok, ga} = O.extract_band(d, 1)
          {:ok, mr} = O.avg(ra)
          {:ok, mg} = O.avg(ga)
          m = H.maxdiff(a3, b3)
          if m > 3 or abs(mr) > 0.7 or abs(mg) > 0.7,
            do: IO.puts("PIX n=#{n} #{g}: max #{m} meanR #{Float.round(mr, 2)} meanG #{Float.round(mg, 2)}")
        end

      other ->
        IO.puts("ERR n=#{n} #{g}: #{inspect(other, limit: 5) |> String.slice(0, 300)}")
    end
  end
end

IO.puts("done")
