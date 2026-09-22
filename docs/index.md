# ImagePipe documentation

ImagePipe processes images inside your Elixir application. Serve images through
Plug, generate them in a job or script, or use the same configuration and plans
for both. Processing is powered by Image and libvips.

## Start here

ImagePipe is unreleased. Start with [installation](installation.md), then choose
the guide that matches your application:

| I want to… | Guide |
| --- | --- |
| Serve resized images from Phoenix or a Plug router | [Plug usage](plug-usage.md) |
| Process uploads, files, or images in background jobs | [Elixir API](elixir-api.md) |
| Generate URLs and precompute images with shared settings | [Combined usage](combined-usage.md) |
| Try the controls locally | [Run the Fiddle](fiddle.md) |

## Configure your application

- [Configuration](configuration.md): where settings belong, defaults, limits, and overrides.
- [Image sources](sources.md): local files, HTTP(S), S3, and custom adapters.
- [URLs and presets](urls.md): path structure, reusable recipes, signing, expiry, and source concealment.

## Choose processing options

Start with the [processing overview](processing.md) for ordering, units, defaults,
and a complete option index. Each category shows URL and Elixir spellings.

| Category | What it covers |
| --- | --- |
| [Resize and layout](processing/resize.md) | Dimensions, fit, enlargement, DPR, zoom, canvas, padding, background |
| [Orientation and cropping](processing/crop.md) | EXIF, rotation, flip, trim, regions, anchors, focus, detection |
| [Effects](processing/effects.md) | Blur, sharpen, pixelate, grayscale, color adjustments, overlays |
| [Output and encoding](processing/output.md) | Formats, quality, size budgets, encoders, profiles, HDR, placeholders, info |
| [Request controls](processing/request.md) | Downloads, expiry, cachebusters, debugging |

See [content-aware cropping](content-aware-gravity.md) for detector installation
and custom detection, and the [API contract](api_contract.md) for exact semantics.

## Run in production

- [Caching](cache.md): input and output storage, freshness, and stale refreshes.
- [HTTP and CDN caching](cdn-http-cache.md): browser/CDN policy, ETags, and negotiation.
- [Processing limits](processing-controls.md): concurrency, queues, deadlines, and cancellation.
- [Source network policy](source-network-policy.md): allowed origins and private networks.
- [Telemetry](telemetry.md): logging, metrics, and traces.
- [Debug headers](debug_headers.md): inspect processing and cache decisions.
- [OpenTelemetry with Jaeger](cookbook/opentelemetry-jaeger.md): a tracing walkthrough.
- [Operational notes](operational_notes.md): safety, memory, and format behavior.

## Understand the implementation

The [execution flow](execution_flow.md), [transform internals](transform_operations.md),
and [cache benchmarks](cache-benchmark.md) explain how the library works.
Historical design notes live under `docs/superpowers/` in the repository;
the published guides describe the current API.
