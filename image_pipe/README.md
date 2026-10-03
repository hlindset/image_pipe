# ImagePipe

ImagePipe serves and processes images inside Elixir applications or as a
standalone image server. Use its Plug endpoint for on-demand HTTP images, its
Elixir API for jobs and uploads, or both with shared plans, configuration, and
caches. Image and libvips power processing.

```elixir
plan =
  ImagePipe.URL.new()
  |> ImagePipe.URL.group(resize: [width: 400, height: 300, fit: :cover])
  |> ImagePipe.URL.output(format: :webp, quality: 82)

{:ok, result} = ImagePipe.run(ImagePipe.config(), plan, {:file, "photos/original.jpg"})
File.write!("thumbnail.webp", result.data)
```

The equivalent path for a configured source on an `/images` mount is:

```text
/images/w=400/h=300/fit=cover/format=webp/q=82/src/photos/original.jpg
```

## Documentation

Start with the [documentation overview](docs/index.md).

## Try the demo

The repository includes the ImagePipe Fiddle, a Phoenix demo app with visual
controls, URL editing, source selection, and tracing.
[Running the Fiddle](https://github.com/hlindset/image_pipe/blob/main/docs/architecture/fiddle.md)
covers starting it from a repository checkout.

![ImagePipe Fiddle](docs/assets/demo-fiddle-desktop.png)
