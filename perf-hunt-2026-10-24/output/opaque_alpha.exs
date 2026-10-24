alias Vix.Vips.Image, as: V
alias Vix.Vips.Operation, as: Op
alias ImagePipe.Output.Ssim2Metric

med = fn l -> Enum.at(Enum.sort(l), div(length(l), 2)) / 1000 end

prep = fn path, width ->
  {:ok, img} = Image.open(path)
  {:ok, img} = Image.thumbnail(img, width)
  {:ok, img} = V.copy_memory(img)
  img
end

for {label, path, w} <- [{"dog", "priv/static/images/dog.jpg", 1600}, {"screenshot", "docs/assets/demo-fiddle-desktop.png", 1440}] do
  rgb = prep.(path, w)
  {:ok, rgba} = Op.bandjoin_const(rgb, [255.0])
  {:ok, rgba} = V.copy_memory(rgba)

  {us, {:ok, {min, _}}} = :timer.tc(fn -> Op.min(elem(Op.extract_band(rgba, 3), 1)) end)
  IO.puts("\n## #{label} #{V.width(rgb)}x#{V.height(rgb)}  (alpha min=#{min}, detect #{us / 1000} ms)")

  for {fmt, s} <- [
        {"avif q56 e3 444", ".avif[Q=56,effort=3,subsample-mode=off,keep=icc]"},
        {"webp q79 e4", ".webp[Q=79,effort=4,keep=icc]"},
        {"png default", ".png[keep=icc]"},
        {"jpeg q80", ".jpg[Q=80,keep=icc]"}
      ],
      fmt != "jpeg q80" do
    {:ok, _} = V.write_to_buffer(rgb, s)
    {:ok, _} = V.write_to_buffer(rgba, s)

    res =
      for _ <- 1..5, {n, img} <- Enum.shuffle([{:rgb, rgb}, {:rgba, rgba}]), reduce: %{} do
        acc ->
          {us, {:ok, b}} = :timer.tc(fn -> V.write_to_buffer(img, s) end)
          Map.update(acc, n, {[us], byte_size(b)}, fn {l, bb} -> {[us | l], bb} end)
      end

    {lr, br} = res.rgb
    {la, ba} = res.rgba
    IO.puts(:io_lib.format("~-18s rgb ~7.1f ms ~8B B | rgba(opaque) ~7.1f ms ~8B B | time x~4.2f bytes x~5.3f", [fmt, med.(lr), br, med.(la), ba, med.(la) / med.(lr), ba / br]))
  end

  # metric: reference + one compare, rgb vs opaque rgba
  {:ok, cand} = V.write_to_buffer(rgb, ".jpg[Q=70]")
  {:ok, cand} = Image.from_binary(cand)

  res =
    for _ <- 1..5, {n, img} <- Enum.shuffle([{:rgb, rgb}, {:rgba, rgba}]), reduce: %{} do
      acc ->
        {us_ref, {:ok, ref}} = :timer.tc(fn -> Ssim2Metric.reference(img) end)
        {us_cmp, {:ok, score}} = :timer.tc(fn -> Ssim2Metric.score(ref, cand) end)
        Map.update(acc, n, {[us_ref], [us_cmp], score}, fn {a, b, s} -> {[us_ref | a], [us_cmp | b], s} end)
    end

  for n <- [:rgb, :rgba] do
    {a, b, s} = res[n]
    IO.puts(:io_lib.format("ssim2 ~-5s reference ~7.1f ms, compare ~7.1f ms, score ~.3f", [n, med.(a), med.(b), s]))
  end
end
