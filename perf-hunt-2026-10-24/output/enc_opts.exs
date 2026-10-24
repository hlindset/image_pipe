{:ok, _} = Vix.Vips.Image.new_from_file("docs/assets/demo-fiddle-desktop.png"); File.read!("/proc/self/maps") |> String.split("\n") |> Enum.filter(&String.contains?(&1, "libz.so")) |> Enum.take(1) |> IO.inspect()
alias Vix.Vips.Image, as: V
alias Vix.Vips.Operation, as: Op

defmodule B do
  # interleaved A/B: run each variant once per round, rounds times; report median ms + bytes
  def run(img, variants, rounds \\ 7) do
    # warm
    Enum.each(variants, fn {_n, s} -> {:ok, _} = V.write_to_buffer(img, s) end)

    samples =
      for _ <- 1..rounds, {name, s} <- Enum.shuffle(variants), reduce: %{} do
        acc ->
          {us, {:ok, bin}} = :timer.tc(fn -> V.write_to_buffer(img, s) end)
          Map.update(acc, name, {[us], byte_size(bin)}, fn {l, b} -> {[us | l], b} end)
      end

    for {name, _} <- variants do
      {l, b} = samples[name]
      med = Enum.at(Enum.sort(l), div(length(l), 2)) / 1000
      {name, med, b}
    end
  end

  def print(label, rows) do
    {_, base_ms, base_b} = hd(rows)
    IO.puts("\n## #{label}")

    for {n, ms, b} <- rows do
      IO.puts(
        :io_lib.format("~-40s ~8.1f ms (~5.2fx)  ~9B bytes (~6.3fx)", [
          n,
          ms,
          ms / base_ms,
          b,
          b / base_b
        ])
      )
    end
  end
end

prep = fn path, width ->
  {:ok, img} = Image.open(path)
  {:ok, img} = Image.thumbnail(img, width)
  {:ok, img} = V.copy_memory(img)
  img
end

ui = fn ->
  img = Image.new!(1440, 900, color: [250, 250, 252])
  img = Image.Draw.rect!(img, 0, 0, 1440, 64, color: [32, 41, 64])
  img = Image.Draw.rect!(img, 0, 64, 240, 836, color: [236, 239, 244])
  img =
    Enum.reduce(0..11, img, fn i, acc ->
      acc
      |> Image.Draw.rect!(280 + rem(i, 4) * 280, 100 + div(i, 4) * 250, 250, 220, color: [255, 255, 255])
      |> Image.Draw.rect!(300 + rem(i, 4) * 280, 120 + div(i, 4) * 250, 120, 14, color: [60, 60, 70])
      |> Image.Draw.rect!(300 + rem(i, 4) * 280, 150 + div(i, 4) * 250, 200, 8, color: [150, 150, 160])
      |> Image.Draw.circle!(470 + rem(i, 4) * 280, 260 + div(i, 4) * 250, 30, color: [30 + i * 15, 120, 220 - i * 10])
    end)
  photo = prep.("priv/static/images/flower.jpg", 300)
  img = Image.compose!(img, photo, x: 20, y: 500)
  {:ok, img} = Image.resize(img, 0.999)
  {:ok, img} = Image.flatten(img)
  {:ok, img} = V.copy_memory(img)
  img
end

inputs = [
  {"synthetic UI 1440", ui.()},
  {"dog 1600", prep.("priv/static/images/dog.jpg", 1600)},
  {"mountain 1600", prep.("priv/static/images/mountain.jpg", 1600)},
  {"waterfall 800", prep.("priv/static/images/waterfall.jpg", 800)},
  {"screenshot 1440", prep.("docs/assets/demo-fiddle-desktop.png", 1440)},
  {"cooking(rgba) 1600", prep.("priv/static/images/cooking.png", 1600)}
]

mode = System.argv() |> List.first() || "all"

for {label, img} <- inputs do
  flat =
    if V.has_alpha?(img),
      do: elem(Op.flatten(img, background: [255.0, 255.0, 255.0]), 1) |> then(&elem(V.copy_memory(Op.cast!(&1, :VIPS_FORMAT_UCHAR)), 1)),
      else: img

  if mode in ["all", "jpeg"] do
    B.print("JPEG Q80 #{label}", B.run(flat, [
      {"default (libvips)", ".jpg[Q=80,keep=icc]"},
      {"optimize-coding", ".jpg[Q=80,keep=icc,optimize-coding=true]"},
      {"interlace (progressive)", ".jpg[Q=80,keep=icc,interlace=true]"},
      {"trellis+optimize", ".jpg[Q=80,keep=icc,optimize-coding=true,trellis-quant=true]"}
    ]))
  end

  if mode in ["all", "png"] do
    B.print("PNG #{label}", B.run(img, [
      {"default (c6, filter none)", ".png[keep=icc]"},
      {"c6 filter all", ".png[keep=icc,filter=all]"},
      {"c6 filter sub", ".png[keep=icc,filter=sub]"},
      {"c6 filter paeth", ".png[keep=icc,filter=paeth]"},
      {"c3 filter none", ".png[keep=icc,compression=3]"},
      {"c3 filter all", ".png[keep=icc,compression=3,filter=all]"},
      {"c9 filter none", ".png[keep=icc,compression=9]"},
      {"c1 filter none", ".png[keep=icc,compression=1]"}
    ], 3))
  end

  if mode in ["all", "palette"] do
    B.print("PNG palette #{label}", B.run(img, [
      {"palette default (effort 7)", ".png[keep=icc,palette=true]"},
      {"palette effort 4", ".png[keep=icc,palette=true,effort=4]"},
      {"palette effort 1", ".png[keep=icc,palette=true,effort=1]"},
      {"palette effort 10", ".png[keep=icc,palette=true,effort=10]"}
    ], 3))
  end

  if mode in ["all", "webp"] do
    B.print("WebP Q79 #{label}", B.run(img, [
      {"default (effort 4)", ".webp[Q=79,keep=icc,effort=4]"},
      {"smart-subsample", ".webp[Q=79,keep=icc,effort=4,smart-subsample=true]"},
      {"effort 3", ".webp[Q=79,keep=icc,effort=3]"}
    ], 5))
  end
end
