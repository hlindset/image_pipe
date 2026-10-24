import Plug.Test
[dir, reps | cases] = System.argv()
reps = String.to_integer(reps)
Logger.configure(level: :error)
Vix.Vips.cache_set_max(0)
alias Vix.Vips.Operation

config =
  ImagePipe.Plug.init(
    allow_unsigned: true,
    max_body_bytes: 200_000_000,
    sources: [path: [adapter: ImagePipe.Source.File, match: :path, options: [root: dir, root_id: "perf"]]]
  )

stages = [[:transform, :materialize], [:encode], [:deliver], [:send], [:source, :fetch_decode], [:transform, :execute], [:transform, :input_color_management]]
:ets.new(:acc, [:named_table, :public, :bag])
:telemetry.attach_many("acc", Enum.map(stages, &([:image_pipe | &1] ++ [:stop])), fn [:image_pipe | ev], m, _md, _ ->
  :ets.insert(:acc, {Enum.join(Enum.drop(ev, -1), "."), System.convert_time_unit(m.duration, :native, :microsecond)})
end, nil)

for c <- cases do
  [file, w, fmt] = String.split(c, ":")
  path = "/w=#{w}/format=#{fmt}/src/#{file}"
  pipe = fn -> 200 = ImagePipe.Plug.call(conn(:get, path), config).status end

  thumb = fn ->
    {:ok, t} = Operation.thumbnail(Path.join(dir, file), String.to_integer(w), height: 100_000)
    {:ok, _} = Vix.Vips.Image.write_to_buffer(t, ".#{fmt}[Q=80]")
  end

  pipe.(); thumb.()

  {a, b} =
    Enum.reduce(1..reps, {[], []}, fn _, {a, b} ->
      {ta, _} = :timer.tc(pipe)
      {tb, _} = :timer.tc(thumb)
      {[ta / 1000 | a], [tb / 1000 | b]}
    end)

  # stage breakdown over reps pipeline runs
  :ets.delete_all_objects(:acc)
  for _ <- 1..reps, do: pipe.()
  br = :ets.tab2list(:acc) |> Enum.group_by(&elem(&1,0), &elem(&1,1)) |> Enum.map(fn {k, v} -> "#{k}=#{Float.round(Enum.sum(v)/reps/1000,1)}" end) |> Enum.join(" ")
  med = fn l -> Enum.at(Enum.sort(l), div(length(l), 2)) |> Float.round(1) end
  IO.puts("#{c}: pipeline=#{med.(a)}ms thumbnail=#{med.(b)}ms | #{br}")
end
