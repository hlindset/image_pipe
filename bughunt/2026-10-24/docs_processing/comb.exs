Code.require_file("/tmp/claude-0/-home-user-image-pipe/d50ad5e9-8a8c-51d3-9791-b10ebb68545c/scratchpad/docs_processing/h.exs")
d = "/tmp/claude-0/-home-user-image-pipe/d50ad5e9-8a8c-51d3-9791-b10ebb68545c/scratchpad/docs_processing"
{:ok, _} = Supervisor.start_link([{ImagePipe, name: MyApp.Images, base_url: "/images", keys: [String.duplicate("ab", 32)],
  sources: [media: [adapter: ImagePipe.Source.File, match: :path, options: [root: H.root(), root_id: "media"]]],
  cache: [root: d <> "/cache", max_size_bytes: 5_000_000_000]}], strategy: :one_for_one)
b = ImagePipe.URL.new() |> ImagePipe.URL.group(resize: [width: 400, height: 300, fit: :cover])
{:ok, res} = ImagePipe.run(MyApp.Images, b, {:source, "photos/beach.jpg"}, accept: "image/avif,image/webp")
IO.inspect({res.format, byte_size(res.data)}, label: "C run")
url = MyApp.Images |> ImagePipe.url_config() |> ImagePipe.URL.new() |> ImagePipe.URL.group(resize: [width: 400, height: 300, fit: :cover]) |> ImagePipe.URL.url!("photos/beach.jpg")
IO.inspect(url, label: "C url")
path = String.replace_prefix(url, "/images", "")
conn = Plug.Test.conn(:get, path <> "") |> Plug.Conn.put_req_header("accept", "image/avif,image/webp,*/*")
conn = ImagePipe.Plug.call(conn, ImagePipe.Plug.init(instance: MyApp.Images))
IO.inspect({conn.status, Plug.Conn.get_resp_header(conn, "content-type"), conn.resp_body == res.data, byte_size(conn.resp_body)}, label: "C plug")
conn = Plug.Test.conn(:get, path <> "") |> Plug.Conn.put_req_header("accept", "image/avif,image/webp,image/apng,*/*;q=0.8")
conn = ImagePipe.Plug.call(conn, ImagePipe.Plug.init(instance: MyApp.Images))
IO.inspect({conn.status, conn.resp_body == res.data}, label: "C plug2")
