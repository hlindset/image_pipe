# ImagePipe documentation

## Start here

Start with [installation](installation.md), then choose
the guide that matches your application:

| I want to… | Guide |
| --- | --- |
| Serve resized images from Phoenix or a Plug router | [Plug usage](plug-usage.md) |
| Build URLs in an application and serve images separately | [URL builder with an external server](external-server.md) |
| Process uploads, files, or images in background jobs | [Elixir API](elixir-api.md) |
| Generate URLs and precompute images with shared settings | [Combined usage](combined-usage.md) |
| Try the controls locally | [Run the Fiddle](fiddle.md) |

## Configure your application

- [Configuration](configuration.md): where settings belong, defaults, limits, and overrides.
- [Image sources](sources.md): local files, HTTP(S), S3, and custom adapters.
- [S3 credentials](s3-credentials.md): static keys, roles, temporary credentials, and warmup.
- [Source network policy](source-network-policy.md): allowed origins and private networks.
- [URLs and presets](urls.md): path structure, reusable recipes, signing, expiry, and source concealment.

## Choose processing options

Start with the [processing overview](processing.md) for ordering, units, defaults,
and a complete option index. Each category shows URL and Elixir spellings.

| Category | What it covers |
| --- | --- |
| [Resize and layout](processing/resize.md) | Dimensions, fit, enlargement, DPR, zoom, canvas, padding, background |
| [Orientation and cropping](processing/crop.md) | EXIF, rotation, flip, trim, regions, anchors, focus, detection |
| [Effects](processing/effects.md) | Blur, sharpen, pixelate, grayscale, color adjustments, overlays |
| [Watermarks](processing/watermark.md) | Image watermarks with opacity, scale, placement, and tiling |
| [Output and encoding](processing/output.md) | Formats, quality, size budgets, encoders, profiles, HDR, placeholders, info |
| [Request controls](processing/request.md) | Downloads, expiry, cachebusters, debugging |

See [content-aware cropping](content-aware-gravity.md) for detector installation
and custom detection, and [API semantics](api_contract.md) for exact behavior.

## Run in production

- [Deployment](deployment.md): streaming failures, timeouts, capacity, and memory.
- [Caching](cache.md): input and output storage, freshness, and stale refreshes.
- [HTTP and CDN caching](cdn-http-cache.md): browser/CDN policy, ETags, and negotiation.
- [Processing limits](processing-controls.md): concurrency, queues, deadlines, and cancellation.
- [Error responses](errors.md): which status each failure returns, and why.

## Observe your application

- [Telemetry](telemetry.md): configure logging, metrics handlers, and request IDs.
- [Telemetry event reference](telemetry-events.md): event names, measurements, metadata, and outcomes.
- [Tracing](tracing.md): trace exporters, inbound context, and OpenTelemetry.
- [Debug headers](debug_headers.md): inspect processing and cache decisions.
- [OpenTelemetry with Jaeger](cookbook/opentelemetry-jaeger.md): a tracing walkthrough.
