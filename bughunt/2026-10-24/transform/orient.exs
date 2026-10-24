Code.require_file("h.exs", __DIR__)

display = H.noise(37, 53)
twin_bytes = Image.write!(display, :memory, suffix: ".png")

geoms =
  [
    "crop=20,30",
    "crop=21,30/anchor=top-left",
    "crop=20,31/anchor=bottom-right",
    "crop=20,30/anchor=top",
    "crop=20,30/anchor=right",
    "crop=20,30/anchor=left/anchor-offset=3,5",
    "crop=20,30/anchor=bottom-right/anchor-offset=3,5",
    "crop=20,30/anchor=center/anchor-offset=3,-5",
    "crop=20,30/anchor=top/anchor-offset=10pct,5pct",
    "crop=20,30/focus=0.3,0.7",
    "crop=19,29/focus=0.5,0.5",
    "crop=20,30/focus=0.1,0.9/anchor-offset=2,3",
    "crop=100pct,100pct/crop-ratio=16:9",
    "crop=50pct,50pct/crop-ratio=3:4/anchor=bottom-left",
    "region=3,4,20,30",
    "region=30,40,20,30",
    "w=20/h=20/fit=cover/kernel=nearest",
    "w=20/h=20/fit=cover/anchor=top-left/kernel=nearest",
    "w=20/h=20/fit=cover/anchor=bottom/anchor-offset=0,2/kernel=nearest",
    "w=20/h=20/fit=cover/focus=0.2,0.8/kernel=nearest",
    "w=20/h=20/fit=cover/anchor=right/anchor-offset=2,0/kernel=nearest",
    "w=20/h=20/fit=cover",
    "w=20/h=20/fit=cover/anchor=top-left",
    "w=20/h=20/fit=cover/anchor=bottom/anchor-offset=0,2",
    "w=20/h=20/fit=cover/focus=0.2,0.8",
    "w=20/h=20/fit=cover/anchor=right/anchor-offset=2,0/dpr=2",
    "w=20/h=20/fit=cover/anchor=left/anchor-offset=2,1",
    "crop=30,40/anchor=top-left/w=10",
    "rotate=90/crop=20,30/anchor=top-left",
    "rotate=90/flip=h/crop=20,30/anchor=bottom/anchor-offset=1,2",
    "flip=v/crop=20,30/anchor=left/anchor-offset=1,2",
    "flip=hv/crop=20,30/focus=0.3,0.2",
    "rotate=270/flip=v/w=20/h=20/fit=cover/anchor=top-right",
    "trim=auto/crop=20,30",
    "crop=20,30/anchor=top-left/-/crop=10,10/anchor=bottom-right",
    "rotate=90/-/crop=20,30/anchor=top-left",
    "pad=1,2,3,4/w=20",
    "w=20/h=20/extend",
    "pixelate=4",
    "rotate=45/crop=20,30/anchor=top-left"
  ]

for n <- 1..8 do
  stored = H.stored_for(display, n)
  bytes = stored |> Image.set_orientation!(n) |> Image.write!(:memory, suffix: ".png")

  for g <- geoms do
    path = "/#{g}/format=png/src/x.png"
    a = H.request(path, H.opts(bytes)) |> H.decoded()
    b = H.request(path, H.opts(twin_bytes)) |> H.decoded()

    case {a, b} do
      {{:ok, a}, {:ok, b}} ->
        if Image.width(a) != Image.width(b) or Image.height(a) != Image.height(b) do
          IO.puts("DIM n=#{n} #{g}: #{Image.width(a)}x#{Image.height(a)} vs #{Image.width(b)}x#{Image.height(b)}")
        else
          m = H.maxdiff(a, b)
          if m > 1, do: IO.puts("PIX n=#{n} #{g}: maxdiff #{m}")
        end

      other ->
        IO.puts("ERR n=#{n} #{g}: #{inspect(other, limit: 5)}")
    end
  end
end

IO.puts("done")
