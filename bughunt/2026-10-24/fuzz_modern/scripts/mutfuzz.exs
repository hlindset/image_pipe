# mutfuzz.exs SEEDFILE N  -> mutates N times, runs through plug in-process, prints anomalies
import Plug.Test
[seed, nstr] = System.argv()
n = String.to_integer(nstr)
orig = File.read!(seed)
dir = "/tmp/claude-0/-home-user-image-pipe/d50ad5e9-8a8c-51d3-9791-b10ebb68545c/scratchpad/fuzz_modern/mut/" <> (Path.basename(seed))
File.mkdir_p!(dir)
ext = Path.extname(seed)
config = ImagePipe.Plug.init(allow_unsigned: true,
  sources: [path: [adapter: ImagePipe.Source.File, match: :path, options: [root: dir, root_id: "fz"]]])
:rand.seed(:exsss, {:erlang.phash2(seed), n, 7})
pipes = ["", "w=300/", "blur=5/format=png/", "pad=5/bg=00ff00/format=png/", "format=avif/"]
for k <- 1..n do
  b = :binary.bin_to_list(orig) |> :erlang.list_to_binary()
  sz = byte_size(b)
  mut =
    case rem(k, 4) do
      0 -> # flip random bytes
        Enum.reduce(1..(:rand.uniform(8)), b, fn _, acc ->
          pos = :rand.uniform(sz) - 1
          <<pre::binary-size(pos), _::8, post::binary>> = acc
          <<pre::binary, :rand.uniform(256)-1::8, post::binary>>
        end)
      1 -> binary_part(b, 0, :rand.uniform(sz)) # truncate
      2 -> # zero a run
        pos = :rand.uniform(sz) - 1
        len = min(:rand.uniform(64), sz - pos)
        <<pre::binary-size(pos), _::binary-size(len), post::binary>> = b
        <<pre::binary, :binary.copy(<<0>>, len)::binary, post::binary>>
      3 -> b <> :crypto.strong_rand_bytes(:rand.uniform(128)) # append junk
    end
  name = "m#{k}#{ext}"
  File.write!(Path.join(dir, name), mut)
  _ = mut
  p = Enum.random(pipes)
  t0 = System.monotonic_time(:millisecond)
  res =
    try do
      c = conn(:get, "/" <> p <> "src/" <> name) |> ImagePipe.Plug.call(config)
      {:status, c.status}
    catch kk, rr -> {:raise, kk, String.slice(inspect(rr),0,120)} end
  dt = System.monotonic_time(:millisecond) - t0
  flag =
    case res do
      {:status, s} when s in [200,400,413,415,422] -> if dt > 3000, do: "SLOW", else: nil
      {:status, 500} ->
        body = (try do (conn(:get, "/" <> p <> "src/" <> name) |> ImagePipe.Plug.call(config)).resp_body catch _,_ -> "?" end)
        File.cp(Path.join(dir, name), "/tmp/claude-0/-home-user-image-pipe/d50ad5e9-8a8c-51d3-9791-b10ebb68545c/scratchpad/fuzz_modern/crash500/#{name}")
        "STATUS500 body=#{inspect(String.slice(body,0,160))}"
      {:status, s} when s != 404 -> "STATUS#{s}"
      {:raise, _, _} -> "RAISE"
    end
  if flag, do: IO.puts("#{flag} k=#{k} pipe=#{inspect p} #{inspect res} #{dt}ms #{name}")
  File.rm(Path.join(dir, name))
end
IO.puts("done #{seed}")
