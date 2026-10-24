Logger.configure(level: :error)
images = Path.expand("priv/static/images")
root = Path.join(System.tmp_dir!(), "sz-#{System.unique_integer([:positive])}")

{:ok, _} =
  Supervisor.start_link(
    [
      {ImagePipe,
       name: Sz.I,
       allow_unsigned: true,
       sources: [
         media: [adapter: ImagePipe.Source.File, match: :path, options: [root: images, root_id: "media"]]
       ],
       cache: [root: root, max_size_bytes: 1_000_000_000]}
    ],
    strategy: :one_for_one
  )

cfg = ImagePipe.Plug.init(instance: Sz.I)
conf = ImagePipe.Config.fetch_instance!(Sz.I).options
w = :erts_debug.flat_size(conf)
IO.puts("instance config flat words: #{w} (#{w * 8} bytes)")
{us, _} = :timer.tc(fn -> for _ <- 1..1000 do
  pid = spawn(fn -> receive do {:c, c} -> :erts_debug.flat_size(c) end end)
  send(pid, {:c, conf}) end end)
IO.puts("1000 sends of config: #{us} us")
