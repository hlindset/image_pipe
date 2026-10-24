System.put_env("IMAGE_PIPE_SIGNING_KEY", String.duplicate("ab", 32))
url_config =
  ImagePipe.URL.config(
    base_url: "https://images.example.com",
    keys: [System.fetch_env!("IMAGE_PIPE_SIGNING_KEY")]
  )

url =
  ImagePipe.URL.new(url_config)
  |> ImagePipe.URL.group(presets: ["card"])
  |> ImagePipe.URL.output(format: :webp)
  |> ImagePipe.URL.url!("photos/beach.jpg")
IO.puts(url)
