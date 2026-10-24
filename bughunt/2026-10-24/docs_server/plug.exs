d = "/tmp/claude-0/-home-user-image-pipe/d50ad5e9-8a8c-51d3-9791-b10ebb68545c/scratchpad/docs_server"
p = fn l, f -> r = try do f.() rescue e -> {:raised, e.__struct__, Exception.message(e)} end; IO.puts("#{l}: #{inspect(r, limit: 12, printable_limit: 300) |> String.slice(0, 400)}") end
src = [sources: [m: [adapter: ImagePipe.Source.File, match: :path, options: [root: d <> "/imgs", root_id: "m"]]]]
p.("init unsigned", fn -> ImagePipe.Plug.init(src); :init_ok end)
o = ImagePipe.Plug.init(src ++ [allow_unsigned: true])
for m <- [:get, :head, :options, :post, :put, :delete] do
  p.("method #{m}", fn -> c = ImagePipe.Plug.call(Plug.Test.conn(m, "/w=10/src/photo.jpg"), o); {c.status, Plug.Conn.get_resp_header(c, "allow")} end)
end
p.("instance not running", fn -> ImagePipe.Plug.call(Plug.Test.conn(:get, "/w=10/src/photo.jpg"), ImagePipe.Plug.init(instance: NotRunning)) end)
p.("instance + other opt", fn -> ImagePipe.Plug.init(instance: NotRunning, quality: 3) end)
p.("instance + http_cache", fn -> ImagePipe.Plug.init(instance: NotRunning, http_cache: :auto); :ok end)
