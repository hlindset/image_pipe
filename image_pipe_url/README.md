# ImagePipe URL

Builds and signs [ImagePipe](https://github.com/hlindset/image_pipe) image URLs
without the image processing runtime. Use it in an application that only
generates URLs, while a separate service running `image_pipe` serves them.

It contains the URL grammar, the processing plan model and its validation,
presets, signing, and source encryption. Its only runtime dependencies are
`nimble_options`, `color`, and `mime`; it starts no processes and loads no NIFs.
`image_pipe` depends on this package, so a single application that both builds
and serves URLs needs only `image_pipe`.

```elixir
def deps do
  [{:image_pipe_url, "~> 0.1.0"}]
end
```

```elixir
url_config =
  ImagePipe.URL.config(
    base_url: "https://images.example.com",
    keys: [System.fetch_env!("IMAGE_PIPE_SIGNING_KEY")],
    presets: %{"card" => "w=400/h=300/fit=cover"}
  )

url =
  ImagePipe.URL.new(url_config, presets: ["card"])
  |> ImagePipe.URL.output(format: :webp)
  |> ImagePipe.URL.url!("photos/beach.jpg")
```

Generation performs no source, image, or cache I/O. The serving mount must use
the same signing keys, source-encryption keys, and preset map, and should be
deployed before the application that builds URLs. See
[split deployments](https://github.com/hlindset/image_pipe/blob/main/image_pipe/docs/elixir-api.md#split-deployments)
in the ImagePipe guides.

The two packages are released in lockstep at the same version.
