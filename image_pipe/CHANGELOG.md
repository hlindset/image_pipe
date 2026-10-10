# Changelog

This changelog follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).
Releases use [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- Without `max_size_bytes`, `cache` and `input_cache` delete entries nobody has
  read for `max_age` seconds, 7 days by default, so images that are no longer
  requested don't stay on disk. Set `max_age: nil` to keep them. Only a running
  instance deletes them (see `ImagePipe.child_spec/1`).
- The `image_pipe.request` span carries a `request_id` attribute when Logger
  metadata has a `:request_id`, such as the one `Plug.RequestId` sets.
- The `[:cache, :lookup]`, `[:cache, :write]`, and `[:cache, :stage]`
  telemetry events carry `:cache_key`, the hash of the entry's cache key, and
  `[:cache, :lookup]` carries `:entry`, which says whether it read a processed
  response or a source record. The tracer adds them to their spans and span
  events.
- A `[:source, :decode_open]` span wraps each time libvips opens the original,
  so a trace shows how often a request opens it. The default Logger doesn't log
  it.

### Changed

- Processed images cached by an earlier version are not reused, because the
  cache key changed. The cache refills as requests come in.
- Requests for PNG and other sources that need no shrink-on-load open the
  source once instead of twice, which saves about 0.3 ms per request.
- A custom detector's `identity/1`, `available?/1`, and `ready?/1` receive only
  `:classes`, as `detect/2` already did. They no longer see the mount's other
  configuration.
- **Breaking:** The source identifiers a custom source adapter receives are
  `ImagePipe.Source.Path`, `ImagePipe.Source.URL`, and `ImagePipe.Source.Object`.
  Replace `ImagePipe.Plan.Source.Path`, `.URL`, and `.Object` in your adapter.
- **Breaking:** A source's `internal_cache` takes `:enabled` or `:disabled`,
  and defaults to `:enabled`. Replace `internal_cache: :auto`, which meant the
  same as `:enabled`.
- **Breaking:** `c:ImagePipe.Source.S3.CredentialProvider.fetch_credentials/2`
  takes the bucket and the provider's options. Change your provider's
  `fetch_credentials/3` to `fetch_credentials/2` by dropping the third
  argument, which was always `[]`.
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
- `trim` is faster on images under a megapixel: 2 ms instead of 6.5 ms on a
  256×256 image.

### Removed

- **Breaking:** `ImagePipe.Transform.Detector.Composite.new/1` and
  `default/0`. A detector is configured as a module, so a composite struct
  could not be configured. Configure `ImagePipe.Transform.Detector.Composite`
  itself to get the default face and object detectors.
- **Breaking:** Bounded caches keep request counts in memory only. Remove
  `node_id`, `state_dir`, `flush_interval`, `cleanup_interval`, and
  `state_ttl` from `cache` and `input_cache`. After a restart, a bounded
  cache keeps its entries and learns again which are requested most. You can
  delete the `.cache_state` directory under each bounded cache's `root`.
- The `[:cache, :warm_start]`, `[:cache, :flush, :stop]`, and
  `[:cache, :cleanup, :stop]` telemetry events.
- `[:cache, :stage]` no longer reports `cache: :stage_cleanup_error`.
  Discarding a staged entry doesn't fail.
- **Breaking:** `ImagePipe.Telemetry.Trace.LogExporter`,
  `ImagePipe.Telemetry.Trace.OpenTelemetryExporter`,
  `ImagePipe.Telemetry.Trace.OtelIdGenerator`,
  `ImagePipe.Telemetry.Trace.Span`, `ImagePipe.Telemetry.Trace.Context`, and
  the `ImagePipe.Telemetry.Trace.Exporter` behaviour.

### Fixed

- With `max-bytes`, a quality search that ran out of encode attempts
  shipped the lowest quality, even when it had already encoded a higher one
  that fit the budget. It now ships the highest encoded quality that fits. When
  only the lowest quality fits, the `X-ImagePipe-AQ-Outcome` debug header and
  the `[:encode, :search]` telemetry event report `hit` instead of
  `best_effort`.
- With `allow_origin` set, cross-origin scripts can send conditional
  requests such as `If-None-Match`, and can read response headers such as
  `ETag` and `Content-Disposition`. Preflight requests now get
  `Access-Control-Allow-Headers: *`, and responses get
  `Access-Control-Expose-Headers: *`.
- A comma inside a quoted `Accept` parameter, as in
  `image/webp;x="a,b";q=0`, no longer splits the entry. The split dropped the
  `q=0`, so ImagePipe could choose a format the client had excluded.
- `input_cache` rejects `max_body_bytes` instead of ignoring it, and
  configuration fails with an unknown-option error. Remove the option from
  `input_cache`.
- Concurrent fetches from an HTTP source (`ImagePipe.Source.HTTP`) just after
  startup could exit with `:noproc`. They now wait for the connection pool to
  start.
- A CMYK or other non-RGB source with an embedded color profile and more
  pixels than `max_intermediate_pixels` fails with `422`, like other oversized
  images, instead of `415`.

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
