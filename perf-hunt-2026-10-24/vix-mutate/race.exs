# The ETS table isn't started (--no-start), so every call runs the full check.
Vix.Vips.cache_set_max(0)
srgb = File.read!("priv/icc/sRGB.icc")
p3 = File.read!("priv/icc/DisplayP3.icc")
IO.inspect({ImagePipe.SrgbProfile.equivalent?(srgb), ImagePipe.SrgbProfile.equivalent?(p3)}, label: "serial (sRGB, P3)")

for round <- 1..5 do
  results =
    1..2000
    |> Task.async_stream(fn i -> if rem(i, 2) == 0, do: {:srgb, ImagePipe.SrgbProfile.equivalent?(srgb)}, else: {:p3, ImagePipe.SrgbProfile.equivalent?(p3)} end,
      max_concurrency: 16, timeout: :infinity)
    |> Enum.map(fn {:ok, r} -> r end)
    |> Enum.frequencies()
  IO.inspect(results, label: "concurrent round #{round}")
end
