alias Vix.Vips.Image, as: V
alias Vix.Vips.Operation, as: Op

med = fn l -> Enum.at(Enum.sort(l), div(length(l), 2)) / 1000 end

cpu = fn ->
  [_, rest] = File.read!("/proc/self/stat") |> String.split(") ", parts: 2)
  f = String.split(rest, " ")
  (String.to_integer(Enum.at(f, 11)) + String.to_integer(Enum.at(f, 12))) * 10
end

# 1. JPEG from RGBA: float flatten (encoder.ex) vs direct uchar flatten
{:ok, rgba} = Op.thumbnail("priv/static/images/cooking.png", 1600)
{:ok, rgba} = V.copy_memory(rgba)

float_flat = fn ->
  {:ok, f} = Op.cast(rgba, :VIPS_FORMAT_FLOAT)
  {:ok, fl} = Op.flatten(f, background: [255.0, 255.0, 255.0])
  {:ok, r} = Op.round(fl, :VIPS_OPERATION_ROUND_RINT)
  {:ok, c} = Op.cast(r, :VIPS_FORMAT_UCHAR)
  {:ok, b} = V.write_to_buffer(c, ".jpg[Q=80]")
  b
end

direct = fn ->
  {:ok, fl} = Op.flatten(rgba, background: [255.0, 255.0, 255.0])
  {:ok, b} = V.write_to_buffer(fl, ".jpg[Q=80]")
  b
end

vs = [float: float_flat, direct: direct]
Enum.each(vs, fn {_, f} -> f.() end)

r =
  for _ <- 1..9, {n, f} <- Enum.shuffle(vs), reduce: %{} do
    acc ->
      {us, _} = :timer.tc(f)
      Map.update(acc, n, [us], &[us | &1])
  end

IO.puts("RGBA->JPEG 1600: float flatten #{med.(r.float)} ms, direct flatten #{med.(r.direct)} ms, same bytes? #{float_flat.() == direct.()}")

# 2. AVIF encode: wall vs CPU (threading)
{:ok, big} = Op.thumbnail("priv/static/images/waterfall.jpg", 3000, height: 100_000)
{:ok, big} = V.copy_memory(big)

for s <- [".avif[Q=56,effort=3,subsample-mode=off]", ".webp[Q=79,effort=4]"] do
  c0 = cpu.()
  {us, {:ok, _}} = :timer.tc(fn -> V.write_to_buffer(big, s) end)
  IO.puts("#{s} 3000x4500: wall #{us / 1000} ms cpu #{cpu.() - c0} ms")
end
