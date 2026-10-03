# ImagePipe documentation

ImagePipe resizes, crops, and converts images, either on request over HTTP or
in Elixir code. Start with the page for what you want to do:

| I want to… | Start with |
| --- | --- |
| Request images from an external ImagePipe server | [Requesting images](requesting-images.md) |
| Run `image_pipe_server` | [Getting started with the server](../../image_pipe_server/docs/server-getting-started.md), then [deploying](../../image_pipe_server/docs/server-deployment.md) and [configuring](../../image_pipe_server/docs/server-configuration.md) it |
| Serve images from my Phoenix or Plug app | [Plug usage](plug-usage.md) |
| Process images in Elixir code (uploads, jobs) | [Processing images in Elixir](processing-in-elixir.md), then the [Elixir API](elixir-api.md) |
| Generate signed URLs for a separate server | [URL builder with an external server](external-server.md), then [shared URL settings](shared-url-settings.md) and [fetching images from the server](fetching-from-the-server.md) |
| Extend ImagePipe with custom sources, detectors, or telemetry handlers | [Custom source adapters](sources.md#custom-adapters), [custom detectors](custom-detectors.md), and [telemetry handlers](telemetry.md#attaching-handlers) |

## Application setup

- [Installation](installation.md): the Hex dependency and supported image formats.
- [Combined usage](combined-usage.md): serve images and process them in code with one configuration.
- [Configuration](configuration.md): where settings belong, defaults, limits, and overrides.
- [Image sources](sources.md): local files, HTTP(S), and S3.
- [S3 credentials](s3-credentials.md): static keys, roles, temporary credentials, and warmup.
- [Source network policy](source-network-policy.md): allowed origins and private networks.
- [Enabling face and object detection](enabling-detection.md): install the detector, load its models, and require detection.

## Requesting images

[Requesting images](requesting-images.md) explains how image URLs work: their
structure, option values, presets, and signed URLs.
[Processing options](processing.md) covers processing order and a complete
option index. Each category page shows the URL and Elixir spellings.

| Category | What it covers |
| --- | --- |
| [Resize and layout](processing/resize.md) | Dimensions, fit, enlargement, DPR, zoom, canvas, padding, background |
| [Orientation and cropping](processing/crop.md) | EXIF, rotation, flip, trim, regions, anchors, focus, detection |
| [Effects](processing/effects.md) | Blur, sharpen, pixelate, grayscale, color adjustments, overlays |
| [Watermarks](processing/watermark.md) | Image watermarks with opacity, scale, placement, and tiling |
| [Output and encoding](processing/output.md) | Formats, quality, size budgets, encoders, profiles, HDR, placeholders, info |
| [Request controls](processing/request.md) | Downloads, page selection, cache busting, expiry, debugging |

- [Content-aware cropping](content-aware-gravity.md): how attention and detection choose what a crop keeps.
- [API semantics](api_contract.md): the precise rules the processing options follow.

## Caching and CDNs

- [Caching and freshness](caching-and-freshness.md): how long originals and processed images stay valid.
- [Caching processed images](caching-processed-images.md): store processed images on disk and share them between replicas.
- [Serving images through a CDN](serving-through-a-cdn.md): cache headers, source lifetimes, and CDN settings.
- [Cache storage](cache.md): what the caches store, cache key inputs, and bounded mode.
- [HTTP cache headers](cdn-http-cache.md): `Cache-Control`, `ETag`, `Vary`, and `304` responses.

## Running in production

- [Deployment](deployment.md): streaming failures, timeouts, capacity, and memory.
- [Processing limits](processing-controls.md): concurrency, queues, deadlines, and cancellation.
- [Error responses](errors.md): which status each failure returns, and why.

## Monitoring and tracing

- [Telemetry](telemetry.md): logging, metrics handlers, and request IDs.
- [Telemetry event reference](telemetry-events.md): event names, measurements, metadata, and outcomes.
- [Tracing](tracing.md): trace exporters, inbound context, and OpenTelemetry.
- [Debug headers](debug_headers.md): inspect processing and cache decisions.
- [OpenTelemetry with Jaeger](cookbook/opentelemetry-jaeger.md): a tracing walkthrough.
