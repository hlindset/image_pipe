defmodule Burst do
  @images Path.expand("priv/static/images")
  def start(conc) do
    root = Path.join(System.tmp_dir!(), "burst-#{System.unique_integer([:positive])}")
    enc = :counters.new(2, [:atomics])
    :telemetry.attach(:enc, [:burst, :encode, :stop], &__MODULE__.h/4, enc)
    :telemetry.attach(:coord, [:burst, :cache, :coordination], &__MODULE__.c/4, enc)

    {:ok, _} =
      Supervisor.start_link(
        [
          {ImagePipe,
           name: Burst.I,
           allow_unsigned: true,
           telemetry_prefix: [:burst],
           sources: [
             media: [
               adapter: ImagePipe.Source.File,
               match: :path,
               options: [root: @images, root_id: "media"]
             ]
           ],
           
           pool: [max_concurrency: conc, queue_timeout: 120_000, processing_timeout: 120_000]}
        ],
        strategy: :one_for_one
      )

    %{enc: enc, cfg: ImagePipe.Plug.init(instance: Burst.I)}
  end

  def h(_, _, _, c), do: :counters.add(c, 1, 1)
  def c(_, _, %{pool: :output, result: :busy}, c), do: :counters.add(c, 2, 1)
  def c(_, _, _, _), do: :ok

  def run(ctx, keys, dup, tag, img \\ "dog.jpg") do
    :counters.put(ctx.enc, 1, 0)
    :counters.put(ctx.enc, 2, 0)
    paths = for k <- 1..keys, _ <- 1..dup, do: "/w=#{40 + k}/q=#{tag}/format=jpeg/src/#{img}"

    {us, res} =
      :timer.tc(fn ->
        paths
        |> Enum.shuffle()
        |> Task.async_stream(
          fn p ->
            t = System.monotonic_time(:millisecond)
            conn = Plug.Test.conn(:get, p) |> ImagePipe.Plug.call(ctx.cfg)
            {conn.status, System.monotonic_time(:millisecond) - t}
          end,
          max_concurrency: keys * dup,
          timeout: :infinity
        )
        |> Enum.map(fn {:ok, r} -> r end)
      end)

    lat = res |> Enum.map(&elem(&1, 1)) |> Enum.sort()

    %{
      requests: length(paths),
      statuses: Enum.frequencies(Enum.map(res, &elem(&1, 0))),
      encodes: :counters.get(ctx.enc, 1),
      output_busy: :counters.get(ctx.enc, 2),
      wall_ms: div(us, 1000),
      p50: Enum.at(lat, div(length(lat), 2)),
      p99: Enum.at(lat, trunc(length(lat) * 0.99))
    }
  end
end

Logger.configure(level: :error)
[conc, keys, dup] = Enum.map(System.argv(), &String.to_integer/1)
ctx = Burst.start(conc)
Burst.run(ctx, 2, 1, 50)

for round <- 1..1, cap <- [64] do
  :persistent_term.put(:ip_max_flights, cap)
  IO.inspect({cap, Burst.run(ctx, keys, dup, 60 + round * 2 + div(cap, 4096))}, label: "round#{round}")
end
