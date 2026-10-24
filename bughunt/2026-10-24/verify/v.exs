import Plug.Test
opts = ImagePipe.Plug.init(allow_unsigned: true, sources: [path: [adapter: ImagePipe.Source.File, match: :path, options: [root: Path.expand("x", __DIR__), root_id: "x"]]])
for p <- ["/pad=5/bg=00ff00/format=png/src/grey_icc.jpg", "/format=png/src/grey_icc.jpg"] do
  c = conn(:get, p) |> ImagePipe.Plug.call(opts)
  px = if c.status == 200, do: (Image.from_binary!(c.resp_body) |> Image.get_pixel!(0, 0)), else: c.resp_body
  IO.inspect({p, c.status, px})
end
