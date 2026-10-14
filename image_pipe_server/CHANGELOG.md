# Changelog

This changelog follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).
Releases use [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Fixed

- A source's `bearer_token` with a line break or NUL passed the startup
  check, and every fetch from that source then failed. The server now
  refuses to start, naming the setting.
- Every log line was preceded by a blank line, which log collectors stored
  as an empty entry. Log lines now also start with the date, as in
  `2026-10-14 19:55:23.967 request_id=abc [info] ...`.

## [0.2.0] - 2026-10-13

### Added

- The `IPS_CONFIG_TOML` environment variable holds the whole TOML
  configuration, for platforms that can't mount a configuration file. `IPS_`
  setting variables override it as they override the file. Setting both
  `IPS_CONFIG` and `IPS_CONFIG_TOML` is an error.
- SVG originals and SVG watermarks render like other images. An SVG renders
  straight at the size the request needs, so it stays sharp at any size, and
  a resize can make it larger than its own size without `enlarge`. Without a
  `format` or a negotiated one, the result is a PNG.
- `[processing.svg]` configures SVG rendering: `font_dirs` and
  `fallback_family` for the fonts SVG text renders in (mount a font
  directory into the container, since no system fonts are used), and
  `max_bytes`, `max_render_work`, and `max_render_pixels` to limit the work
  an SVG can cause. A `font_dirs` entry that doesn't exist, or a file in it
  that isn't a font, stops the server from starting.
- Logs and traces have an `image_pipe.source.svg_render` span for each SVG
  rendered, with its own and rendered sizes, the estimated work, and the
  limit that rejected an SVG.
- Caches delete files they can't read, such as ones another ImagePipe
  version wrote, once the files are more than an hour old. The
  `image_pipe.cache.sweep` span reports them as `unreadable`.
- Cache lookup and write spans, and cache stage span events, carry a
  `cache_key` attribute, the hash of the entry's cache key. Lookup spans also
  carry `entry` (`response` or `source_record`), and stage events carry
  `pool` (`output` or `input`).
- Cache write log lines and spans carry `bytes`, the size of the stored
  image, and lookups carry it on a hit for a processed image. Write spans
  also carry `estimated_cost_us`, the work the cache estimates it took to
  make the image.
- The `image_pipe.request` span carries a `request_id` attribute, the ID
  that tags the request's log lines.
- Traces have an `image_pipe.source.decode_open` span for each time the
  original is opened for decoding.

### Changed

- **Breaking:** `[cache.output]` and `[cache.input]` need `max_size_bytes`.
  A cache without it stops the server from starting with
  `cache.output.max_size_bytes: required`. Set `max_size_bytes` on each
  cache, below the free space on its volume.
- **Breaking:** Each cache `root` serves one server. The server writes a
  `.image-pipe-owner` file into each cache root. While another server keeps
  that file updated, the server logs an error and runs without that cache,
  and it takes the root over once the other server stops. Give each replica
  its own cache volume. A server takes over a root left by a crashed server
  on another host about 30 seconds after it starts.
- **Breaking:** A source's `internal_cache` takes `"enabled"` or
  `"disabled"`, and defaults to `"enabled"`. Replace
  `internal_cache = "auto"`, which meant the same as `"enabled"`.
- **Breaking:** An `allowed_hosts` entry of an `http` source allows only the
  scheme's default port, 80 or 443, including for redirect targets. Add an
  entry with the port, such as `"assets.example.com:8443"`, for an origin on
  another port. A `base_url` with a non-default port needs that port in
  `allowed_hosts` when the list is set. A malformed entry, such as
  `"assets.example.com:https"`, stops the server from starting.
- **Breaking:** The `image_pipe.cache.eviction` trace event and the cache
  eviction log line report `trigger` as `admission` or `startup` instead of `reconcile`.
- Processed images and originals cached by an earlier version miss once,
  because cache keys and file names changed. The cache refills as requests
  come in and deletes the old files. Cache keys now also include the SVG
  renderer and the fonts, so changing the fonts or the fallback family makes
  cached images miss again.
- The cache keeps the images that are requested often and took the most
  work to make for their size. At startup it reads only file names, so a
  large cache is ready sooner.
- Responses no longer wait for the cache volume. A processed image is stored
  in the background after it's sent, and a downloaded original while the
  request processes it. A request waiting for another request's image or
  original stops waiting when it isn't stored 2 seconds after it was sent or
  downloaded, and the `image_pipe.cache.coordination` trace event reports
  `reason` as `deadline`.
- When the cache volume can't keep up, writes are dropped instead of queued,
  and unfinished writes count against `max_size_bytes`. A write evicts what
  it needs before it's stored, so stored images stay under
  `max_size_bytes`. An image larger than a twentieth of `max_size_bytes`, or
  256 MiB, is never stored. Each dropped write logs `stage_dropped` at
  `warning`.
- A response to a URL with `expires` drops `stale-while-revalidate` and
  `stale-if-error`, because caches can't use them alongside its
  `must-revalidate`.
- Each trace span is exported when it ends, not when the request finishes.
- With `trust_traceparent`, a request that carries a `traceparent` header
  follows the caller's sampled flag. Before, it was always exported.
- The server uses about 140 MiB less memory: it loads its code when it first
  needs it instead of all at startup. Set `RELEASE_MODE=embedded` to load
  everything at startup.
- Before it reports ready, the server processes a small image in each output
  format, so the first requests don't wait for the image-processing code to
  load or an encoder to start. `/health/ready` now answers `503` until then, including on the
  separate `health_port` listener.
- Images process faster, PNG most of all. The Docker images now ship zlib-ng
  2.3.3, libjpeg-turbo 3.2.0 and libpng 1.6.59 in place of Debian's zlib,
  libjpeg-turbo and libpng. Across a set of typical requests, latency dropped
  by about a quarter, and by more than half for some PNG resizes.
- The server handles about 5–10% more images per second when the container
  has a CPU limit: the Erlang VM's schedulers no longer spin while they wait
  for work, which took CPU that image processing needed.
- `trim` is faster on images under a megapixel.
- PNG originals, and others that need no shrink-on-load, are opened once
  instead of twice.
- Uses `image_pipe`
  [0.2.0](https://github.com/hlindset/image_pipe/blob/v0.2.0/image_pipe/CHANGELOG.md).

### Removed

- **Breaking:** `node_id`, `state_dir`, `flush_interval`,
  `cleanup_interval`, and `state_ttl` in `[cache.output]` and
  `[cache.input]`. The cache keeps request counts in memory, so after a
  restart it keeps its entries and learns again which are requested most.
  Remove the settings, and delete each cache's `state_dir`, by default
  `.cache_state` under its root.
- **Breaking:** `eviction_victim_limit` and `reconcile_interval` in
  `[cache.output]` and `[cache.input]`. Remove them from your configuration.
- **Breaking:** `window_ratio`, `sketch_depth`, `sketch_width`,
  `aging_sample_size`, `doorkeeper_cardinality`, `doorkeeper_fpr`, and
  `path_prefix` in `[cache.output]` and `[cache.input]`. Remove them from
  your configuration. The cache no longer reads or cleans up the entries
  under a `path_prefix` directory, so delete that directory.
- **Breaking:** `rescan_interval` in `[cache.output]` and `[cache.input]`,
  and the `image_pipe.cache.rescan` span and log line. Remove
  `rescan_interval` from your configuration. A cache deletes leftover files
  after its startup scan and then every 24 hours.
- **Breaking:** The `image_pipe.cache.warm_start` span and the cache flush
  and cleanup span events. Remove alerts or queries that use them.
- Cache stage events no longer report `stage_cleanup_error`.

### Fixed

- A cache write log line and span report an error when the cache isn't
  running, instead of reporting the image as written.
- A comma inside a quoted `Accept` parameter, as in
  `image/webp;x="a,b";q=0`, no longer splits the entry and drops the `q=0`,
  so the server no longer chooses a format the client excluded.
- With `[http] allow_origin` set, cross-origin scripts can send conditional
  requests such as `If-None-Match` and read headers such as `ETag` and
  `Content-Disposition`. Preflight requests get
  `Access-Control-Allow-Headers: *`, and responses get
  `Access-Control-Expose-Headers: *`.
- With `max-bytes`, a quality search that ran out of encode attempts ships
  the highest encoded quality that fits instead of the lowest. When only the
  lowest quality fits, `X-ImagePipe-AQ-Outcome` and the logs report `hit`.
- A `crop` placed with `focus` on an image with an EXIF orientation other
  than 1 or 5 could land one pixel off when its position fell on a half
  pixel.
- The source cache stores and reuses originals whose `Cache-Control` has a
  qualified `private="..."` or `no-cache="..."` naming only headers
  ImagePipe doesn't keep, such as `private="Set-Cookie"`. Before, they were
  never stored, or revalidated on every request.
- Concurrent fetches from an `http` source just after startup could fail.
  They now wait for the connection pool to start.
- A CMYK or other non-RGB source with an embedded color profile and more
  pixels than `max_intermediate_pixels` fails with `422`, like other
  oversized images, instead of `415`.

## [0.1.0] - 2026-10-09

### Added

First release of the standalone ImagePipe server.

- Run a dedicated HTTP image service from the published Docker images at
  `ghcr.io/hlindset/image_pipe_server`, or build it as a Mix release. Configure
  it through TOML and environment variables, without writing an Elixir
  application.
- Configure file, HTTP(S), and S3 sources, filesystem caches, signing keys,
  presets, and processing limits. Load secrets from mounted files.
- Serve images under a configurable mount path, with health checks, request
  IDs, optional bearer authentication, logging, and OpenTelemetry export.
- Choose a base image or a vision image with bundled face and object detection
  models.

[Unreleased]: https://github.com/hlindset/image_pipe/compare/image_pipe_server-v0.2.0...HEAD
[0.2.0]: https://github.com/hlindset/image_pipe/compare/image_pipe_server-v0.1.0...image_pipe_server-v0.2.0
[0.1.0]: https://github.com/hlindset/image_pipe/releases/tag/image_pipe_server-v0.1.0
