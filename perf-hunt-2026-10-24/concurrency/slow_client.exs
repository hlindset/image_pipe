# MIX_ENV=test mix run <this>
# Slow clients vs pool turns and coalesced waiters. A/B: :ip_prefetch flag.
defmodule SlowClient do
  @images Path.expand("priv/static/images")

  def start do
    root = Path.join(System.tmp_dir!(), "slowcli-#{System.unique_integer([:positive])}")
    name = SlowClient.Images
    encodes = :counters.new(1, [:atomics])

    :telemetry.attach(
      :enc,
      [:slowcli, :encode, :stop],
      fn _e, _m, _meta, c -> :counters.add(c, 1, 1) end,
      encodes
    )

    {:ok, _} =
      Supervisor.start_link(
        [
          {ImagePipe,
           name: name,
           allow_unsigned: true,
           telemetry_prefix: [:slowcli],
           max_body_bytes: 200_000_000,
           max_input_pixels: 200_000_000,
           sources: [
             media: [
               adapter: ImagePipe.Source.File,
               match: :path,
               options: [root: @images, root_id: "media"]
             ]
           ],
           cache: [root: root, max_size_bytes: 2_000_000_000],
           pool: [max_concurrency: 2]}
        ],
        strategy: :one_for_one
      )

    {:ok, sup} =
      Supervisor.start_link([{Bandit, plug: {ImagePipe.Plug, instance: name}, ip: {127, 0, 0, 1}, port: 0}],
        strategy: :one_for_one
      )

    [{_, server, _, _}] = Supervisor.which_children(sup)
    {:ok, {_, port}} = ThousandIsland.listener_info(server)
    %{port: port, encodes: encodes, pool: Module.concat(name, ImagePipe.ProcessingPool)}
  end

  # rate: bytes per tick (50 ms); :fast reads everything at once.
  def get(port, path, rate) do
    t0 = System.monotonic_time(:millisecond)
    opts = [:binary, active: false, packet: :raw] ++ if(rate == :fast, do: [], else: [recbuf: 32_768])
    {:ok, s} = :gen_tcp.connect({127, 0, 0, 1}, port, opts)
    :ok = :gen_tcp.send(s, "GET #{path} HTTP/1.1\r\nhost: x\r\nconnection: close\r\n\r\n")
    {first, bytes} = read(s, rate, nil, 0, t0)
    :gen_tcp.close(s)
    %{ms: System.monotonic_time(:millisecond) - t0, ttfb: first, bytes: bytes}
  end

  defp read(s, rate, first, n, t0) do
    len = if rate == :fast, do: 0, else: rate

    case :gen_tcp.recv(s, len, 60_000) do
      {:ok, data} ->
        first = first || System.monotonic_time(:millisecond) - t0
        if rate != :fast, do: Process.sleep(50)
        read(s, rate, first, n + byte_size(data), t0)

      {:error, :closed} ->
        {first, n}
    end
  end

  def sample(pool, stop_at, acc \\ []) do
    if System.monotonic_time(:millisecond) >= stop_at do
      Enum.reverse(acc)
    else
      st = ImagePipe.ProcessingPool.stats(pool)
      Process.sleep(100)
      sample(pool, stop_at, [st.active | acc])
    end
  end

  def scenario_a(ctx, prefetch, run) do
    :persistent_term.put(:ip_prefetch, prefetch)
    # two slow clients for distinct big PNGs, 32 KB / 50 ms = 640 KB/s
    slow =
      for img <- ["dog_2.jpg", "waterfall.jpg"] do
        Task.async(fn -> get(ctx.port, "/w=#{3000 + run}/format=png/src/#{img}", 32_768) end)
      end

    Process.sleep(2500)
    t = System.monotonic_time(:millisecond)
    sampler = Task.async(fn -> sample(ctx.pool, t + 1500) end)

    fast =
      for {img, i} <- Enum.with_index(["beach.jpg", "flower.jpg", "mountain.jpg", "woman.jpg"]) do
        Task.async(fn -> get(ctx.port, "/w=#{300 + run * 10 + i}/format=jpeg/src/#{img}", :fast) end)
      end
      |> Task.await_many(120_000)

    active = Task.await(sampler)
    slow = Task.await_many(slow, 180_000)

    %{
      prefetch: prefetch,
      fast_ms: Enum.map(fast, & &1.ms),
      slow_ms: Enum.map(slow, & &1.ms),
      slow_mb: Enum.map(slow, &Float.round(&1.bytes / 1.0e6, 1)),
      pool_active_samples: active
    }
  end

  def scenario_b(ctx, prefetch, run) do
    :persistent_term.put(:ip_prefetch, prefetch)
    before = :counters.get(ctx.encodes, 1)
    path = "/w=#{3100 + run}/format=png/src/dog_2.jpg"
    leader = Task.async(fn -> get(ctx.port, path, 32_768) end)
    Process.sleep(300)
    followers = for _ <- 1..6, do: Task.async(fn -> get(ctx.port, path, :fast) end)
    f = Task.await_many(followers, 180_000)
    l = Task.await(leader, 180_000)

    %{
      prefetch: prefetch,
      leader_ms: l.ms,
      follower_ms: Enum.map(f, & &1.ms),
      encodes: :counters.get(ctx.encodes, 1) - before
    }
  end
end

ctx = SlowClient.start()
Logger.configure(level: :warning)
# warm up
SlowClient.get(ctx.port, "/w=100/format=jpeg/src/dog.jpg", :fast) |> IO.inspect(label: :warm)

which = List.first(System.argv()) || "ab"

for run <- 1..2, prefetch <- [false, true] do
  if which in ["a", "ab"], do: IO.inspect(SlowClient.scenario_a(ctx, prefetch, run * 2 + if(prefetch, do: 1, else: 0)), label: "A", charlists: :as_lists)
  if which in ["b", "ab"], do: IO.inspect(SlowClient.scenario_b(ctx, prefetch, run * 2 + if(prefetch, do: 1, else: 0)), label: "B", charlists: :as_lists)
end
