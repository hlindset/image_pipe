Code.require_file(Path.join(__DIR__, "harness.exs"))
Logger.configure(level: :error)
%{mount: mount} = H.setup()
path = "/w=300/format=webp/src/image.jpg"
%{status: 200} = H.call(mount, :get, path)

config = ImagePipe.Plug.Config.resolve(mount)
IO.puts("config keys: #{length(config)} #{inspect(Keyword.keys(config))}")
IO.puts("config term size words: #{:erts_debug.size(config)} flat: #{:erts_debug.flat_size(config)}")

bench = fn name, f, n ->
  Enum.each(1..1000, fn _ -> f.() end)
  {t, _} = :timer.tc(fn -> Enum.each(1..n, fn _ -> f.() end) end)
  {:reductions, r0} = Process.info(self(), :reductions)
  Enum.each(1..n, fn _ -> f.() end)
  {:reductions, r1} = Process.info(self(), :reductions)
  IO.puts("#{String.pad_trailing(name, 40)} #{Float.round(t / n, 3)} us  #{div(r1 - r0, n)} red")
end

for _ <- 1..2 do
  bench.("Config.resolve", fn -> ImagePipe.Plug.Config.resolve(mount) end, 20_000)
  bench.("Source.runtime_opts", fn -> ImagePipe.Source.runtime_opts(config) end, 50_000)
  bench.("Telemetry.span (no handlers)", fn -> ImagePipe.Telemetry.span(config, [:x], %{a: 1}, fn -> {:ok, %{b: 2}} end) end, 50_000)
  bench.("Keyword.get last key", fn -> Keyword.get(config, :zzz) end, 50_000)
end
