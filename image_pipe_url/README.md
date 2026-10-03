# ImagePipe URL

Builds and signs [ImagePipe](https://github.com/hlindset/image_pipe) image URLs
without the image processing runtime. Use it in an application that only
generates URLs, while a separate service running `image_pipe` serves them.

It contains the URL grammar, the processing plan model and its validation,
preset references, signing, and source encryption. Its only runtime dependencies are
`nimble_options`, `color`, and `mime`; it starts no processes and loads no NIFs.
`image_pipe` depends on this package, so a single application that both builds
and serves URLs needs only `image_pipe`.

Add `image_pipe_url` to your application's dependencies in `mix.exs`:

```elixir
def deps do
  [{:image_pipe_url, "~> 0.1.0"}]
end
```

Run `mix deps.get` in your application.

```elixir
url_config =
  ImagePipe.URL.config(
    base_url: "https://images.example.com",
    keys: [System.fetch_env!("IMAGE_PIPE_SIGNING_KEY")]
  )

url =
  ImagePipe.URL.new(url_config, presets: ["card"])
  |> ImagePipe.URL.output(format: :webp)
  |> ImagePipe.URL.url!("photos/beach.jpg")
```

Generation performs no source, image, or cache I/O. Follow the
[builder + external server guide](https://github.com/hlindset/image_pipe/blob/main/image_pipe/docs/building-server-urls.md)
to run `image_pipe_server`, generate your first working URL, and synchronize
keys. Preset definitions live on the server; URLs carry only their names.

The two packages are released in lockstep at the same version.

See the [changelog](CHANGELOG.md) for release notes.
