seg = "/wm-src64=AAA" <> String.duplicate("/AAAA", 64)
p = String.duplicate(seg, 30) <> "/src/x.jpg"
IO.inspect byte_size(p)
ImagePipe.Telemetry.request_path(p, "")
{t, _} = :timer.tc(fn -> for _ <- 1..10, do: ImagePipe.Telemetry.request_path(p, "") end)
IO.puts "per call ms: #{t / 10_000}"
