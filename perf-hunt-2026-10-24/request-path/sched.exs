Code.require_file(Path.join(__DIR__, "harness.exs"))
Logger.configure(level: :error)
%{mount: mount} = H.setup()
path = "/w=300/format=webp/src/image.jpg"
%{status: 200} = r = H.call(mount, :get, path)
etag = r |> Plug.Conn.get_resp_header("etag") |> hd()
:persistent_term.put(:proto_noopen, System.get_env("NOOPEN") == "1")

modes = %{
  "get" => fn -> %{status: 200} = H.call(mount, :get, path) end,
  "head" => fn -> %{status: 200} = H.call(mount, :head, path) end,
  "304" => fn -> %{status: 304} = H.call(mount, :get, path, [{"if-none-match", etag}]) end
}

f = modes[System.get_env("RMODE", "head")]
Enum.each(1..300, fn _ -> f.() end)
me = self()
n = 300

collector =
  spawn(fn ->
    loop = fn loop, acc, last_out ->
      receive do
        {:trace_ts, _pid, :out, mfa, ts} -> loop.(loop, acc, {mfa, ts})
        {:trace_ts, _pid, :in, _mfa, ts} ->
          acc =
            case last_out do
              {mfa, t0} -> Map.update(acc, mfa, {1, :timer.now_diff(ts, t0)}, fn {c, d} -> {c + 1, d + :timer.now_diff(ts, t0)} end)
              nil -> acc
            end

          loop.(loop, acc, nil)

        {:done, from} -> send(from, {:acc, acc})
      end
    end

    loop.(loop, %{}, nil)
  end)

:erlang.trace(self(), true, [:running, :timestamp, {:tracer, collector}])
{t, _} = :timer.tc(fn -> Enum.each(1..n, fn _ -> f.() end) end)
:erlang.trace(self(), false, [:running])
send(collector, {:done, me})

receive do
  {:acc, acc} ->
    total_out = acc |> Map.values() |> Enum.map(&elem(&1, 1)) |> Enum.sum()
    IO.puts("wall per req #{t / n} us, scheduled-out per req #{total_out / n} us")

    acc
    |> Enum.sort_by(fn {_, {_, d}} -> -d end)
    |> Enum.take(15)
    |> Enum.each(fn {mfa, {c, d}} -> IO.puts("  #{inspect(mfa)}  #{c / n}/req  #{Float.round(d / n, 1)} us/req") end)
end
