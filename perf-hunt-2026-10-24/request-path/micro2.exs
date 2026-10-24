Code.require_file(Path.join(__DIR__, "harness.exs"))
Logger.configure(level: :error)
%{mount: mount, root: root} = H.setup()
path = "/w=300/format=webp/src/image.jpg"
%{status: 200} = H.call(mount, :get, path)
Enum.each(1..5, fn _ -> H.call(mount, :head, path) end)

config = ImagePipe.Plug.Config.resolve(mount)
[meta] = Path.wildcard(Path.join([root, "output", "**", "*.meta"]))
hash = Path.basename(meta, ".meta")
key = %ImagePipe.Cache.Key{hash: hash, data: []}
cache_opts = Keyword.fetch!(config, :cache)
croot = Keyword.fetch!(cache_opts, :root)
alias ImagePipe.Cache.FileSystem.Store

bench = fn name, f, n ->
  Enum.each(1..500, fn _ -> f.() end)
  {t, _} = :timer.tc(fn -> Enum.each(1..n, fn _ -> f.() end) end)
  {:reductions, r0} = Process.info(self(), :reductions)
  Enum.each(1..n, fn _ -> f.() end)
  {:reductions, r1} = Process.info(self(), :reductions)
  IO.puts("#{String.pad_trailing(name, 40)} #{Float.round(t / n, 2)} us  #{div(r1 - r0, n)} red")
end

{:hit, e} = ImagePipe.Cache.lookup_entry(key, config)
IO.inspect(Map.from_struct(e) |> Map.delete(:body) |> Map.keys())
ImagePipe.Cache.Entry.close(e)

for _ <- 1..3 do
  bench.("Cache.lookup_entry+close", fn ->
    {:hit, e} = ImagePipe.Cache.lookup_entry(key, config)
    ImagePipe.Cache.Entry.close(e)
  end, 5_000)

  bench.("Store.registry_name", fn -> Store.registry_name(croot) end, 20_000)
  bench.("Registry.lookup(registry_name)", fn -> Registry.lookup(Store.registry_name(croot), croot) end, 20_000)
  bench.("Store.paths", fn -> Store.paths(key, cache_opts) end, 20_000)
  bench.("file open+fstat+close raw", fn ->
    {:ok, io} = :file.open(Path.join(Path.dirname(meta), "x") |> then(fn _ -> hd(Path.wildcard(Path.join(Path.dirname(meta), "*")) -- [meta]) end), [:read, :binary, :raw])
    :file.read_file_info(io, time: :posix)
    :file.close(io)
  end, 5_000)
end
