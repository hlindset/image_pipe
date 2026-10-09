# Changelog

This changelog follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).
Releases use [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- The `image_pipe.request` span carries a `request_id` attribute when Logger
  metadata has a `:request_id`, such as the one `Plug.RequestId` sets.
- The `[:cache, :lookup]`, `[:cache, :write]`, and `[:cache, :stage]`
  telemetry events carry `:cache_key`, the hash of the entry's cache key, and
  `[:cache, :lookup]` carries `:entry`, which says whether it read a processed
  response or a source record. The tracer adds them to their spans and span
  events.

### Changed

- **Breaking:** `cache` and `input_cache` take the file system cache's options
  directly. Replace `cache: {ImagePipe.Cache.FileSystem, root: "..."}` with
  `cache: [root: "..."]`, and the same for `input_cache`. The server's
  `[cache]` configuration is unchanged.
- **Breaking:** The tracer now creates OpenTelemetry spans as they happen, and
  needs the OpenTelemetry SDK in your application. Remove the `exporter:`
  option from `ImagePipe.Telemetry.attach_tracer/1` and the
  `ImagePipe.Telemetry.Trace.OtelIdGenerator` `id_generator` setting from your
  `:opentelemetry` configuration. To print spans without a backend, use the
  SDK's stdout exporter. Span and trace IDs now come from the SDK, and each
  span reaches the SDK when it ends, not when the request finishes.
- A request's spans join the trace of the span that is current when the
  request starts, such as one from your Phoenix or Bandit instrumentation.
  This includes `ImagePipe.run/4` in an instrumented job. With
  `extract_inbound: true`, the inbound `traceparent` applies only when no span
  is current.
- Spans your own code opens inside ImagePipe's processes, such as in a custom
  source or detector, nest under the request's spans, with or without the
  tracer attached.
- A request that continues an inbound trace follows the caller's sampled
  flag under the SDK's default parent-based sampler. It was always recorded
  before.

### Removed

- `[:cache, :stage]` no longer reports `cache: :stage_cleanup_error`.
  Discarding a staged entry doesn't fail.
- **Breaking:** `ImagePipe.Telemetry.Trace.LogExporter`,
  `ImagePipe.Telemetry.Trace.OpenTelemetryExporter`,
  `ImagePipe.Telemetry.Trace.OtelIdGenerator`,
  `ImagePipe.Telemetry.Trace.Span`, `ImagePipe.Telemetry.Trace.Context`, and
  the `ImagePipe.Telemetry.Trace.Exporter` behaviour.

### Fixed

- Concurrent fetches from an HTTP source (`ImagePipe.Source.HTTP`) just after
  startup could exit with `:noproc`. They now wait for the connection pool to
  start.

## [0.1.0] - 2026-10-09

### Added

First release of ImagePipe, with image processing powered by
[elixir-image/image](https://github.com/elixir-image/image),
[Vix](https://github.com/akash-akya/vix), and libvips.

- Serve transformed images on demand from Phoenix or any Plug application
  through `ImagePipe.Plug`. Reuse the same processing plans and configuration
  for uploads, files, and background jobs through the Elixir API.
- Read originals from local files, HTTP(S), S3-compatible storage, or custom
  source adapters.
- Compose resizing, cropping, orientation, effects, and watermarks in explicit
  processing groups, with optional face and object detection, or your own
  detector.
- Define reusable presets and request defaults in your configuration,
  statically or through a host preset lookup backed by a database or cache.
- Encode JPEG, PNG, WebP, and AVIF, with format negotiation, quality controls,
  byte budgets, and color-profile policies. Automatic quality gives each image
  the lowest quality that still looks as good as a target you choose. Generate
  BlurHash, LQIP CSS, and image-info JSON.
- Configure input and output caches, conditional HTTP responses, streamed
  delivery, request safety limits, and processing concurrency. Observe requests
  through telemetry, logging, and tracing.

[Unreleased]: https://github.com/hlindset/image_pipe/compare/v0.1.0...HEAD
[0.1.0]: https://github.com/hlindset/image_pipe/releases/tag/v0.1.0
