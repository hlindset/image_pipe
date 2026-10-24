Code.require_file(Path.join(__DIR__, "harness.exs"))
Logger.configure(level: :error)
%{mount: mount} = H.setup()
path = "/w=300/format=webp/src/image.jpg"
%{status: 200} = r = H.call(mount, :get, path)
etag = r |> Plug.Conn.get_resp_header("etag") |> hd()
f304 = fn -> %{status: 304} = H.call(mount, :get, path, [{"if-none-match", etag}]) end

bench = fn name, f, n ->
  Enum.each(1..300, fn _ -> f.() end)
  {t, _} = :timer.tc(fn -> Enum.each(1..n, fn _ -> f.() end) end)
  {:reductions, r0} = Process.info(self(), :reductions)
  Enum.each(1..n, fn _ -> f.() end)
  {:reductions, r1} = Process.info(self(), :reductions)
  IO.puts("#{String.pad_trailing(name, 50)} #{Float.round(t / n, 2)} us  #{div(r1 - r0, n)} red")
end

handler = fn _e, _m, _md, _c -> :ok end

attach_n = fn from, to ->
  for i <- from..to do
    :telemetry.attach("other-#{i}", [:other_lib, :"ev#{rem(i, 50)}", :stop], handler, nil)
  end
end

IO.puts("handlers: #{length(:telemetry.list_handlers([]))}")
bench.("list_handlers([:image_pipe,:request,:summary])", fn -> :telemetry.list_handlers([:image_pipe, :request, :summary]) end, 20000)
bench.("304 request", f304, 2000)
attach_n.(1, 200)
IO.puts("handlers: #{length(:telemetry.list_handlers([]))}")
bench.("list_handlers (200 foreign)", fn -> :telemetry.list_handlers([:image_pipe, :request, :summary]) end, 20000)
bench.("304 request", f304, 2000)
attach_n.(201, 1000)
IO.puts("handlers: #{length(:telemetry.list_handlers([]))}")
bench.("list_handlers (1000 foreign)", fn -> :telemetry.list_handlers([:image_pipe, :request, :summary]) end, 20000)
bench.("304 request", f304, 2000)
ImagePipe.Telemetry.attach_default_logger(level: :debug)
Logger.configure(level: :error)
IO.puts("handlers after default logger: #{length(:telemetry.list_handlers([]))}")
bench.("304 request (+default logger, logger level error)", f304, 2000)
