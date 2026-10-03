# ImagePipe documentation

ImagePipe resizes, crops, and converts images, either on request over HTTP or
in Elixir code. Start with the page for what you want to do:

| I want to… | Start with |
| --- | --- |
| Request images from an external ImagePipe server | [Requesting images](requesting-images.md) |
| Run `image_pipe_server` | [Getting started with the server](../../image_pipe_server/docs/server-getting-started.md), then [deploying](../../image_pipe_server/docs/server-deployment.md) and [configuring](../../image_pipe_server/docs/server-configuration.md) it |
| Serve images from my Phoenix or Plug app | [Getting started with Phoenix](phoenix-getting-started.md) |
| Process images in Elixir code (uploads, jobs) | [Processing images in Elixir](processing-in-elixir.md), then the [Elixir API](elixir-api.md) |
| Generate signed URLs for a separate server | [Building URLs for the server](building-server-urls.md), then [shared URL settings](shared-url-settings.md) and [fetching images from the server](fetching-from-the-server.md) |
| Extend ImagePipe with custom sources, detectors, or telemetry handlers | [Custom sources](custom-sources.md), [custom detectors](custom-detectors.md), and [telemetry handlers](telemetry.md#attaching-handlers) |

## Getting started

First steps for each way of running ImagePipe.

- [Installation](installation.md): the Hex dependency and supported image formats.
- [Getting started with the server](../../image_pipe_server/docs/server-getting-started.md): run `image_pipe_server` in Docker and request your first images.
- [Getting started with Phoenix](phoenix-getting-started.md): serve resized images from a new Phoenix app.
- [Processing images in Elixir](processing-in-elixir.md): resize, crop, and convert a photo from `iex`.
- [Elixir API](elixir-api.md): the Elixir entry points and their guides.
- [Building URLs for the server](building-server-urls.md): generate signed URLs for a separate `image_pipe_server`.

## Requesting images

How image URLs work, and what each processing option does to the picture.

- [Requesting images](requesting-images.md): URL structure, option values, presets, and signed URLs.
- [Processing options](processing.md): the complete option index and common recipes.
- [Resize and layout](processing/resize.md): dimensions, fit, DPR, zoom, canvas, padding, and background.
- [Orientation and cropping](processing/crop.md): rotation, flip, trim, regions, anchors, and detection.
- [Effects](processing/effects.md): blur, sharpen, pixelate, color adjustments, and overlays.
- [Watermarks](processing/watermark.md): image watermarks with opacity, scale, placement, and tiling.
- [Output and encoding](processing/output.md): formats, quality, size budgets, encoders, placeholders, and info.
- [Request controls](processing/request.md): downloads, page selection, cache busting, expiry, and debugging.

## Running ImagePipe

Guides for deploying, connecting sources, caching, securing, and monitoring.

- [Deploying image_pipe_server](../../image_pipe_server/docs/server-deployment.md): Docker, Kubernetes, health checks, and capacity.
- [Limiting work per request](deployment.md): limits on originals, timeouts, slow clients, and memory.
- [Image sources](sources.md): what a source is, routing, and the available sources.
- [Serving images from local files](serving-local-files.md): read originals from a directory.
- [Serving images from an HTTP origin](serving-from-http.md): download originals from a web server.
- [Serving images from S3](serving-from-s3.md): read originals from private S3-compatible buckets.
- [Caching processed images](caching-processed-images.md): store processed images on disk and share them between replicas.
- [Serving images through a CDN](serving-through-a-cdn.md): cache headers, source lifetimes, and CDN settings.
- [Signing URLs and rotating keys](signing-urls.md): require signed URLs and replace keys safely.
- [Defining presets](defining-presets.md): named sets of URL options.
- [Enabling face and object detection](enabling-detection.md): install the detector and load its models.
- [Limiting concurrent processing](processing-controls.md): how many images are processed at once, queues, and deadlines.
- [Monitoring with telemetry](telemetry.md): logging, metrics handlers, and request IDs.
- [Exporting traces to Jaeger](cookbook/opentelemetry-jaeger.md): send traces to a local Jaeger.
- [Serving and processing in one app](combined-usage.md): serve images and process them in code with one configuration.
- [Fetching images from the server](fetching-from-the-server.md): use processed images inside your application.

## Concepts

Why ImagePipe behaves the way it does.

- [Processing order and groups](processing-order.md): the fixed stage order, and groups that run options in a different order.
- [Caching and freshness](caching-and-freshness.md): how long originals and processed images stay valid.
- [Failures during streaming](streaming-failures.md): what happens when encoding fails after headers are sent.
- [Signing and source concealment](urls.md): what a signature covers, expiry, and hidden source paths.
- [Presets](presets.md): request defaults, precedence, and pipeline presets.
- [Content-aware cropping](content-aware-gravity.md): how attention and detection choose what a crop keeps.
- [Source network policy](source-network-policy.md): what HTTP sources may connect to.
- [Request tracing](tracing.md): how traces are built, inbound trace context, and sampling.

## Extending

Plug in your own stores, detectors, and preset storage.

- [Writing a custom source](custom-sources.md): serve originals from a database, API, or blob store.
- [Writing a custom detector](custom-detectors.md): use your own model or service for `detect` crops.
- [Storing presets in a database](storing-presets-in-a-database.md): change presets without a restart.

## Reference

Settings, headers, events, and rules to look up.

- [Elixir configuration](configuration.md): where each Elixir setting goes, and which wins when they overlap.
- [Configuring image_pipe_server](../../image_pipe_server/docs/server-configuration.md): the server's TOML and environment variables.
- [Shared URL settings](shared-url-settings.md): settings the URL builder and the server must agree on.
- [Cache storage](cache.md): what the caches store, cache key inputs, and bounded mode.
- [HTTP cache headers](cdn-http-cache.md): `Cache-Control`, `ETag`, `Vary`, and `304` responses.
- [Error responses](errors.md): which status each failure returns.
- [Telemetry event reference](telemetry-events.md): event names, measurements, metadata, and outcomes.
- [Debug response headers](debug_headers.md): inspect processing and cache decisions.

## Project

About the project itself.

- [ImagePipe](../README.md): the project README.
- [Changelog](../CHANGELOG.md): changes in each release.
- [License](../LICENSE.md): the Apache License 2.0.
