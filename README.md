# ImagePipe

ImagePipe serves and processes images inside Elixir applications. Use its Plug
endpoint for on-demand HTTP images, its Elixir API for jobs and uploads, or both
with shared plans, configuration, and caches. Image and libvips power processing.

ImagePipe is unreleased and has no Hex package yet. The `0.1.0` API may change
before release.

## Get started

[Installation](docs/installation.md) explains local setup. Choose your entry point:

- [Plug usage](docs/plug-usage.md): mount in Phoenix or Plug and serve your first image.
- [Elixir API](docs/elixir-api.md): build plans, process files/uploads, and write results.
- [Combined usage](docs/combined-usage.md): generate URLs and share processing and caches.

```elixir
plan =
  ImagePipe.new()
  |> ImagePipe.group(resize: [width: 400, height: 300, fit: :cover])
  |> ImagePipe.output(format: :webp, quality: 82)

{:ok, result} = ImagePipe.run(plan, {:file, "photos/original.jpg"})
File.write!("thumbnail.webp", result.data)
```

The equivalent path for a configured source on an `/images` mount is:

```text
/images/w=400/h=300/fit=cover/format=webp/q=82/src/photos/original.jpg
```

## Documentation

[Browse all documentation](docs/index.md).

| Topic | Guides |
| --- | --- |
| Application setup | [Configuration](docs/configuration.md), [sources](docs/sources.md), [URLs and presets](docs/urls.md) |
| Processing | [Option index](docs/processing.md), [resize](docs/processing/resize.md), [crop](docs/processing/crop.md), [effects](docs/processing/effects.md), [output](docs/processing/output.md), [request controls](docs/processing/request.md) |
| Production | [Caching](docs/cache.md), [HTTP/CDN policy](docs/cdn-http-cache.md), [processing limits](docs/processing-controls.md), [network policy](docs/source-network-policy.md) |
| Observability | [Telemetry](docs/telemetry.md), [debug headers](docs/debug_headers.md), [Jaeger walkthrough](docs/cookbook/opentelemetry-jaeger.md) |
| Internals | [API contract](docs/api_contract.md), [execution flow](docs/execution_flow.md), [transform operations](docs/transform_operations.md) |

## Try the demo

The [ImagePipe Fiddle](docs/fiddle.md) is a standalone Phoenix app with visual
controls, URL editing, source selection, and tracing.

```sh
mise install
mise run setup
mise run fiddle
```

Open http://localhost:4000.

![ImagePipe Fiddle](docs/assets/demo-fiddle-desktop.png)
