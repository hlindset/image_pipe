alias Vix.Vips.Image, as: V
alias Vix.Vips.Operation, as: Op

med = fn l -> Enum.at(Enum.sort(l), div(length(l), 2)) / 1000 end

# Lazy upstream: sequential open with shrink-on-load + resize, like the executor.
build = fn path, width ->
  {:ok, img} = Op.thumbnail(path, width)
  img
end

cases = [
  {"dog.jpg -> 1600", "priv/static/images/dog.jpg", 1600},
  {"waterfall.jpg -> 3000", "priv/static/images/waterfall.jpg", 3000},
  {"mountain.jpg -> 800", "priv/static/images/mountain.jpg", 800},
  {"cooking.png -> 1600", "priv/static/images/cooking.png", 1600}
]

fmts = [
  {"jpeg q80", ".jpg[Q=80,keep=icc]"},
  {"webp q79", ".webp[Q=79,effort=4,keep=icc]"},
  {"avif q56", ".avif[Q=56,effort=3,subsample-mode=off,keep=icc]"}
]

stream_all = fn img, s ->
  img |> V.write_to_stream(s) |> Enum.reduce(0, fn c, acc -> acc + byte_size(c) end)
end

for {label, path, w} <- cases, {fl, s} <- fmts do
  variants = [
    {:copy_then_stream, fn -> {:ok, m} = V.copy_memory(build.(path, w)); stream_all.(m, s) end},
    {:lazy_stream, fn -> stream_all.(build.(path, w), s) end}
  ]

  Enum.each(variants, fn {_, f} -> f.() end)

  res =
    for _ <- 1..7, {n, f} <- Enum.shuffle(variants), reduce: %{} do
      acc ->
        {us, bytes} = :timer.tc(f)
        Map.update(acc, n, {[us], bytes}, fn {l, b} -> {[us | l], b} end)
    end

  {lc, bc} = res.copy_then_stream
  {ll, bl} = res.lazy_stream

  IO.puts(:io_lib.format("~-24s ~-9s copy+stream ~7.1f ms | lazy stream ~7.1f ms | lazy/copy ~4.2f | bytes equal: ~p", [label, fl, med.(lc), med.(ll), med.(ll) / med.(lc), bc == bl]))
end
