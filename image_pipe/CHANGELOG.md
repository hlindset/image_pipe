# Changelog

This changelog follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).
Releases use [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Changed

- **Breaking:** `ImagePipe.config/1` raises `ArgumentError` for a preset or
  request defaults whose own options can't be combined, such as
  `anchor=top/detect=face` or `q=80/autoquality=50`. It also raises for a `wm`
  name missing from `:watermarks`, and for `wm-src64` or `wm-enc` without
  `request_watermarks: true`. Requests that used them failed with `400`
  unless the URL replaced the conflicting options. Remove one of the
  conflicting options, or the watermark option.
- A preset from a preset lookup whose own options can't be combined answers
  `500`, like other invalid stored presets, instead of `400`, and
  `ImagePipe.run/4` returns `{:preset, :invalid_definition}` for it.
- A request with `pad=0` gets the cache key and ETag of the same request
  without `pad`, and a `gradient` or `progressive-blur` that starts or stops
  at `-0.0` gets those of one at `0`. Cached copies of such requests miss once
  after an upgrade.
- A `format-q` entry for `png` applies only when PNG has a palette, like `q`.
  Before, a URL with one and no palette failed with `400`, even when the
  response wasn't PNG, and one in `request_defaults` or a preset made every
  request fail.

### Fixed

- `format=png` with `q`, from the URL, the request defaults, or a preset,
  failed with `400` when PNG had no palette. A `q` in `request_defaults` or a
  preset made every `format=png` request fail. PNG without a palette now
  ignores `q`, as negotiated PNG already did.
- On a URL with `expires`, a response gets `Cache-Control: no-store`, even
  when an earlier Plug set `Cache-Control`, if storage is denied by its origin
  or by configuration, or if a crop fell back because content detection
  failed. Before, it got the earlier Plug's `Cache-Control` capped at the
  expiry, and a CDN could store it.
- An SVG source with `fit=stretch` and one axis, such as `w=480/fit=stretch`,
  or with only `min-w` or `min-h`, stayed at its intrinsic size instead of
  rendering at the requested size. It now renders at that size, like any
  other first-group resize of an SVG.
- On a URL with `expires`, a `Cache-Control` set by an earlier Plug is capped
  at the expiry in more cases:
  - A quoted value, such as `max-age="86400"`, is read as seconds. A
    `max-age` that isn't a whole number of seconds, such as
    `max-age=86400.5`, is replaced, and an `s-maxage` like that is dropped.
    Before, both failed the request with `500`.
  - Directive names match in any case, so `MAX-AGE=86400` is lowered too.
  - A `Cache-Control` without `max-age`, such as `public`, gets one that ends
    at the expiry.
- A `crop` or `region` followed by a resize could give a different size for
  a JPEG source than for the same image as PNG, because JPEG decodes at a
  smaller size first. A narrow crop was off by several pixels, such as
  `crop=101,1500/w=50` giving 50×750 instead of 50×743. The size is now the
  same for every source format, in the image and in `output=info`.
- A server error (`5xx`), such as a `502` for a failing origin, gets
  `Cache-Control: no-store`, even when an earlier Plug set `Cache-Control`.
  Before, it kept the earlier Plug's `Cache-Control`, and a CDN could serve
  the error for that header's lifetime. A client error (`4xx`) still keeps
  it.
- `output=info` with an explicit `format` whose encoder has a lower size limit
  than the server's result limits, such as `format=webp` with limits above
  16,383 pixels, shared its cache entry and ETag with other formats. A cache
  could then serve one format's `result` dimensions for another.
- A request to an HTTP or S3 source that waited past `pool_timeout` for a
  free connection crashed the request process. Behind Bandit, the client got
  no response and the connection stayed open. Such requests now fail with a
  `{:source, :pool_timeout}` error, which the Plug answers with `504`.
- `autoquality` together with `max-bytes` could ship a lower quality than
  `max-bytes` alone, because the quality search used up the encodes the byte
  budget needed. The byte budget now gets its own encodes.
- A conditional header in an HTTP or S3 source's `req_options`, such as
  `if-none-match`, made the request fail when the origin answered a first
  fetch with `304`. Sources now drop `if-none-match`, `if-modified-since`,
  `if-match`, `if-unmodified-since`, and `if-range` from `req_options`.
- The detector warmup gave up after three failed attempts, about a third of
  a second, so with `detector_required: true` detection requests answered
  `503` until a restart. It now retries, at most a minute apart, until the
  models load.
- Req's `:range` option in `req_options` set a `range` header even on sources
  that drop `range` headers, which is every source except one with
  `internal_cache: :disabled` that isn't immutable. The origin then sent part
  of the image, which was processed as the whole original. These sources now
  drop the `:range` option too.
- A watermark whose stored copy in the input cache was corrupt made every
  request using it fail with `415` until the copy was evicted. The copy is now
  discarded after the first failure, and the next request fetches the
  watermark again.
- An HTTP source URL whose query has a space or a non-ASCII character, such
  as `?a b`, is fetched with those characters percent-encoded. Before, the
  request failed with `502`.
- `png-options` with `bitdepth:2` or `bitdepth:4` wrote wrong gray levels,
  such as gray 150 coming back as 102 at 4 bits. A `bitdepth` of `1`, `2`,
  or `4` on a result with alpha or color failed with `500`. Grayscale
  results without alpha now keep their gray levels, and other results
  without a palette encode at 8 bits.
- An HTTP source whose host name resolves to several addresses could run
  past `fetch_timeout`, because it waited for a response at each address in
  turn. Fetches now end by `fetch_timeout`, apart from a connection attempt,
  which can run past it by up to `connect_timeout`.
- A FileSystem cache could hold more than `max_size_bytes` on disk and not
  bring it back down:
  - A read of an entry the startup scan hadn't counted yet counted it
    without evicting. The cache now evicts back under its cap.
  - A startup scan that crashed skipped evicting down to a lowered cap. It
    now evicts as a completed scan does.
  - A write during the startup scan that was rejected or failed left its
    key's existing entry on disk uncounted. A write that replaced such an
    entry left its old body on disk. Both are now counted or deleted.
  - An entry written again after the startup sweep removed its unreadable
    metadata, as after an upgrade that changes the metadata format, wasn't
    counted.

## [0.2.0] - 2026-10-13

### Added

- SVG sources, when the optional `image_pipe_svg` package is installed.
  An SVG renders straight at the size the request needs, so it stays sharp
  at any size, and a resize can make it larger than its own `width` and
  `height` without `enlarge`, up to the input pixel limit, past which the
  rendered image is enlarged. Regions and crops in pixels measure the SVG at
  its own size. With no `format` and no negotiated format, the result is a
  PNG. Watermark images can be SVGs too, and render at the size they're
  drawn. Without `image_pipe_svg`, SVG sources still fail with `415`.
- The `:svg` option configures SVG sources: `:font_dirs` and
  `:fallback_family` for the fonts SVG text renders in (no system fonts are
  used), and `:max_bytes`, `:max_render_work`, and `:max_render_pixels` to
  limit the work an SVG can cause.
- A `[:source, :svg_render]` span wraps rendering an SVG original or
  watermark, with its intrinsic and rendered sizes and the estimated work,
  and names the limit that rejected an SVG. The default Logger logs it.
- `cache` and `input_cache` delete metadata files they can't read, such as
  ones another ImagePipe version wrote, and their bodies, once the files are
  more than an hour old. The `[:cache, :sweep]` event reports them as
  `:unreadable`.
- `[:cache, :stage]` reports writes the cache drops to keep up with its
  storage as `:stage_dropped`, for processed images and originals, and
  carries `:pool`. The default Logger logs dropped writes at `:warning`.
- `[:cache, :coordination]` carries `reason: :deadline` when a request stops
  waiting for another request's image because it wasn't stored in time.
- The `image_pipe.request` span carries a `request_id` attribute when Logger
  metadata has a `:request_id`, such as the one `Plug.RequestId` sets.
- The `[:cache, :lookup]`, `[:cache, :write]`, and `[:cache, :stage]`
  telemetry events carry `:cache_key`, the hash of the entry's cache key, and
  `[:cache, :lookup]` carries `:entry`, which says whether it read a processed
  response or a source record. The tracer adds them to their spans and span
  events.
- The `[:cache, :write]` stop event carries `:estimated_cost_us`, the work
  the cache estimates it took to make a processed image. The tracer adds it
  to the span.
- The `[:cache, :write]` stop event carries `:bytes`, the size of the stored
  body, so dividing it by the span's duration gives a rough write speed for the
  cache storage. `[:cache, :lookup]` carries `:bytes` on a hit for a processed
  response. The tracer adds `:bytes` to both spans, and the default Logger
  logs it.
- A `[:source, :decode_open]` span wraps each time libvips opens the original,
  so a trace shows how often a request opens it. The default Logger doesn't log
  it.

### Changed

- With `image_pipe_svg` installed, cache keys and ETags include the resvg
  version, the fonts, and the fallback family, so every cached image misses
  once after installing it, and again after changing the fonts or fallback
  family, or upgrading `image_pipe_svg` to a version that renders SVGs
  differently.
- **Breaking:** An HTTP source's `allowed_hosts` entry without a port allows
  only the scheme's default port, 80 or 443, including for redirect targets.
  Before, any port on a listed host was reachable. Add an entry with the port,
  such as `"assets.example.com:8443"`, for an origin on another port. A
  `base_url` with a non-default port needs that port in `allowed_hosts` when you
  set the list. A malformed entry, such as `"assets.example.com:https"`, now
  fails at startup.
- A response to a URL with `expires` drops `stale-while-revalidate` and
  `stale-if-error`, including ones the host sets, because caches can't use them
  alongside its `must-revalidate`.
- Processed images and originals cached by an earlier version are not
  reused, because the cache key changed and entry files are named
  differently. The cache refills as requests come in, and deletes the old
  files as
  [leftover files](https://hexdocs.pm/image_pipe/cache.html#leftover-files).
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
- **Breaking:** `[:cache, :eviction, :stop]` reports the entries a write
  evicts, with `trigger: :admission`, and the startup scan's batches with
  `trigger: :startup`. Update handlers that match `trigger: :reconcile`.
- Responses no longer wait for the cache's disk. A processed image is stored
  in the background after it's sent, and a downloaded original while the
  request processes it. The `[:cache, :write]` span can end after the
  request.
- A request waiting for another request's image or original stops waiting
  when the image or original isn't stored 2 seconds after it was sent or
  downloaded.
- When the disk can't keep up, writes are dropped, and unfinished writes
  count against `max_size_bytes`. An entry larger than a twentieth of
  `max_size_bytes`, or 256 MiB, is never stored (see
  [writing entries](https://hexdocs.pm/image_pipe/cache.html#writing-entries)).
- `trim` is faster on images under a megapixel: 2 ms instead of 6.5 ms on a
  256×256 image.
- **Breaking:** `cache` and `input_cache` need `max_size_bytes`, and an
  ImagePipe instance (see `ImagePipe.child_spec/1`). Add `max_size_bytes` to
  each cache, and to the options of `ImagePipe.Cache.FileSystem.get/2`, and
  move a configuration with a cache from `ImagePipe.Plug` options or an
  `ImagePipe.run/4` call into an instance. `run/4` with an instance name
  can't set `cache` or `input_cache` per call.
- **Breaking:** Each `root` of `cache` and `input_cache` serves one node. An
  instance writes a `.image-pipe-owner` file into each cache's `root`.
  While another node keeps that file updated, the instance logs an error and
  runs without that cache, and it takes the `root` over once the other node
  stops. Give each replica its own cache directories, such as its own volume.
  When a node is killed, a node on another host that starts after the kill
  takes over its `root` about 30 seconds after starting.
- `cache` and `input_cache` keep the entries that are requested often and
  took the most work to make for their size. For a processed image, that work
  is estimated from the request instead of timed (see
  [work to make an entry](https://hexdocs.pm/image_pipe/cache.html#work-to-make-an-entry)).
  On startup a cache reads only file names, so a large cache is ready sooner.

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
- **Breaking:** The `eviction_victim_limit` and `reconcile_interval` options
  of `cache` and `input_cache`. Remove them from your configuration. A write
  now evicts every entry it needs before it's stored, so the stored bodies
  stay under `max_size_bytes` once the startup scan has run, and the cache no
  longer runs a background eviction pass every minute.
- **Breaking:** The `window_ratio`, `sketch_depth`, `sketch_width`,
  `aging_sample_size`, `doorkeeper_cardinality`, `doorkeeper_fpr`, and
  `path_prefix` options of `cache` and `input_cache`. Remove them from your
  configuration. The cache no longer reads or cleans up the old entries under
  a `path_prefix` directory, so delete that directory.
- **Breaking:** The `rescan_interval` option of `cache` and `input_cache`, and
  the `[:cache, :rescan]` telemetry event. Remove `rescan_interval` from your
  configuration. A cache deletes leftover files after its startup scan
  and then every 24 hours.
- `[:cache, :stage]` no longer reports `cache: :stage_cleanup_error`.
  Discarding a staged entry doesn't fail.
- **Breaking:** `ImagePipe.Telemetry.Trace.LogExporter`,
  `ImagePipe.Telemetry.Trace.OpenTelemetryExporter`,
  `ImagePipe.Telemetry.Trace.OtelIdGenerator`,
  `ImagePipe.Telemetry.Trace.Span`, `ImagePipe.Telemetry.Trace.Context`, and
  the `ImagePipe.Telemetry.Trace.Exporter` behaviour.

### Fixed

- `[:cache, :write]` reports a write error instead of `cache: :write` when
  the cache's process isn't running, since nothing was stored.
- A `crop` placed with `focus` on an image with an EXIF orientation other than
  1 or 5 could land one pixel off from the same crop on an untagged image,
  when the crop's position fell on a half pixel.
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
- The source cache stores and reuses originals whose `Cache-Control` has a
  qualified `private="..."` or `no-cache="..."` naming only headers ImagePipe
  doesn't keep, such as `private="Set-Cookie"`. They were treated as
  unqualified `private` (never stored) or `no-cache` (revalidated on every
  request).

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

[Unreleased]: https://github.com/hlindset/image_pipe/compare/v0.2.0...HEAD
[0.2.0]: https://github.com/hlindset/image_pipe/compare/v0.1.0...v0.2.0
[0.1.0]: https://github.com/hlindset/image_pipe/releases/tag/v0.1.0
