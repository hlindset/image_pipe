# usage: MIX_ENV=test mix run run.exs DIR REPS PATH [--work]
import Plug.Test
[dir, reps, path | rest] = System.argv()
reps = String.to_integer(reps)
Logger.configure(level: :error)
Vix.Vips.cache_set_max(0)

config =
  ImagePipe.Plug.init(
    allow_unsigned: true,
    max_body_bytes: 200_000_000,
    sources: [
      path: [adapter: ImagePipe.Source.File, match: :path, options: [root: dir, root_id: "perf"]]
    ],
    watermarks: %{mark: [source: "alpha.png"]}
  )

req = fn -> ImagePipe.Plug.call(conn(:get, path), config) end
c = req.()
hw1 = Vix.Vips.tracked_get_mem_highwater()
if c.status != 200, do: raise("status #{c.status}: #{inspect(c.resp_body |> binary_part(0, min(200, byte_size(c.resp_body))))}")

times =
  for _ <- 1..reps do
    {t, c} = :timer.tc(req)
    200 = c.status
    t / 1000
  end

sorted = Enum.sort(times)
median = Enum.at(sorted, div(length(sorted), 2))
hw = Vix.Vips.tracked_get_mem_highwater()

work =
  if "--work" in rest do
    {_c, w} = ImagePipe.Test.WorkCount.measure(req)
    " copies=#{w.copies} ops=#{inspect(Enum.sort(w.operations) |> Enum.reject(fn {k, _} -> k in ~w(VipsForeignLoadJpegFile) end))}"
  else
    ""
  end

if "--save" in rest do
  File.write!(Path.join(dir, "out_" <> (List.last(rest)) ), c.resp_body)
end

IO.puts("#{path} median=#{Float.round(median, 1)}ms min=#{Float.round(hd(sorted), 1)}ms hw1=#{Float.round(hw1 / 1_048_576, 1)}MiB hw=#{Float.round(hw / 1_048_576, 1)}MiB bytes=#{byte_size(c.resp_body)}#{work}")
