Logger.configure(level: :error)
{:ok, _} = ImagePipe.ProcessingPool.start_link(name: P, max_concurrency: 4, max_queue: 4096)

bench = fn label, config ->
  n = 20_000
  {us, _} =
    :timer.tc(fn ->
      1..n
      |> Task.async_stream(
        fn _ -> ImagePipe.ProcessingPool.within(P, self(), config, fn -> :ok end) end,
        max_concurrency: 64,
        ordered: false
      )
      |> Stream.run()
    end)

  {:message_queue_len, q} = Process.info(Process.whereis(P), :message_queue_len)
  IO.puts("#{label}: #{Float.round(n / (us / 1.0e6))} turns/s, #{Float.round(us / n, 1)} us/turn, final mq #{q}")
end

bench.("no handlers", [])
bench.("no handlers", [])
ImagePipe.Telemetry.attach_default_logger(level: :info)
bench.("default logger (level error filters output)", [])
bench.("default logger (level error filters output)", [])
