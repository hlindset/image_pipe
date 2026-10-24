File.cd!("/tmp/claude-0/-home-user-image-pipe/d50ad5e9-8a8c-51d3-9791-b10ebb68545c/scratchpad/docs_server/run1")
plan =
  ImagePipe.URL.new()
  |> ImagePipe.URL.group(resize: [width: 400, height: 300, fit: :cover])
  |> ImagePipe.URL.output(format: :webp, quality: 82)

r = ImagePipe.run(ImagePipe.config(), plan, {:file, "photos/original.jpg"})
IO.inspect(r |> then(fn {:ok, x} -> Map.drop(x, [:data]); o -> o end), limit: 20)
