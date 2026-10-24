alias Vix.Vips.Image, as: V
alias Vix.Vips.Operation, as: Op
alias ImagePipe.Output.Ssim2Metric

med = fn l -> Enum.at(Enum.sort(l), div(length(l), 2)) / 1000 end

for {path, w} <- [{"priv/static/images/dog.jpg", 1200}, {"priv/static/images/mountain.jpg", 2400}] do
  {:ok, img} = Op.thumbnail(path, w, height: 100_000)
  {:ok, img} = V.copy_memory(img)

  for {fl, s} <- [{"jpeg", ".jpg[Q=76,keep=icc]"}, {"webp", ".webp[Q=78,effort=4,keep=icc]"}, {"avif", ".avif[Q=53,effort=3,subsample-mode=off,keep=icc]"}] do
    serial = fn ->
      {:ok, _ref} = Ssim2Metric.reference(img)
      {:ok, _b} = V.write_to_buffer(img, s)
    end

    overlap = fn ->
      t = Task.async(fn -> Ssim2Metric.reference(img) end)
      {:ok, _b} = V.write_to_buffer(img, s)
      {:ok, _ref} = Task.await(t, :infinity)
    end

    vs = [serial: serial, overlap: overlap]
    Enum.each(vs, fn {_, f} -> f.() end)

    r =
      for _ <- 1..7, {n, f} <- Enum.shuffle(vs), reduce: %{} do
        acc ->
          {us, _} = :timer.tc(f)
          Map.update(acc, n, [us], &[us | &1])
      end

    IO.puts("#{Path.basename(path)} #{V.width(img)}x#{V.height(img)} #{fl}: serial #{med.(r.serial)} ms, overlapped #{med.(r.overlap)} ms")
  end
end
