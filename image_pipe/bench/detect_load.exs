# Run from image_pipe/, against a running server:
# mise exec -- mix run bench/detect_load.exs URL [CONCURRENCY] [REQUESTS]
#
# Sends REQUESTS GETs to URL from CONCURRENCY workers and prints latency
# percentiles, throughput and the response body's SHA-256. Used to compare
# detector scheduling in two vision images under the same CPU limit; point it
# at a request that runs detection and is not served from a cache.
defmodule DetectLoadBench do
  def run(url, concurrency, requests) do
    get = fn -> Req.get!(url, retry: false, receive_timeout: 120_000) end
    %{status: 200, body: body} = get.()
    Enum.each(1..3, fn _ -> get.() end)

    {elapsed, latencies} =
      :timer.tc(fn ->
        1..requests
        |> Task.async_stream(fn _ -> timed(get) end,
          max_concurrency: concurrency,
          timeout: :infinity
        )
        |> Enum.map(fn {:ok, ms} -> ms end)
      end)

    sorted = Enum.sort(latencies)

    IO.puts(
      JSON.encode!(%{
        concurrency: concurrency,
        requests: requests,
        p50_ms: percentile(sorted, 0.50),
        p95_ms: percentile(sorted, 0.95),
        max_ms: List.last(sorted),
        requests_per_s: Float.round(requests / (elapsed / 1_000_000), 2),
        body_sha256: :crypto.hash(:sha256, body) |> Base.encode16(case: :lower)
      })
    )
  end

  defp timed(get) do
    {us, %{status: 200}} = :timer.tc(get)
    Float.round(us / 1_000, 1)
  end

  defp percentile(sorted, p), do: Enum.at(sorted, round(p * (length(sorted) - 1)))
end

[url | rest] = System.argv()
concurrency = rest |> Enum.at(0, "1") |> String.to_integer()
requests = rest |> Enum.at(1, "50") |> String.to_integer()
DetectLoadBench.run(url, concurrency, requests)
