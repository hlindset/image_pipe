# elixir drive.exs MODE CONCURRENCY DURATION_S
# MODE: mix | big | hits | distinct | autoq | origin
[mode, conc, dur] = System.argv()
conc = String.to_integer(conc)
dur = String.to_integer(dur) * 1000
:inets.start()
:httpc.set_options(max_sessions: 1000, max_keep_alive_length: 1000, keep_alive_timeout: 30_000)
base = "http://127.0.0.1:18181"

large = ~w(dog_2.jpg mountain.jpg beach.jpg cooking.png alpha.png para.webp)
small = ~w(woman.jpg concert.jpeg)
fmts = ~w(jpeg webp avif png)

rand_w = fn -> Enum.random(100..1600) end

gen = fn
  "mix" ->
    r = :rand.uniform(100)
    cond do
      r <= 30 -> "/w=#{Enum.random([200, 400, 800])}/src/#{Enum.random(large ++ small)}"
      r <= 55 -> "/w=#{rand_w.()}/format=#{Enum.random(fmts)}/src/#{Enum.random(large)}"
      r <= 70 -> "/w=#{rand_w.()}/h=#{rand_w.()}/fit=cover/src/#{Enum.random(small ++ large)}"
      r <= 80 -> "/w=#{rand_w.()}/autoquality/format=#{Enum.random(~w(jpeg webp))}/src/#{Enum.random(large)}"
      r <= 90 -> "/w=#{rand_w.()}/src/many/d#{Enum.random(1..400)}.jpg"
      true -> "/w=#{rand_w.()}/src/origin/#{Enum.random(large)}"
    end

  "big" -> "/w=#{rand_w.()}/format=#{Enum.random(~w(jpeg webp png))}/src/#{Enum.random(large)}"
  "hits" -> "/w=#{Enum.random([200, 400])}/src/#{Enum.random(large ++ small)}"
  "distinct" -> "/w=#{rand_w.()}/src/many/d#{Enum.random(1..400)}.jpg"
  "autoq" -> "/w=#{rand_w.()}/autoquality/format=#{Enum.random(~w(jpeg webp avif))}/src/#{Enum.random(large)}"
  "origin" -> "/w=#{rand_w.()}/src/origin/#{Enum.random(large ++ small)}"
end

deadline = System.monotonic_time(:millisecond) + dur
parent = self()

workers =
  for i <- 1..conc do
    spawn_link(fn ->
      :rand.seed(:exsss, {i, 42, String.to_integer(System.get_env("SEED", "7"))})
      loop = fn loop, acc ->
        if System.monotonic_time(:millisecond) > deadline do
          send(parent, {:done, acc})
        else
          path = gen.(mode)
          accept = Enum.random([~c"image/avif,image/webp,*/*", ~c"image/webp,*/*", ~c"*/*"])
          t = System.monotonic_time(:microsecond)
          res = :httpc.request(:get, {~c"#{base}#{path}", [{~c"accept", accept}]}, [timeout: 60_000], body_format: :binary)
          lat = System.monotonic_time(:microsecond) - t
          key = case res do
            {:ok, {{_, s, _}, _, _}} -> s
            {:error, e} -> {:error, e |> inspect() |> String.slice(0, 40)}
          end
          loop.(loop, [{key, lat} | acc])
        end
      end
      loop.(loop, [])
    end)
  end

results = for _ <- workers, do: (receive do {:done, a} -> a end)
all = List.flatten(results)
lats = all |> Enum.map(&elem(&1, 1)) |> Enum.sort()
n = length(lats)
pct = fn p -> Enum.at(lats, min(n - 1, trunc(n * p))) / 1000 end
IO.puts("#{mode} c=#{conc}: n=#{n} rps=#{Float.round(n / (dur / 1000), 1)} p50=#{pct.(0.5)}ms p99=#{pct.(0.99)}ms statuses=#{inspect(Enum.frequencies_by(all, &elem(&1, 0)))}")
