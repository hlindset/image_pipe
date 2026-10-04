# Run from image_pipe/:
# mise exec -- mix run bench/source_fetch.exs [CONCURRENCY]
#
# Times small pinned HTTP fetches through ImagePipe.Source.ReqStream against a
# local Bandit origin, so per-fetch client overhead dominates.
defmodule SourceFetchBench do
  @fetches 4_000

  defmodule Origin do
    def init(opts), do: opts
    def call(conn, _opts), do: Plug.Conn.send_resp(conn, 200, "small body")
  end

  def run(concurrency) do
    {:ok, bandit} = Bandit.start_link(plug: Origin, port: 0, ip: :loopback, startup_log: false)
    {:ok, {_ip, port}} = ThousandIsland.listener_info(bandit)
    url = "http://localhost:#{port}/image"
    runtime = [validate_target: fn _url -> {:ok, [{127, 0, 0, 1}]} end]
    fetch = fn -> drain(ImagePipe.Source.ReqStream.open([url: url], runtime)) end
    Enum.each(1..100, fn _ -> fetch.() end)

    {elapsed, _} =
      :timer.tc(fn ->
        1..concurrency
        |> Task.async_stream(
          fn _ -> Enum.each(1..div(@fetches, concurrency), fn _ -> fetch.() end) end,
          timeout: :infinity
        )
        |> Stream.run()
      end)

    IO.puts(
      JSON.encode!(%{
        concurrency: concurrency,
        fetches: @fetches,
        total_ms: elapsed / 1_000,
        us_per_fetch: elapsed / @fetches
      })
    )
  end

  defp drain({:ok, response}), do: Enum.each(response.stream, fn _ -> :ok end)
end

concurrency = System.argv() |> List.first("1") |> String.to_integer()
SourceFetchBench.run(concurrency)
