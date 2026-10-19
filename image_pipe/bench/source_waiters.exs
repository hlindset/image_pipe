# How long requests for other sizes of one original wait behind its download.
# mix run --no-compile bench/source_waiters.exs IMAGE MIBPS [ROUNDS]
#
# A loopback origin sends IMAGE at MIBPS. Each round, on a new source URL so
# both caches are cold, a leader requests a 1200 px wide copy and three
# followers request 800, 400, and 200 px copies a quarter of the way into the
# download. SOURCE_WAITERS_INPUT_CACHE=off runs without an originals cache, and
# SOURCE_WAITERS_SAME=on has the followers request the leader's size.
# Prints one JSON line per round, with times in ms from the
# leader's start:
#
#   - downloaded: when the origin sent the last byte to the leader.
#   - released: when each follower got the source lock.
#   - store_wait: released minus downloaded, the wait for the stored original.
#   - behind_leader: each follower's finish minus the leader's. A follower
#     that decoded from the download as it arrived would finish about when
#     the leader does.
defmodule SourceWaitersBench do
  @prefix [:source_waiters_bench]
  @widths [800, 400, 200]

  def run([path, rate | rest]) do
    rate = String.to_integer(rate)
    rounds = String.to_integer(List.first(rest) || "3")
    body = File.read!(path)
    root = Path.join(System.tmp_dir!(), "source-waiters-#{System.unique_integer([:positive])}")
    events = :ets.new(:events, [:public, :bag])
    Vix.Vips.cache_set_max(0)

    :telemetry.attach(
      __MODULE__,
      @prefix ++ [:cache, :coordination],
      fn _, _, meta, _ ->
        :ets.insert(events, {:coordination, self(), meta.result, now()})
      end,
      nil
    )

    {:ok, listener} = :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true])
    {:ok, {_, port}} = :inet.sockname(listener)
    type = MIME.from_path(path)
    origin = spawn_link(fn -> accept(listener, {body, type}, rate, events) end)

    {:ok, _} =
      Supervisor.start_link(
        [
          {ImagePipe,
           [
             name: __MODULE__.Instance,
             telemetry_prefix: @prefix,
             max_body_bytes: 100_000_000,
             max_input_pixels: 60_000_000,
             sources: [
               url: [
                 adapter: ImagePipe.Source.HTTP,
                 match: [scheme: ["http", "https"]],
                 options: [
                   allowed_hosts: ["127.0.0.1:#{port}"],
                   address_policy: [allow_loopback: true],
                   fetch_timeout: 120_000
                 ]
               ]
             ],
             cache: [root: Path.join(root, "output"), max_size_bytes: 10_000_000_000]
           ] ++ input_cache(root)}
        ],
        strategy: :one_for_one
      )

    expected_ms = if rate > 0, do: byte_size(body) * 1000 / (rate * 1024 * 1024), else: 0.0

    try do
      # A warm-up round loads the code paths, and isn't reported.
      for round <- 0..rounds do
        :ets.delete_all_objects(events)
        url = "http://127.0.0.1:#{port}/round-#{System.unique_integer([:positive])}"
        started = now()
        leader = Task.async(fn -> timed(url, 1200) end)
        Process.sleep(round(expected_ms / 4))
        followers = for width <- widths(), do: Task.async(fn -> timed(url, width) end)
        {_leader, leader_end} = Task.await(leader, 300_000)
        results = Enum.map(followers, &Task.await(&1, 300_000))

        if round > 0,
          do: report(path, rate, body, events, started, leader_end, results)
      end
    after
      Process.unlink(origin)
      Process.exit(origin, :kill)
      :gen_tcp.close(listener)
      File.rm_rf!(root)
    end
  end

  defp report(path, rate, body, events, started, leader_end, results) do
    ms = &Float.round((&1 - started) / 1000, 1)
    downloads = for {:downloaded, t} <- :ets.tab2list(events), do: t
    [first_download | _] = Enum.sort(downloads)

    followers =
      for {{pid, finished}, width} <- Enum.zip(results, widths()) do
        {result, released} =
          case for({:coordination, ^pid, result, t} <- :ets.tab2list(events), do: {result, t}) do
            [] -> {:none, nil}
            [{result, t} | _] -> {result, t}
          end

        %{
          width: width,
          coordination: result,
          released: released && ms.(released),
          store_wait: released && Float.round((released - first_download) / 1000, 1),
          finished: ms.(finished),
          behind_leader: Float.round((finished - leader_end) / 1000, 1)
        }
      end

    IO.puts(
      JSON.encode!(%{
        image: Path.basename(path),
        size_kib: div(byte_size(body), 1024),
        rate_mib_s: rate,
        origin_downloads: length(downloads),
        downloaded: ms.(first_download),
        leader_finished: ms.(leader_end),
        followers: followers
      })
    )
  end

  # SOURCE_WAITERS_SAME=on makes the followers request the leader's size.
  defp widths do
    case System.get_env("SOURCE_WAITERS_SAME") do
      "on" -> [1200, 1200, 1200]
      _ -> @widths
    end
  end

  # SOURCE_WAITERS_INPUT_CACHE=off leaves out the originals cache.
  defp input_cache(root) do
    case System.get_env("SOURCE_WAITERS_INPUT_CACHE") do
      "off" -> []
      _ -> [input_cache: [root: Path.join(root, "input"), max_size_bytes: 10_000_000_000]]
    end
  end

  defp timed(url, width) do
    builder =
      ImagePipe.URL.new()
      |> ImagePipe.URL.group(resize: [width: width])
      |> ImagePipe.URL.output(format: :jpeg)

    {:ok, _result} = ImagePipe.run(__MODULE__.Instance, builder, {:source, url})
    {self(), now()}
  end

  defp accept(listener, body, rate, events) do
    {:ok, socket} = :gen_tcp.accept(listener)
    spawn(fn -> serve(socket, body, rate, events) end)
    accept(listener, body, rate, events)
  end

  defp serve(socket, {body, type}, rate, events) do
    {:ok, _request} = :gen_tcp.recv(socket, 0)

    :ok =
      :gen_tcp.send(socket, [
        "HTTP/1.1 200 OK\r\nconnection: close\r\ncache-control: public, max-age=600\r\n",
        "content-type: #{type}\r\ncontent-length: #{byte_size(body)}\r\n\r\n"
      ])

    send_body(socket, body, rate, now(), 0)
    :ets.insert(events, {:downloaded, now()})
    :gen_tcp.close(socket)
  end

  defp send_body(_socket, <<>>, _rate, _started, _sent), do: :ok

  defp send_body(socket, body, rate, started, sent) do
    size = min(byte_size(body), 65_536)
    <<chunk::binary-size(^size), rest::binary>> = body

    if rate > 0 do
      due = started + trunc((sent + size) * 1_000_000 / (rate * 1024 * 1024))
      Process.sleep(max(0, div(due - now(), 1000)))
    end

    case :gen_tcp.send(socket, chunk) do
      :ok -> send_body(socket, rest, rate, started, sent + size)
      {:error, _closed} -> :ok
    end
  end

  defp now, do: System.monotonic_time(:microsecond)
end

SourceWaitersBench.run(System.argv())
