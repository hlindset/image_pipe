# Changelog

This changelog follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).
Releases use [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- `[cache] max_remembered_originals` sets how many originals the server
  remembers in memory: a local file's hash, or an origin image's cache
  headers. It defaults to one for each 50 KB of `output.max_size_bytes`, at
  least 10,000 and at most 200,000, and forgets originals that weren't
  used recently first. A remembered file isn't read and hashed again while
  it's unchanged, and the processed images of a remembered origin image are
  served without downloading it again. Each takes about 1 KB for a local
  file and about 1.4 KB for an image from an origin. See
  [`[cache]`](docs/server-configuration.md#cache).
- `[cache.output] max_remembered_entries` sets how many recently served
  entries the cache keeps in memory, so a repeated hit reads only the body
  file. It defaults to one for each 50 KB of `max_size_bytes`, at least
  1,000 and at most 50,000, about 1.8 KB each.
- `GET /stats` (JSON) and `GET /metrics` (Prometheus text) report each
  cache's size, hits, misses, entries kept in memory, and free disk space,
  or that another replica owns its root, and how many originals the server
  remembers. The disk space is read every 15 seconds, and both
  endpoints report how many seconds ago it was read. A cache that doesn't
  answer within a second has `"available": false`. Turn them on with
  `[stats] enabled = true` and a `[stats] token` of at least 32 characters
  that requests send as a bearer token. See [cache stats](docs/server-deployment.md#cache-stats).
- `[server] health_bind` sets the address the `health_port` listener binds
  to, such as an internal one. It defaults to `bind`. See
  [health and shutdown](docs/server-deployment.md#health-and-shutdown).
- With `[telemetry] log_requests`, a request without a valid
  `[server] auth_token` logs its `401` at `warning`, and a request outside
  `mount_path` logs its `404` at `info`, each with the method, path, status,
  and duration. Before, the server logged neither.

### Changed

- **Breaking:** `[cache] storage_inputs` is now `[cache] vary_on`. Rename it
  in `config.toml`.
- **Breaking:** Without `[url] keys`, the server doesn't start unless
  `[url] allow_unsigned = true`, and with that setting it logs a warning at
  startup. Serve public traffic with signed URLs, and set `allow_unsigned`
  only for a server that nothing outside a private network can reach. See
  [`[url]`](docs/server-configuration.md#url).
- **Breaking:** `[server] auth_token` needs at least 32 characters, and the
  server doesn't start with a shorter one. Replace a shorter token, for
  example with the output of `openssl rand -hex 16`.
- The hash of each local file and the cache headers of each origin image
  are kept in memory instead of in the `output` cache, so they no longer
  take its space. After a restart, a local file is hashed again, and an
  image from an origin is downloaded again, on its first request. See
  [`[cache]`](docs/server-configuration.md#cache).
- Cache hits are served faster. The Erlang VM's dirty I/O schedulers, which
  read cached files, again spin briefly before they sleep
  (`+sbwtdio very_short`), so a hit's reads rarely wait for a sleeping
  scheduler to wake. The other schedulers still don't spin.
- `text` log lines are no longer colored when the container runs on a
  terminal, such as with `docker run -t`. Set `[telemetry] log_colors = true`
  to color them by level.
- Concurrent requests for different sizes or formats of an image from an
  HTTP or S3 source share one download. Before, without `[cache.input]`,
  each request downloaded the original.
- The server fetches S3 credentials from a provider at startup when an S3
  source allows any bucket. Before, it fetched them at startup only for
  buckets listed under `buckets`.
- The server keeps the bytes of up to 64 recently used watermark images in
  memory, so a watermark from an origin is no longer downloaded for every
  processed image.

### Removed

- **Breaking:** `[cache.input]`, the cache for originals, and the file
  source's `copy` setting. The server now refuses to start with either, so
  remove them from `config.toml`. It doesn't delete an existing
  `[cache.input]` directory, so delete it yourself. `/stats` no longer has
  an `input` entry.
- **Breaking:** `[http] allow_debug_headers`. A request's `debug` option
  always adds the debug headers. Remove the setting from `config.toml`. With
  signed URLs, only your app can add `debug`.
- **Breaking:** `[processing] request_watermarks`. Requests may always name
  their own watermark with `wm-src64` or `wm-enc`, and its image still has to
  come from a configured source, like the main image. Remove the setting from
  `config.toml`.

### Fixed

- A server that can't listen on `[server] port` or `health_port`, such as a
  port another process uses, prints a line naming the setting and exits
  with status 1. Before, it printed a crash report and a line for each
  application it stopped.
- The server refuses to start when `[server] mount_path` has a character
  other than letters, digits, and `-._~` between its slashes, such as a
  space or `é`. Before, it started and answered every image request with
  `404`.
- A malformed request is no longer logged. Its `400` line quoted the raw
  request, so a request with a bad `Authorization` header put the token in
  the log.
- `/health/ready` answers `503` while the server's image processing
  restarts after a crash. Before, it answered `200` while every image
  request failed.
- The lines the libraries the server uses log while it starts, such as the
  CA certificates loading, follow `[telemetry] log_level` and `log_format`.
  Before, they were always text and ignored `log_level`.
- The log keeps every line the server can write. Before, it kept at most
  500 lines a second and dropped the rest without a notice.
- A log collector that reads the container's output slowly no longer delays
  requests. Before, a request could wait several seconds. Up to 10,000 lines
  can wait to be written. Lines past that are dropped, and a `notice` line
  says when dropping starts and stops. See
  [Logging](docs/server-deployment.md#logging).
- A request that chains many operations, such as a watermark in each of a
  dozen groups, no longer crashes the server. libvips ran out of stack
  rendering the chain. The image is now copied to memory once six
  operations have run since its last copy, and libvips gets 8 MB of stack,
  up from 320 KB.

### Security

- `/health/live` and `/health/ready` responses send
  `X-Content-Type-Options: nosniff`.
- The Docker image no longer trusts the `emSign ECC Root CA - G3`,
  `emSign Root CA - C1`, and `emSign ECC Root CA - C3` root certificates,
  which Mozilla removed after eMudhra issued intermediate certificates
  whose private keys are known. With them, anyone who could intercept the
  server's traffic to an origin could pose as that origin. Debian's
  `ca-certificates` package still includes some of them, so the image
  removes them itself. Servers running an earlier image still trust them.
  The fallback list the OpenTelemetry exporter uses when the system has no
  CA certificates no longer includes them either.
- Updated `plug_crypto` to 2.2.1, which fixes
  [CVE-2026-105963](https://osv.dev/EEF-CVE-2026-105963): its key
  derivation could write a secret key to the logs when given bad
  arguments. The server uses `plug_crypto` only to compare tokens, so it
  wasn't affected, but vulnerability scanners flag 2.2.0.

## [0.3.0] - 2026-10-18

### Added

- The `kernel` URL option sets the filter a group's resize uses: `nearest`,
  `linear`, `cubic`, `mitchell`, `lanczos2`, `lanczos3` (the default),
  `mks2013`, or `mks2021`. With `kernel=nearest` in the first group, a large
  JPEG or WebP source is decoded at full size, so the request takes longer
  and uses more memory. See [kernel](https://github.com/hlindset/image_pipe/blob/v0.3.0/image_pipe/docs/processing/resize.md#kernel).
- A [`priority=low`](https://github.com/hlindset/image_pipe/blob/v0.3.0/image_pipe/docs/processing/request.md#priority) request waits for
  spare capacity in the processing pool: it starts only when no normal
  request is waiting, and a normal request that finds the queue full takes
  its place. `[pool] low_priority_max_concurrency` limits how many run at
  once. It defaults to half of `max_concurrency`, rounded down, and at
  least 1. A low-priority request waits for the original to finish downloading
  before processing starts. Its processing spans in traces carry `priority`,
  and one that a full pool turned away logs at `info` instead of `error`.
- The `503` for a full processing queue or a queue timeout has a
  `Retry-After` header. Its value is `[pool] queue_timeout` converted to
  whole seconds, rounded up.
- `[processing] max_blur_work` limits `blur` and `progressive-blur`: the
  pixels of the image being blurred, times the square of the sigma, can't
  exceed it. A blur over the limit fails with `422`.
- `dns_cache = false` in a `[sources.<name>]` table turns off the HTTP
  source's DNS cache, for a server whose DNS resolver already caches and
  whose TTLs should apply exactly.
- `[telemetry] log_stages = true` also logs a line for each stage of each
  request, such as each cache lookup, the decode, and the encode. It needs
  `log_requests` on.
- `[telemetry] log_format` writes each log line as one JSON object:
  `"json"`, or `"gcp"`, `"datadog"`, or `"elastic"` for those log collectors'
  field names. The default is `"text"`. A request's fields are under an
  `image_pipe` key.
- The request span carries the method and path as `http.request.method`,
  `url.path`, and `url.query`.
- The server logs a warning, once per directory, when the `image_pipe`
  directory in `TMPDIR` can't be used to stage originals, so they are held
  in memory instead. The request's log line then has `staging=memory` and
  `staging_reason`.
- A file system cache logs at `info` when it claims its cache root, naming
  the host. A server that refused its cache root, because another server
  used it, logs at `info` when it takes the root over and requests use the
  cache again.
- An S3 source logs a warning when a fetch of its provider's credentials
  fails, naming the bucket and the provider module, and logs at `info` when a
  fetch succeeds again.

### Changed

- **Breaking:** `[telemetry] log_requests` defaults to `true`, and logs one
  line per image request instead of one per stage: the method, path,
  status, duration, and bytes sent, then the cache outcome, source, sizes,
  operations, and stage timings. A `5xx`, or a response that failed partway
  through sending, logs at `error`, and a `4xx`, a result that didn't come
  out as requested, or a failed cache read at `warning`. Failed and dropped
  cache writes log their own `warning` lines, `image_pipe cache write` and
  `image_pipe cache stage`, with the error category. The path is as sent,
  with a presigned source URL's credentials, such as an `X-Amz-Signature`
  value, redacted. Set `log_stages = true` to also get the stage lines that
  `log_requests = true` gave before, or `log_requests = false` for no
  request lines.
- **Breaking:** The server no longer accepts HTTP/2 over plain HTTP (h2c,
  HTTP/2 with prior knowledge). Configure the load balancer or proxy in front
  of the server to connect with HTTP/1.1. Before, an HTTP/2 request that
  took longer than `[server] read_timeout` lost its response, along with
  every other request on its connection.
- **Breaking:** The server fails at startup when a preset in
  `[processing.presets]` or `[processing] request_defaults` sets options
  that can't be combined, such as `anchor=top/detect=face` or
  `q=80/autoquality=50`, names a `wm` that isn't in
  `[processing.watermarks]`, or uses `wm-src64` or `wm-enc` without
  `request_watermarks = true`. Requests using them failed with `400` unless
  the URL replaced the conflicting options. Remove one of the conflicting options, or the watermark option.
- **Breaking:** A `blur` or `progressive-blur` over the default
  `max_blur_work`, 4,000,000,000,000, fails with `422`. `blur=1000` on a
  10-megapixel photo took about 7 seconds and now fails. Raise
  `[processing] max_blur_work` to allow larger blurs.
- AVIF's default quality is 56, down from 63. Files are about 18% smaller.
  The median image scores 78 instead of 82 on
  [SSIMULACRA2](https://github.com/hlindset/image_pipe/blob/v0.3.0/image_pipe/docs/choosing-an-autoquality-target.md#choosing-a-target),
  close to the JPEG default's 77. To keep 63, set
  `format_quality = { avif = 63 }` under `[processing]`.
- A response's cache key and `ETag` no longer depend on the quality and
  encoder settings of other formats. Changing the AVIF quality or
  `avif_options` under `[processing]` leaves them unchanged for WebP responses and
  for requests with a `format`, such as `format=jpeg`. A response without
  `format`, for a client that accepts neither AVIF nor WebP, still depends
  on every format's settings. After upgrading, cached image responses miss
  once and clients download each image again once.
- A request with `pad=0` gets the cache key and `ETag` of the same request
  without `pad`, and a `gradient` or `progressive-blur` that starts or stops
  at `-0.0` gets those of one at `0`. Cached copies of such requests miss
  once after an upgrade.
- Cached `output=blurhash`, `output=lqip-css`, and `output=info` responses
  that include a placeholder miss once after upgrading, since placeholders of
  transparent images changed.
- A server without `[cache]` keeps the content hashes of up to 10,000 local
  files in memory, so a request for an unchanged file checks its size and
  timestamps instead of reading and hashing it. For a 5.5 MB PNG this saves
  about 3 ms per request. For a remote original, a request with
  `If-None-Match` gets `304` without contacting the origin while the
  origin's cache lifetime lasts. Cache lookup stage lines and spans report
  these lookups in the `memory` pool.
- An HTTP source keeps the addresses a hostname resolves to for 10 seconds,
  so a busy origin is no longer looked up before every fetch. The addresses
  are still checked against `address_policy` on every fetch. When none of
  the addresses accepts a connection or answers in time, the source looks
  the hostname up again and tries once more if the answer changed.
- `blur` and `sharpen` buffer the image in memory before filtering it.
  `sharpen=10/w=8000/h=8000/enlarge` took 14 s and now takes under 1 s. A
  request with `blur` or `sharpen` holds one copy of the image in memory at
  that point.
- A watermark on an image with a color profile is about 5 ms faster when the
  output is sRGB, which is the case with the default `profile=strip` and with
  `profile=srgb`. Partly transparent watermark pixels over colors outside
  sRGB, such as on a Display P3 photo, blend slightly differently.
- A `format-q` entry for `png` applies only when PNG has a palette, like `q`.
  Before, a URL with one and no palette failed with `400`, even when the
  response wasn't PNG, and one in `request_defaults` or a preset made every
  request fail.
- A `detect`, `anchor=smart`, or `anchor=smart-face` crop whose box covers
  the whole image, such as `crop=8000,8000/detect=face` on a smaller image,
  runs no detection. Before, with a failing detector the response wasn't
  stored, or failed with `500` under `detector_required = true`.
- A server error (`5xx`), such as a `502` for a failing origin, gets
  `Cache-Control: no-store` in place of `max-age=0, private,
  must-revalidate`, so a CDN doesn't keep it.
- Log lines start with the date and time, as in
  `2026-10-14 19:55:23.967 request_id=abc [info] ...`.
- Uses `image_pipe`
  [0.3.0](https://github.com/hlindset/image_pipe/blob/v0.3.0/image_pipe/CHANGELOG.md).

### Fixed

- `autoquality` scored images with transparency as if they were shown on
  black, so changes at their edges and in their transparency didn't count,
  and transparent margins raised the score. A logo could get AVIF quality 22
  where it needed 31. It now scores the visible area against both a dark and
  a light background, and keeps the lower score. Images with transparency
  can get a higher quality and larger files.
- `autoquality` together with `max-bytes` could ship a lower quality than
  `max-bytes` alone. The byte budget now gets its own encodes.
- Content-aware crops with `detect` or `anchor=smart-face` for a small
  output detected on the resized image. `w=64/h=64/fit=cover` on a
  6000×4000 source gave the detector 96×64 pixels, so small faces and
  objects were missed. Detection now gets at least 640 pixels on the long
  edge, or the whole source when it's smaller, and such requests decode at
  that size.
- The detector warmup gave up after three failed attempts, about a third of
  a second, so with `detector_required = true` detection requests answered
  `503` until a restart. It now retries, at most a minute apart, until the
  models load, and logs at `info` when they do.
- Detection requests that arrived before the face or object model had
  loaded, such as during startup warmup, each downloaded and loaded the
  model. They now wait for one load.
- With `detector_required = true`, an `anchor=smart-face` crop called the
  detector before its models were ready, so it could download a model during
  the request. Until the face model is ready, such a crop uses attention
  cropping without calling the detector, and the response isn't stored
  while the face model can still become ready.
- The `image_pipe.transform.detect.model` trace span and its log line report
  an unavailable model as `unavailable` instead of `error`.
- A `crop` or `region` followed by a resize could give a different size for
  a JPEG source than for the same image as PNG. `crop=101,1500/w=50` gave
  50×750 instead of 50×743. The size is now the same for every source
  format, in the image and in `output=info`.
- A `region` whose width or height came to less than half a pixel, such as
  `region=0,0,0.3,1`, failed with `500`. It now keeps one pixel.
- A `region` that started inside the last pixel column or row, such as
  `region=99.99pct,0,10,10`, failed with `400`. It now starts at the last
  pixel.
- A large `pixelate` block size, such as `pixelate=2000` on a 4000×2667
  JPEG, failed with `415`. It now works.
- An `extend-offset` that landed exactly on a half pixel, such as
  `extend-offset=0,1.25` with `dpr=2`, placed the image 1 pixel off. It now
  rounds ties to even, as crops, watermarks, and padding do.
- Watermarks, `bg`, `colorize` over transparent areas, JPEG output of an
  image with transparency, and resizing or rotating an image with
  transparency could make a color one level darker than the exact result.
  These now round to the nearest level.
- `format=png` with `q`, from the URL, `request_defaults`, or a preset,
  failed with `400` when PNG had no palette. PNG without a palette now
  ignores `q`.
- `png-options` with `bitdepth:2` or `bitdepth:4` wrote wrong gray levels,
  and a `bitdepth` of `1`, `2`, or `4` on a result with alpha or color
  failed with `500`. Grayscale results without alpha now keep their gray
  levels, and other results without a palette encode at 8 bits.
- `png-options=bitdepth:16` scaled 8-bit color by 256 instead of 257, so
  only white reached 65535.
- `output=blurhash` and `output=lqip-css` rendered transparency on black.
  They now render it on white, unless `bg` sets a background, matching the
  JPEG the same URL returns.
- `output=info` reported `dpr` from before the scale-down to the result
  limits, so dividing its width by `dpr` gave less than the CSS width.
- `output=info` reported a `result` size for a URL whose image request fails
  with `422` because it exceeds `max_intermediate_pixels`. It now fails with
  `422` too.
- `output=info` with `format=webp`, on a server whose result limits are
  above 16,383 pixels, shared its cache entry and `ETag` with other formats.
- An SVG source with `fit=stretch` and one axis, such as `w=480/fit=stretch`,
  or with only `min-w` or `min-h`, stayed at its own size instead of
  rendering at the requested size.
- An SVG source ignored `page`, so `page=1` answered `200` with the only
  image. A `page` past `0` now fails with `422`.
- A request that reached `[pool] processing_timeout` while its source was
  still downloading failed with `500` or got no response. It now fails with
  `503`.
- A request for another variant of a source that was still downloading, such
  as `w=50` while `w=100` was fetching the same image, could fail with `504`.
  It now waits only for the download.
- A request to an `http` or `s3` source that waited past `pool_timeout` for
  a free connection got no response, and the connection stayed open. Such
  requests now fail with `504`.
- An `http` source could run past `fetch_timeout` while looking up the host
  name, or by waiting for a response at each of a name's addresses in turn.
  Fetches now fail with `504` at `fetch_timeout`, except that a connection
  attempt can run past it by up to `connect_timeout`.
- An `http` source URL whose query has a space or a non-ASCII character,
  such as `?a b`, is fetched with those characters percent-encoded. Before,
  the request failed with `502`.
- Conditional headers in an `http` source's `request_headers`, such as
  `if-none-match`, made the request fail when the origin answered a first
  fetch with `304`. Sources now drop `if-none-match`, `if-modified-since`,
  `if-match`, `if-unmodified-since`, and `if-range`.
- A watermark whose stored copy in the input cache was corrupt made every
  request using it fail with `415` until the copy was evicted. The copy is now
  discarded, and the next request fetches the watermark again.
- A file system cache could hold more than `max_size_bytes` on disk and not
  bring it back down, after a read or write during its startup scan, a
  crashed startup scan, or an upgrade that changed its metadata format.
- A file system cache that restarted while a write was stuck on disk for
  more than 25 seconds, as on a hung network mount, kept counting that
  write's bytes, so until the next restart it dropped more writes and
  evicted more entries than it needed to.
- A file system cache that was full and busy with other writes could keep an
  original's outdated expiry time or content identity, so requests checked
  with the origin, or downloaded the changed original, every time.
- A source's `bearer_token`, or a `container_credentials` provider's
  `auth_token`, with a line break or NUL passed the startup check, and every
  fetch from that source then failed. The server now refuses to start,
  naming the setting.
- Log lines are no longer preceded by a blank line, which log collectors
  stored as an empty entry.
- The server closed new connections well below `[server] max_connections`.
  The cap was split over up to 100 connection acceptors, and a connection
  that reached a full acceptor waited about five seconds, then was closed,
  even while the server had room. `max_connections` is now an exact cap.
- The configuration reference now gives the defaults of `format_order`,
  `webp_options.effort`, `avif_options.effort`,
  `avif_options.subsample_mode`, `svg.max_render_pixels`, and the
  `address_policy.allow_*` settings, which it left blank.

### Security

- Bandit 1.13.1 fixes two advisories:
  - An HTTP/2 client that trickled window updates could keep a stream's
    send blocked indefinitely (GHSA-69m6-wcv4-rwcf). Earlier releases were
    exposed through HTTP/2 over plain HTTP, which this release also turns
    off.
  - An HTTP/1 request target's authority wasn't validated, so a client could
    choose `conn.host` and `conn.port` (GHSA-v53v-9hvg-37jf). The server
    doesn't read either.

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

[Unreleased]: https://github.com/hlindset/image_pipe/compare/image_pipe_server-v0.3.0...HEAD
[0.3.0]: https://github.com/hlindset/image_pipe/compare/image_pipe_server-v0.2.0...image_pipe_server-v0.3.0
[0.2.0]: https://github.com/hlindset/image_pipe/compare/image_pipe_server-v0.1.0...image_pipe_server-v0.2.0
[0.1.0]: https://github.com/hlindset/image_pipe/releases/tag/image_pipe_server-v0.1.0
