d = "/tmp/claude-0/-home-user-image-pipe/d50ad5e9-8a8c-51d3-9791-b10ebb68545c/scratchpad/docs_server"
b = ImagePipe.URL.new() |> ImagePipe.URL.group(resize: [width: 40])
File.ln_s(d <> "/imgs/photo.jpg", d <> "/link.jpg")
for i <- [{:file, d <> "/imgs"}, {:file, d <> "/link.jpg"}, {:source, "/photo.jpg"}] do
  IO.inspect(ImagePipe.run(ImagePipe.config(sources: [m: [adapter: ImagePipe.Source.File, match: :path, options: [root: d <> "/imgs", root_id: "m"]]]), b, i) |> then(fn {:ok, r} -> {:ok, r.width}; o -> o end), label: inspect(i) |> String.slice(-30, 30))
end
{:ok, r} = ImagePipe.run(ImagePipe.config(), ImagePipe.URL.output(b, terminal: :info), {:file, d <> "/imgs/photo.jpg"})
IO.inspect({r.content_type, r.terminal, is_map(r.data)})
{:ok, _} = ImagePipe.write(ImagePipe.config(), ImagePipe.URL.output(b, terminal: :info), {:file, d <> "/imgs/photo.jpg"}, d <> "/info.json")
IO.puts(File.read!(d <> "/info.json") |> String.slice(0, 150))
