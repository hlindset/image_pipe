# Changelog

This changelog follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).
Releases use [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Changed

- PNG output is 15-35% smaller and encodes 7-29% faster. A PNG that isn't
  a palette image is saved at zlib compression 3, with the `paeth` row
  filter unless it is grayscale at `bitdepth` `1`, `2`, or `4`, instead of
  compression 6 with no filter. A `filter` set in
  [`png-options`](docs/processing/output.md#png-options) still wins.
- JPEG output is up to 18% smaller, with the same pixels. The encoder
  optimizes the entropy coding for each image, which adds 1 to 4 ms to an
  encode of 1-2 megapixels.
- A FileSystem cache's startup scan is several times faster and uses a
  quarter of the memory. On a 12-core machine, a cache of 1M entries is
  scanned in 3.5 s instead of 19 s, with a memory peak of 0.6 GB instead of
  2.4 GB. The first scan after an upgrade that changes the metadata format
  takes 28 s instead of 320 s.
- The startup scan deletes [leftover files](docs/cache.md#leftover-files)
  while it counts the entries, so `:counting?` in the cache's
  [usage](docs/cache.md#usage-and-hit-rate) stays `true` until the scan
  finishes.
- A cache hit whose metadata is in memory no longer opens its body before
  sending it, which makes a warm `GET` about 15% faster and a `HEAD` about
  40% faster. A body deleted after the lookup is noticed when the response
  is sent, before any headers, and the image is generated again.

### Fixed

- A response from a source configured to deny storage gets
  `Cache-Control: no-store` even when an earlier Plug set `Cache-Control`
  or `Set-Cookie`. Before, it kept the earlier Plug's caching headers and
  sent no `no-store`.
- Identical requests for a processed image share one render while up to
  4,096 other images are processing or waiting for a turn. Before, past 64
  such images, each identical request rendered its own copy: a cold burst
  of 160 thumbnails, each requested 3 times, made 342 renders instead of
  160 and took twice as long.
- A streamed image gives back its processing turn when its encode ends,
  instead of when the client has read the last byte. The part of the
  response the client hasn't read yet waits in memory, up to 4 MB, and the
  rest in a file in the system temporary directory, which needs room for
  the largest responses slow clients read at once (see
  [slow clients](docs/deployment.md#slow-clients)). Before, a few slow
  clients downloading large images could hold every turn, so other requests
  got `503`, and identical requests waited for the slowest client.
  When the system temporary directory is private to ImagePipe's user and
  has room, `processing_timeout` no longer counts the client's download, so
  a slow download of a large image is no longer cut short at the deadline.
- On a CMYK source without a usable embedded ICC profile, colors from the
  request, such as `bg`, `colorize` and `duotone`, come out as requested.
  Before, `pad=5/bg=00ff00` painted `(192, 208, 11)` instead of
  `(0, 255, 0)`, and a progressive blur or several blur groups could
  crash the BEAM.
- An HTTP source that redirects to a protocol-relative `Location` on the
  same host, such as `//images.example.com/moved.jpg`, keeps its
  configured `auth`, `aws_sigv4` and headers on the next request. Before,
  ImagePipe treated it as another origin and dropped them, so the origin
  usually answered `401` or `403`.
- A file source and the filesystem cache treat a path under their root
  that follows more than 40 symlinks as unsafe. A file source request for
  such a path fails as a denied path (`404`). Before, some symlink loops
  inside the root, such as one that passes through a link to `.`, hung the
  request, or the cache's startup check or first lookup, and grew memory
  without bound.
- With `stages: true`, the default Logger logs `:processing_error` on
  `[:source, :watermark]` and `[:transform, :execute]`, and `:error` on
  `[:transform, :operation]`, at `:warning`. Before, it logged them at the
  configured level.
- The tracer ends an `image_pipe.http.client` span with an error status
  when a step of the HTTP request raises an exception. Before, the span
  stayed open and the trace lacked it.
- An HTTP or S3 source whose response declares a `Content-Length` over
  `max_body_bytes` fails as soon as the headers arrive. Before, the body
  kept arriving into memory until ImagePipe read past the limit.
- The filesystem cache deletes an entry's temporary metadata file when
  writing it fails, such as on a full disk. Before, the file stayed until
  the daily sweep.
- An AVIF whose major brand is a generic HEIF brand, such as `mif1`, with
  `avif` among its compatible brands is detected as AVIF. Before, it was
  detected as HEIF, so `skip_processing_formats: [:avif]` didn't pass it
  through and `info` reported `heif`.
- A `src` or `src64` source that isn't valid UTF-8 fails with `400`
  `invalid source` before the source is fetched, as a watermark source
  does.
  Before, it reached the source and usually failed with `404`.
- In telemetry, a query part without a value, such as `&token` in a
  source URL or in a request's query string, is replaced with `REDACTED`.
  Before, it was kept, so a bare token that an origin authorizes with
  appeared in `:source_url`, the logged path, and traces.

## [0.4.0] - 2026-10-23

### Added

- A `[:source, :svg_parse]` span wraps parsing an SVG watermark, and names
  the limit that rejected it, such as `:svg_bytes`. The default Logger logs
  it with `stages: true`.
- The `[:parse]` and `[:request]` stops and the request summary carry
  `:source_url`, the request's source as ImagePipe parsed it, decoded from
  `src64` or decrypted from `enc`, and `:watermark_source_urls`, each
  group's watermark source. Each query value, such as an
  `X-Amz-Signature`, and a URL's user name and password are replaced with
  `REDACTED`. The default Logger writes them as `source_url=` and
  `watermark_source_url=` fields, and the tracer records them on the
  `image_pipe.parse` and `image_pipe.request` spans. See
  [`[:parse]`](docs/telemetry-events.md#parse).
- `ImagePipe.cache_stats/1` reports the cache's stored bytes and entries,
  its size cap, its hits, misses, and failed reads and writes since start,
  and the entries it keeps in memory, or `refused: true` when another node
  owns its root. It also reports how many originals the instance
  remembers. A cache that doesn't report its size within a second has
  `available: false`. See
  [Usage and hit rate](docs/cache.md#usage-and-hit-rate).
- `max_remembered_originals` sets how many originals an instance remembers
  in memory: a local file's hash, or an origin image's cache headers. It
  defaults to one for each 50 KB of `:cache`'s `:max_size_bytes`, at least
  10,000 and at most 200,000, and forgets originals that weren't used
  recently first. A remembered file isn't read and hashed again while it's
  unchanged, and the processed images of a remembered origin image are
  served without downloading it again. Each takes about 1 KB for a local
  file and about 1.4 KB for an image from an origin.
- The `X-ImagePipe-Source-Progressive` debug header says whether a JPEG
  original is progressive. See
  [Debug response headers](docs/debug_headers.md).
- `ImagePipe.Source.HTTP` and `ImagePipe.Source.S3` take `pool_size`, the
  maximum number of open connections to each origin address or S3 endpoint.
  It defaults to `50`, the limit that applied before. Over HTTP/1.1, raise it
  when more downloads from one origin run at once, so they don't wait for a
  free connection and fail with `504` after `pool_timeout`.
- `max_search_pixels` limits the pixels that `autoquality` and `max-bytes`
  encode in one request, 100,000,000 by default. A search stops early when
  the next quality would pass it. On a 40-megapixel AVIF or WebP result it
  tries two qualities, plus up to two encodes to deliver one, where a search
  with both options could encode up to 11 times and take up to 45 seconds.
  `:infinity` turns the limit off. The `[:encode, :search]` stop event
  carries `:pixel_limited`, and its `:limiting_factor` can be
  `:search_pixels`. See
  [Limiting quality search work](docs/deployment.md#limiting-quality-search-work).

### Changed

- A cache whose `root` can't be created or written logs an error at
  startup that names the root and the reason, such as `permission denied`,
  and says images are served without being stored. Before, it logged a
  warning that it "could not claim" the root.
- **Breaking:** The `:error` metadata of `[:debug, :collect, :error]` is
  the module of the raised exception, such as `RuntimeError`, instead of
  always `:error`. Handlers that match on `error: :error` must match the
  module.
- **Breaking:** The HTTP source refuses origins in `192.0.0.0/24`,
  `192.88.99.0/24`, and `2001::/23`, which are reserved for protocol use
  (the last includes Teredo tunnel addresses). They were treated as
  public. To reach one, set `:allow_reserved` or list its range in
  `:allow` in the source's `:address_policy`.
- The HTTP source allows an IPv4 origin reached through a NAT64 gateway
  from an IPv6-only network, at an address such as `64:ff9b::93.184.216.34`,
  when the IPv4 address is public. Before, every such address was refused.
  An IPv4 range in `:allow` also matches the NAT64 form of its addresses.
- **Breaking:** `ImagePipe.Source.Path` has only a `segments` field. Its
  `scheme` field was always `nil` in a path an adapter receives, so remove
  `scheme:` from any pattern that matches the struct.
- **Breaking:** `storage_inputs` is now `vary_on`, and the
  `ImagePipe.run/4` option `request_inputs` is now `vary_values`. Rename
  them in your configuration and calls.
- **Breaking:** An `ImagePipe.Plug` mount without `:keys` raises
  `ArgumentError` on every request unless its configuration sets
  `allow_unsigned: true`. Serve public traffic with signed URLs, and set
  `allow_unsigned: true` only for a mount that nothing outside a private
  network can reach. An instance with `allow_unsigned: true` and no `:keys`
  logs a warning when it starts. Running a plan with `ImagePipe.run/4` or
  `ImagePipe.write/5` needs neither. See [Signing URLs](docs/signing-urls.md).
- **Breaking:** The `[:request]` event's `:path`, the request summary's
  path, and the `url.path` trace attribute end at the source: the first
  `src`, `src64`, or `enc` segment is followed by `REDACTED`, and the rest
  of the path and the query string are left out, as in
  `/w=200/src/REDACTED`. Each `wm-src64=` value is `REDACTED` too,
  including the rest of a standard-base64 value split at its `/`. A path
  without a source keeps its query string, and `url.query`, with every
  value replaced with `REDACTED`. Read the source from the new
  `:source_url` instead. Before, the path was as sent, with only the values
  of a fixed list of credential parameters redacted, so values such as a
  `token` or `api_key` were logged.
- **Breaking:** `enc` and `wm-enc=` sources are now visible to telemetry
  handlers, logs, and traces, decrypted, in `:source_url` and
  `:watermark_source_urls`. Source encryption hides a source from whoever
  requests the image, not from whoever reads your telemetry. If you send
  telemetry somewhere you don't want your source URLs, drop these keys in
  your handler.
- A request with `crop=100pct,100pct` and no `crop-ratio`, or with
  `region=0,0,100pct,100pct`, is processed as the same request without them,
  since they keep the whole image, and gets its cache key and ETag. The
  `[:request, :ignored_options]` event, and with `debug` the
  `X-ImagePipe-Ignored-Options` header, list the crop or region and the
  options only it made useful, such as `anchor`.
- Requests that use `autoquality` or `max-bytes` have new ETags, so
  clients and CDNs download them again once after the upgrade.
- A filesystem cache misses once after upgrading for every image it stored
  before, and its startup sweep deletes those entries.
- A filesystem cache's startup sweep reads its metadata files only when the
  cache was last checked by an ImagePipe version with another metadata
  format, so restarting a cache with many entries reads far less from disk.
  The cache records the format it checked in `.metadata-version` in its
  `root`. The first start after this upgrade still reads every metadata
  file.
- **Breaking:** `:max_blur_work` limits the total work of all `blur`,
  `progressive-blur`, and `sharpen` steps in a request, across all its
  groups, instead of each blur on its own. Each step counts the pixels of
  its image times (sigma² + 10,000), so a single blur may use a slightly
  smaller sigma than before (up to 624 on a 10-megapixel image). A
  progressive blur counts (2 × sigma² + 50,000), so it allows a smaller
  sigma (up to 418 on a 10-megapixel image), and the default limit refuses
  any progressive blur on a 100-megapixel image. A request over the limit
  fails with `422` and the message "blur and sharpen work exceeds the
  limit". Raise the limit if your requests chain large blurs, or set it to
  `:infinity` to turn it off. See
  [Limiting blur and sharpen work](docs/deployment.md#limiting-blur-and-sharpen-work).
- When a cache with `max_size_bytes` is full, it keeps images made from
  progressive JPEGs longer, since they cost more to render again than
  images from baseline JPEGs of the same size. Their `:estimated_cost_us`
  on `[:cache, :write]` is higher.
- A `detect` or `anchor=smart-face` crop of a large JPEG, WebP, or SVG with
  a small crop box decodes at a reduced size. Detection's minimum of 640
  pixels on the long edge applies to the whole image the detector searches,
  not to the crop box. A crop box that covers the whole image runs no
  detection, so without a `fit=cover` resize after it, it decodes as small
  as the output allows.
- Concurrent requests for one new original share its download in more
  configurations, and no longer wait for a download they would repeat. See
  [request coalescing](docs/caching-and-freshness.md#request-coalescing).
  - Requests for an original from an HTTP or S3 source download it once,
    whatever size or format they ask for, with or without a cache, while
    up to 4,096 originals are being fetched at once. Before, without an
    originals cache, requests for the same processed image waited for the
    first download and then downloaded it again, and requests for other
    sizes each downloaded it themselves.
  - Requests for an original from a source with caching turned off
    download it at the same time instead of one after another.
  - When the original may not be stored, waiting requests start their own
    downloads as soon as the origin responds, instead of after the first
    download finishes.
- `gradient` on an 8-bit image takes less time, since it blends in one pass.
  A blended color can differ from before by one level.
- `autoquality` on an image with transparency takes less time. Each quality
  it tries is scored against a dark and a light background at the same time
  instead of one after the other.
- `[:cache, :coordination]` events for `:source` come only from requests
  that download an original, check a remote original with its origin, read
  a local file, or wait for another request doing so. No event is emitted
  for an original from a source with `internal_cache: :disabled`, or for a
  local file from an immutable source. `:source` can report `:bypass` with
  `reason: :not_stored` when the original may not be stored.
- **Breaking:** `:presets` must be a map. Change a list of
  `{name, fragment}` pairs to a map such as `%{"card" => "w=400"}`.
- **Breaking:** An `ImagePipe.Source.S3.CredentialProvider`'s
  `fetch_credentials/1` takes only the provider's options, without the
  bucket, and `ImagePipe.Source.S3.CredentialWarmup` has no `:scope`
  option. Credentials are now cached per provider and options and shared
  by every bucket. Remove the bucket argument from `fetch_credentials`,
  give buckets that need different credentials different provider options
  under `:buckets`, and remove `scope:` from each warmup, keeping one per
  provider and options.
- A WebP original scaled down a lot matches the same image as a JPEG or PNG
  original. Like a JPEG, it's decoded at 1/2, 1/4, or 1/8 of its size, the
  smallest that stays at or above the requested size, and the resize does the
  rest. Before, it was decoded straight at the requested size, so a thumbnail
  under about 200 pixels wide differed visibly from the JPEG or PNG one.
- A cache's `max_size_bytes` counts each entry's body rounded up to whole
  4 KiB blocks, plus one block for its metadata file, instead of the body
  alone, so many tiny entries, such as BlurHash or LQIP responses, can't
  take far more disk than the cap. A cache whose entries now count past its
  cap evicts down to it at startup after the upgrade.
- When a cache with `max_size_bytes` is full, a new processed image that
  many requests want is kept sooner. The cache now counts each request that
  misses it, including requests that wait for another request's copy,
  instead of counting how often it's written.
- A cache with `max_size_bytes` uses less than half the memory to track
  its entries: about 175 bytes per stored image instead of over 400, which
  saves at least 45 MB for a cache of 200,000 images.
- The default Logger shows a coordination event's reason after its result,
  as in `bypass (deadline)`. It logs a `:bypass` with reason `:not_stored`
  at its base level.
- An HTTP source whose host doesn't resolve fails with
  `{:source, :unresolved_host}` in logs and telemetry instead of
  `{:source, :denied_address}`. It still answers `404`.
- `autoquality` with `max-bytes` scores only the quality it delivers, not
  each quality it tries to fit the byte limit, and reuses the encodes
  `autoquality` already made to narrow that search, so such a request takes
  less time. `[:encode, :search, :probe]` spans of the `:cap` phase no
  longer carry `:score`.
- The hash and timestamps kept for each local file, and the cache headers
  kept for each origin's image, are held in memory instead of in the
  processed-image cache, for up to `max_remembered_originals` originals.
  They no longer take its space or get evicted with its images. After a
  restart, a local file is hashed again, and an image from an origin is
  downloaded again, on its first request. Remembering them uses none of the
  cache's 64 concurrent writes, so it never causes a processed image's
  write to be dropped.
- A cache with `max_size_bytes` deletes a rejected write without syncing it
  to disk. Once the popular images don't fit in the cache, that saves most
  of its write I/O. A write that waits more than 5 seconds to be kept or
  rejected is dropped and reported as `error: :admission_timeout`.
  `[:cache, :admission]` is now emitted before the sync, and its
  `:victim_count` counts the entries the write was compared with.
- `[:transform, :detect, :skipped]` is also emitted when `anchor=smart-face`
  uses attention because `detector_required` is set and the face model isn't
  loaded yet (`result: :not_ready`) or the detector has no face model
  (`result: :unavailable`). The default Logger logs both at `warning`.
- When an HTTP source follows a redirect to another host, port, or scheme,
  the request no longer carries the headers or credentials set in
  `req_options`, such as an API key. Before, only `authorization`,
  `proxy-authorization`, and `cookie` were dropped. A redirect from `https`
  to `http`, or to a URL with a user name or password, now fails with
  `502`.
- A `blur`, `progressive-blur`, or `sharpen` result is copied to memory
  before a later resize or a step that rereads pixels (`rotate`, `trim`,
  `pixelate`, `blur`, `progressive-blur`, `sharpen`, or a crop with
  `anchor=smart` or `detect`). Before, each of those steps recomputed the
  blur for every region it read, so a request could take many times the
  CPU that `max_blur_work` allows. A `rotate` by an angle other than a
  quarter turn is copied the same way before such a step.
- A request for a cached image from a local file no longer opens the file
  while its size and timestamps are unchanged.
- A cache with `max_size_bytes` keeps its counts of the requests that miss
  each image in 4 MB per 50 GB of `max_size_bytes`, allocated when it
  starts. Before, a busy 50 GB cache's counts grew to about 70 MB and slowed
  its garbage collection.
- A downloaded original is written to disk in 64 KiB batches instead of one
  write per network read, which takes less CPU for a large original.
- With `format=jpeg`, `pad` and `extend` fill with white directly, instead
  of adding transparency that the encoder then flattens onto white. This
  takes less time to encode and gives the same image, unless
  `:max_result_width`, `:max_result_height`, or `:max_result_pixels` then
  scale it down. Then pixels next to the padding can differ.
- A `detect` or `anchor=smart-face` request decodes and buffers less when no
  detection will run:
  - The detector isn't available for any of the requested classes.
  - With `detector_required: true`, the detector's face model isn't ready
    yet, and the request uses `anchor=smart-face`.
  - The image already has the `fit=cover` target's aspect ratio, so the crop
    can't move.

  When the crop falls back to attention cropping, it runs on the smaller
  decode, so its result can differ slightly.
- Pixels of a source whose embedded RGB profile matches sRGB to within 1
  level are used as sRGB, without converting them through the profile, for
  the output, for placeholders, and for `bg`, `gray`, `bitonal`,
  `monochrome`, `duotone`, `colorize`, `gradient`, `trim`, and `wm`. The
  output still embeds the profile with `profile=preserve`. With the libvips
  operation cache off, this saves about 7 ms on a small JPEG resize and up
  to about 220 ms on a large `trim` request. Some pixels can differ from
  before by 1 out of 255.
- The `[:request]` event's `:path`, and the request line and the
  `url.path` trace attribute that come from it, include the path that
  `ImagePipe.Plug` is mounted at, such as `/images` for
  `forward "/images", ImagePipe.Plug`. Before, the mount path was left out.
- A `FileSystem` cache keeps the metadata of recently served entries in
  memory, so a repeated hit reads only the body file from disk. It takes
  about 36 MB for a 1 GB cache, and at most about 90 MB unless
  `max_remembered_entries` sets the number of entries. See
  [Cache process and restarts](docs/cache.md#cache-process-and-restarts).
- A second instance whose cache `root` another instance in the VM already
  uses raises `ArgumentError` naming the root when it starts. Before, its
  start failed with `{:already_started, pid}`.
- The cache, downloads, and decoding no longer queue their file operations
  behind the Erlang VM's single file-server process.
- An instance keeps the bytes of up to 64 recently used watermark images in
  memory, so a watermark from an origin is no longer downloaded for every
  processed image. See [What is stored](docs/cache.md#what-is-stored).
- The processing pool's `max_queue` defaults to 1,024 instead of 64, so a
  burst of quick requests waits for a turn instead of answering `503`. See
  [choosing values](docs/processing-controls.md#choosing-values).
- With `meta=strip`, a JPEG, WebP, or AVIF image at 72 dpi no longer
  carries an EXIF block, so it's about 190 bytes smaller. An image at
  another density, set by the `dpi` URL option or the `stripped_dpi`
  setting, keeps an EXIF block with only the density. PNG still stores its
  density in `pHYs`.

### Removed

- **Breaking:** The originals cache: the `input_cache` option, and the file
  source's `copy` option, which kept copies of local files in it. Remove
  them from your configuration, and delete the originals cache's directory.
  The `[:cache, :input]` event and the request summary's `:input_cache`
  field are gone, and `[:cache, :sweep]` no longer reports `:pins`.
- **Breaking:** The `ImagePipe.Plug` option `allow_debug_headers`. A
  request's `debug` option always adds the debug headers. Remove the option
  from your configuration. With signed URLs, only your app can add `debug`.
- **Breaking:** The `ImagePipe.config/1` option `request_watermarks`.
  Requests may always name their own watermark with `wm-src64` or `wm-enc`,
  and its image still has to come from a configured source, like the main
  image. Remove the option from your configuration.
- **Breaking:** `max_preset_lookups`. A request may look up any number of
  presets. Remove the option from your configuration. `ImagePipe.run/4`
  no longer returns `{:preset, :too_many_presets}`, and `[:preset, :lookup]`
  no longer reports that reason.
- **Breaking:** The instance option `mounts:`, and `mount:` on
  `ImagePipe.Plug` and `ImagePipe.url_config/2`, which is now
  `ImagePipe.url_config/1`. An instance checks URLs against its own URL
  settings only. To serve URLs with different keys, such as signed and
  unsigned URLs, start an instance for each, and mount it or build its URLs
  by its name. Instances that use caches each need their own cache roots.

### Fixed

- A `debug` response from a configuration without a cache leaves out
  `X-ImagePipe-Cache-Key`, as documented. Before, it carried a key that
  nothing could be stored under.
- When a later preset or URL option unsets or replaces a value from a
  preset or the request defaults, the value that one replaced still
  applies. With
  request defaults of `format-q=avif:50` and a preset `q80` defined as
  `q=80`, `/preset=q80/q=unset` encodes AVIF at 50. A preset that names
  other presets gives the same result as listing them in the URL. Requests
  that hit these cases get new cache keys and ETags. See
  [clearing inherited values](docs/presets.md#clearing-inherited-values).
- A request that uses a preset your `:preset_lookup` returns, naming a
  watermark the configuration doesn't define, or carrying a `wm-enc` token
  that no key in `:source_encryption_keys` decrypts, answers `500`, and
  `ImagePipe.run/4` returns `{:preset, :invalid_definition}`, like other
  invalid stored presets. Before, it failed with `400` or `404`, as if the
  requester had made a mistake.
- The daily sweep of a filesystem cache's leftover files keeps running after
  one of the cache's processes restarts, and after a sweep fails. Before, it
  stopped until ImagePipe restarted.
- The request summary and the default Logger's request line carry `:reason`
  for a `403` invalid signature, a `400` for a signed URL sent to a mount
  without signing keys, a `410` expired URL, and a `404` concealed source
  that doesn't decrypt. Before, these lines had no reason.
- A crash report from a streaming response, or from
  `ImagePipe.Source.S3.CredentialWarmup`, no longer prints the configured
  origin credentials, such as S3 keys and authorization headers.
- A request path with bytes that aren't valid UTF-8 no longer makes the
  telemetry path invalid UTF-8. They become `U+FFFD`.
- `ImagePipe.config/1` raises a duplicate-option error for an option given
  more than once. Before, it raised an unknown-option error for it.
- Requests that differ only in the header or cookie values named in
  `vary_on` share one download of their original and one remembered
  original. Only the processed images differ. A new cachebuster still
  downloads the original again.
- A preset or `:request_defaults` with a `wm-enc` token that the
  `:source_encryption_keys` can't decrypt raises `ArgumentError` when
  ImagePipe starts. Before, the configuration was accepted and every request
  using the token failed with `404`.
- A preset with `wm-enc=unset` no longer needs `:source_encryption_keys`.
- The request defaults apply to a URL's first group even when that group
  holds only `unset` options. Before, they moved to the next group, so
  `w=unset/-/blur=2` with a default `w=200` was still resized to 200
  pixels wide.
- A cached image whose delivery failed after its headers were sent logs its
  request line at `error`, with status `200`. Before, the line had no status
  and logged at `warning`.
- A request that stopped waiting for another request's download of an
  original, just as that download finished, no longer keeps the original
  locked, even when the server takes more than 5 seconds to respond. Later
  requests for that original waited behind the lock until the process that
  served the request exited.
- An `enlarge` or a `kernel=nearest` resize of an image with an EXIF
  orientation, `rotate`, or `flip` now gives the same pixels as rotating or
  flipping first and then resizing. Before, enlarged pixels could be off by
  a fraction of a pixel, and a `kernel=nearest` downscale picked different
  source pixels.
- An image delivered in sRGB without a color profile, with its metadata
  kept, has the EXIF `ColorSpace` tag set to sRGB when the original has the
  tag. Before, the tag said Uncalibrated.
- An image decoded while its original downloads no longer waits behind
  newer requests for its encode. The encode's turn in the processing pool
  goes ahead of waiting requests and keeps the deadline of its first turn.
  Before, it queued at the back and could fail with a `503` after its
  decode had finished.
- An image whose EXIF date fields aren't plain numbers (such as
  `2024:01:01 02+02:00:00`) or aren't stored as text no longer fails with
  a `500` when metadata is stripped. All of its metadata is removed,
  including the copyright and artist that `keep_copyright` would keep.
- A watermark with an opacity below `1` blends with the image at its exact
  faded alpha. Before, the faded alpha was rounded to a whole level first,
  so a watermark's edges or faint areas could be off by one level.
- An S3 credential fetch from a provider that hangs fails after 30 seconds,
  and the next request fetches again. Before, a hung fetch held up every
  request for those credentials until the server restarted.
- An HTTP source fetch that runs out of `fetch_timeout` while waiting for a
  pooled connection reports `:receive_timeout` in logs and telemetry
  instead of `:pool_timeout`. When the source's host resolves to several
  addresses, a fetch no longer tries the next one with less than 100 ms of
  `fetch_timeout` left.
- A request with `format=webp` and lossless `webp-options` no longer fails
  with `400` when it, a preset, or the request defaults set `autoquality` or
  `max-bytes`. The options are ignored, as with `format=png`.
- A preset group holding only `unset` options is kept when the preset is
  compiled, so a first group like that clears the request defaults, as the
  same groups written in the URL do. Before, the defaults applied to the
  preset's next group: `blur=unset/-/w=100` with a default `blur=3` still
  blurred. A preset with such a group, in any position, is a pipeline
  preset, so adding other options to it answers `400`.
- A `:presets` option that isn't a map with string keys, such as a string
  or `nil`, raises an `ArgumentError` that names `:presets` instead of a
  `Protocol.UndefinedError`.
- A `region` whose x or y is `0pct` gets the cache key and ETag of the same
  region written with `0`.
- A detector whose `warmup/1` raises no longer stops its `ImagePipe`
  instance. The warmup logs a warning and retries, as it does for
  `{:error, reason}`. A detector whose `available?/1` raises is skipped
  with a warning. Before, these crashes used up the instance's restart
  limit, and every later request raised. A crash report from the warmup no
  longer prints the detector's options.
- `detect=all:3`, one weight for every class, gets the cache key and ETag of
  `detect=all`, since a weight that every class shares doesn't move the
  crop.
- The request summary of a `HEAD` request that misses the cache no longer
  reports body bytes (`:bytes`, and the size in its log line), since none are
  sent.
- A request whose `src` URL holds a user name or password that isn't valid
  UTF-8 once decoded keeps its request summary log line.
- A `crop` placed by an anchor, including the default center, or by a focus
  point, followed by a resize, now lands where it would on a full-size
  decode. Before, a source decoded at a reduced size for the resize could
  place it up to one output pixel off.
- Downscaling a 16-bit image or watermark without transparency, including
  the scale-down to fit the result limits or a format's size limit, no
  longer darkens it slightly. Each value lost about 0.1%, so white came
  back as 65455 instead of 65535.
- An image scaled down to fit `:max_result_width`, `:max_result_height`,
  `:max_result_pixels`, or a format's size limit keeps the exact colors of
  its semi-transparent pixels and uses the request's `kernel`. Before, a
  semi-transparent pixel could lose a level, so `[200, 120, 37, 100]` became
  `[200, 119, 37, 100]`, and a `kernel=nearest` result was smoothed.
- When the first load of the face or object model failed, each detection
  request waiting for it tried the load again in turn, so the last one
  waited for every attempt. Those requests now fail with the first load's
  error at once: the crop falls back to attention, or the request fails with
  `500` when `detector_required` is set. The next request loads again.
- `png-options=palette,bitdepth:16` multiplies 8-bit color by 257, as
  `bitdepth:16` without `palette` does. Before, it multiplied by 256.
- `png-options=bitdepth:1`, `2`, or `4` on a 16-bit color or gray-and-alpha
  result encodes at 8 bits, as on an 8-bit one. Before, it encoded at
  16 bits.
- A `crop-ratio` far from the `crop` size's own ratio, such as `1:4000`
  for a square crop, no longer fails with a `500`. Each side of the crop
  keeps at least one pixel.
- A client error, such as a `404` for a missing source, on a URL with
  `expires` caps a host's `Cache-Control` at the URL's expiry, as an image
  response does. Before, a host's `max-age=86400` kept the error cached
  after the URL expired. Errors found while parsing the URL, and the `410`
  for an expired URL, keep the host's `Cache-Control` unchanged.
- A thin `crop` or `region` of a JPEG or WebP image blends in far fewer
  pixels from just outside it. A crop under 16 pixels on its short side,
  such as an 8-pixel strip, decodes at full size and takes in none.
  Otherwise the reduced-size decode shrinks by at most an eighth of the
  crop's short side.
- When none of an HTTP source's addresses accepts a connection or answers
  in time, the source keeps its cached DNS answer while it looks the host
  up again, and replaces the answer only when it changed. Before, the
  cached answer was dropped first, so other requests to that origin waited
  for a new lookup.
- `output=info` reports an exact `dpr` for a tall, narrow image that the
  result limits scale down. Before, a 7×4000 image scaled to 2×1000
  reported `dpr` 0.29 instead of 0.25. The `:scale` measurement of
  `[:output, :clamp]` now uses the long side too.
- A URL's `anchor-offset`, `extend-at`, or `extend-offset` no longer
  replaces the crop target or canvas from a preset or the request defaults,
  and its `unset` removes only that option. Before, `anchor-offset=5,5`
  dropped a preset's `anchor`. See
  [presets](docs/requesting-images.md#named-presets).
- A `trim` tolerance with hundreds of digits no longer fails with a `500`.
  Tolerances above `2147483647` now fail with a `400`.
- Resizing a JPEG or WebP image only a few pixels high or wide, such as a
  2000×3 image at `w=100`, no longer fails with a `415`. Neither does
  shrinking a WebP so far that its short side would be under one pixel, such
  as `w=1/dpr=0.5`.
- S3 credentials that a provider returns with less than five minutes left
  are fetched again at half their remaining time, instead of every five
  seconds until the provider rotates them.
- A cache's own events, `[:cache, :admission]`, `[:cache, :eviction, :stop]`,
  and `[:cache, :sweep]`, use the instance's `telemetry_prefix`. Before, they
  always used `[:image_pipe]`. Handlers attached for a custom prefix,
  including `attach_default_logger(prefix: ...)` and `attach_tracer`, now get
  them, and handlers attached under `[:image_pipe]` for such an instance no
  longer do.
- An issue that `ImagePipe.validate/2` or `ImagePipe.run/4` reports, and
  the `:locations` of `[:request, :ignored_options]`, name the group as it's
  written in the URL or in the URL builder. Before, when a group held only
  `unset` options, issues in later groups named the group before theirs.
- `png-options=bitdepth:1` on a grayscale result now turns values below 128
  black and the rest white. Before, every gray above black came out white.
- With a [processing pool](docs/processing-controls.md), a request that
  waits for its turn while its original is still downloading:
  - Answers `503` once it has waited `queue_timeout`. Before, it waited
    for a second turn after the download finished.
  - Answers an error from processing, such as a `415` for an image that
    can't be decoded, without waiting for a second turn. Before, it could
    answer `503` instead when that wait timed out.
  - No longer fails with `503` 60 seconds after its original finished
    downloading when `queue_timeout` plus `processing_timeout` allows
    longer.
- S3 credentials whose access key, secret, or session token holds a line
  break or NUL are rejected: static ones when the configuration is checked,
  and ones from a credential provider when they're fetched, which answers
  `500` and logs which field was invalid. Before, every fetch with them
  failed with `502`, or with `404` when the secret held one.
- A `detect` or `anchor=smart-face` crop whose detector isn't available in
  this build no longer adds a detection to the work the cache estimates for
  the image, which the cache uses to choose what to evict and reports as
  `:estimated_cost_us` on `[:cache, :write]`.
- The default Logger logs every `4xx` request line at `:warning`. Before, a
  `4xx` for a failed decode, an input limit, a transform, or an invalid
  source logged at `:error`.
- A request with an invalid source has the result `:parser_error`, not
  `:processing_error`. Like other parser errors, its
  `[:request]` stop from `ImagePipe.run/4` has no `:error`.
- The request line for an invalid source or invalid output gives the
  reason: `reason="invalid source"` or `reason="invalid output"`.
- A 16-bit original delivered at 8 bits per channel has each value rounded
  to the nearest 8-bit level. Before, about a quarter of the values were one
  level off, so 65400 became 255 instead of 254. This also applies to
  `png-options=bitdepth:8` with `hdr=preserve`.
- A request that chains many operations, such as a watermark in each of a
  dozen groups, no longer crashes the Erlang VM. libvips ran out of stack
  rendering the chain. The image is now copied to memory once six
  operations have run since its last copy, which keeps the chain short.
- `png-options=palette` gives a palette PNG from a 16-bit result, such as
  one with `hdr=preserve`. Without a `bitdepth`, the palette was dropped and
  the PNG stayed 16-bit.
- With `meta=keep` and `profile=srgb`, `display-p3`, or `adobe-rgb`, the
  kept EXIF no longer carries the original's white point and primaries, and
  its ColorSpace tag is sRGB only for `profile=srgb` and Uncalibrated
  otherwise. Before, a Display P3 result could keep ColorSpace sRGB from its
  original.

### Security

- **Breaking:** `ImagePipe.Source.S3.ContainerCredentials` rejects a
  `base_url` that doesn't use `https`, a loopback host, or the ECS or EKS
  credential endpoint, as it already did for `full_uri`. Before, a
  `relative_uri` sent the authorization token to any `base_url`. The default
  `base_url` is unaffected. Change any other `base_url` to use `https` or a
  loopback host.
- Redacting a request path for telemetry, and echoing it in a `400`
  response, take time in proportion to the path's length. A path with many
  `wm-src64=` segments took seconds to redact, and other crafted 10 KB
  paths took tens of milliseconds. Telemetry redacts every request path
  before its URL signature is checked, so an unsigned request could cause
  this.
- Plain-text error responses, such as the `400` and the `405`, now send
  `X-Content-Type-Options: nosniff`. A `400` body quotes the request
  path, so a browser that sniffs content types could otherwise render it as
  HTML.
- The default Logger and the span tracer cap how much of each error reason
  and attribute value they print, so a large term can't produce an
  unbounded log line or span. Before, the Logger relied on Logger's own
  truncation, which a host can turn off.

## [0.3.0] - 2026-10-18

### Added

- The `kernel` URL option sets the filter a group's resize uses: `nearest`,
  `linear`, `cubic`, `mitchell`, `lanczos2`, `lanczos3` (the default),
  `mks2013`, or `mks2021`. With `kernel=nearest` in the first group, a large
  JPEG or WebP source is decoded at full size, so the request takes longer
  and uses more memory. See [kernel](docs/processing/resize.md#kernel).
- `dns_cache: false` turns off an HTTP source's DNS cache, for a server
  whose DNS resolver already caches and whose TTLs should apply exactly.
- `max_blur_work` limits `blur` and `progressive-blur`: the pixels of the
  image being blurred, times the square of the sigma, can't exceed it. A blur
  over the limit fails with `422`. See
  [Limiting blurs](docs/deployment.md#limiting-blurs).
- A `[:request, :summary]` telemetry event, emitted once per request, with
  what the request did as flat fields: method, path, status, duration, bytes
  sent, the signing key, the output and input cache outcomes, source, the
  original's format and size, the operations, the output format and size,
  the quality a search chose, and the time spent fetching, decoding,
  encoding, and waiting for the processing pool. It also records a result
  scaled down to the limits, ignored options, an original sent unprocessed,
  an original held in memory because it couldn't be written to a temporary
  file, and a client that disconnected. It gathers them from every process
  that served the request. The
  [event reference](docs/telemetry-events.md#request-summary) lists them.
- The `[:request]` span's start carries `:method` and `:path` for Plug
  requests. The path is as sent, except that a presigned source URL's
  credentials, such as an `X-Amz-Signature` value, are replaced with
  `REDACTED`. The tracer records them on the request span as
  `http.request.method`, `url.path`, and `url.query`.
- A file system cache logs at `info` when it claims its cache root, naming
  the host. A node that refused the root, because another node used it, logs
  at `info` when it takes the root over and requests use the cache again.
- ImagePipe logs a warning, once per directory, when the `image_pipe`
  directory in the system's temporary directory can't be used to stage
  originals, so they are held in memory instead. The `[:source, :stage]`
  span reports each original held in memory, and why, in `:staging` and
  `:staging_reason`, which the request summary also carries.
- An S3 source logs a warning when a fetch of its provider's credentials
  fails, naming the bucket and the provider module, and logs at `info` when a
  fetch succeeds again.
- A [`priority=low`](docs/processing/request.md#priority) request waits for
  spare capacity in the processing pool: it starts only when no normal
  request is waiting, and a normal request that finds the queue full takes
  its place. The pool's `low_priority_max_concurrency` option limits how
  many run at once. It defaults to half of `max_concurrency`, rounded down,
  and at least 1. A low-priority request waits for the original to finish
  downloading before processing starts. See
  [Low-priority requests](docs/processing-controls.md#low-priority-requests).
- The `503` for a full processing queue or a queue timeout has a
  `Retry-After` header, the pool's `queue_timeout` in whole seconds, rounded
  up.
- The `[:processing, :admission]` and `[:processing, :execute]` spans carry
  the request's `:priority`, and `ImagePipe.ProcessingPool.stats/1` also
  returns `:low_active` and `:low_queued`. The `[:request, :summary]` event
  has `priority: :low` for a low-priority request, and the default Logger
  logs one that a full pool turned away at its base level instead of as an
  error.

### Changed

- An instance without `cache` or `input_cache` no longer reads and hashes an
  unchanged local file on every request. It keeps the hashes of up to 10,000
  files in memory and checks each file's size, timestamps, inode, and device
  instead. For a 5.5 MB PNG this saves about 3 ms per request.
  For a remote original, a request with `If-None-Match` gets `304` without
  contacting the origin while the origin's cache lifetime lasts.
  [`[:cache, :lookup]`](docs/telemetry-events.md#cache-lookup) reports these
  lookups with `pool: :memory`.
- An HTTP source keeps the addresses a hostname resolves to for 10 seconds,
  so a busy origin is no longer looked up before every fetch. The addresses
  are still checked against `:address_policy` on every fetch. A resolver
  passed in `:address_resolver` replaces the cache.
- When none of an HTTP source's addresses accepts a connection or answers in
  time, the source looks the hostname up again and tries once more if the
  answer changed. A resolver passed in `:address_resolver` can therefore be
  called twice for one fetch.
- AVIF's default quality is 56, down from 63. Files are about 18% smaller.
  The median image scores 78 instead of 82 on
  [SSIMULACRA2](docs/choosing-an-autoquality-target.md#choosing-a-target),
  close to the JPEG default's 77. To keep 63, set
  `format_quality: %{avif: 63}`.
- A response's cache key and `ETag` no longer depend on the quality and
  encoder settings of other formats. Changing the AVIF quality or
  `avif_options` leaves them unchanged for WebP responses and for requests
  with a `format`, such as `format=jpeg`, so those stay cached and clients
  keep their copies. A response without `format`, for a client that accepts
  neither AVIF nor WebP, takes the original's format and still depends on
  every format's settings. After upgrading, cached image responses miss once
  and clients download each image again once.
- **Breaking:** a `blur` or `progressive-blur` over the default
  `max_blur_work`, 4,000,000,000,000, fails with `422`. `blur=1000` on a 10-megapixel photo took about 7 seconds
  and now fails. Raise `max_blur_work` to allow larger blurs.
- `blur` and `sharpen` buffer the image in memory before filtering it. They
  recomputed earlier steps, such as an enlarge or a color conversion, many
  times over, so `sharpen=10/w=8000/h=8000/enlarge` took 14 s. It now takes
  under 1 s. A request with `blur` or `sharpen` holds one copy of the image in
  memory at that point.
- Cached `output=blurhash`, `output=lqip-css`, and `output=info` responses
  that include a placeholder miss once after upgrading, since placeholders of
  transparent images changed.
- Output cache write failures are no longer logged directly. Attach the
  default Logger to see them, as `image_pipe cache stage` and
  `image_pipe cache write` warnings with the error category.
- `[:cache, :write]` carries `:error` on input cache write errors too.
- **Breaking:** `ImagePipe.Telemetry.attach_default_logger/1` logs one line
  per request, from the new `[:request, :summary]` event, instead of one line
  per stage. A `5xx`, or a response that failed partway through sending,
  logs at `error`, and a `4xx`, a result that didn't come out as requested,
  or a failed cache read at `warning`. Failed and dropped cache writes log
  their own `warning` lines. Pass `stages: true` to also log the stage lines
  as before.
- **Breaking:** An `ImagePipe` instance starts a processing pool unless its
  configuration names one in `processing_pool`. It processes as many images
  at once as the VM has online schedulers and queues up to 64 more for up to
  10 seconds. Beyond that, requests get a `503`, and `ImagePipe.run/4`
  returns `{:processing, :overloaded}` or `{:processing, :queue_timeout}`. An
  image that takes longer than 30 seconds gets a `503`, or
  `{:processing, :timeout}` from `run/4`. Set the new `pool` instance option
  to change the limits, or `pool: false` to process every request as it
  arrives, as before.
- **Breaking:** `ImagePipe.config/1` raises `ArgumentError` for a `:detector`
  module that isn't loaded or doesn't implement
  `ImagePipe.Transform.Detector`. Before, such a configuration started, and
  every `detect` or `anchor=smart-face` request failed with `500`. Fix the
  module name, or set `detector: nil`.
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
- A watermark on an image with a color profile is about 5 ms faster when the
  output is sRGB, which is the case with the default `profile=strip` and with
  `profile=srgb`. Partly transparent watermark pixels over colors outside
  sRGB, such as on a Display P3 photo, blend slightly differently.

### Fixed

- `autoquality` scored images with transparency as if they were shown on
  black, so changes at their edges and in their transparency didn't count,
  and transparent margins raised the score. A logo could get AVIF quality 22
  where it needed 31. It now scores the visible area only, against both a
  dark and a light background, and keeps the lower score. Images with
  transparency can get a higher quality and larger files.
- Detection requests that arrived before the bundled face or object model
  had loaded, for example during startup warmup with
  `detector_required: false`, each downloaded and loaded the model. They now
  wait for one load, so the 175 MB object model downloads once.
- `png-options=bitdepth:16` multiplied 8-bit color by 256 instead of 257, so
  128 became 32768 instead of 32896 and only white reached 65535. Color now
  scales by 257, as gray already did.
- `output=info` reported `dpr` from before the scale-down to the result
  limits, so dividing its width by `dpr` gave less than the CSS width. `dpr` now includes that scale-down: `w=4000/dpr=3` on a
  9,000-pixel-wide image with an 8,192-pixel limit reports width 8192 at
  `dpr` 2.048, not 2.25.
- Content-aware crops with `detect` or `anchor=smart-face` for a small
  output detected on the resized image. `w=64/h=64/fit=cover` on a
  6000×4000 source gave the detector 96×64 pixels, so small faces and
  objects were missed. Detection now gets at least 640 pixels on the long
  edge, or the whole source when it's smaller, and such requests decode at
  that size.
- An `extend-offset` that landed exactly on a half pixel, such as
  `extend-offset=0,1.25` with `dpr=2`, rounded away from zero, placing the
  image 1 pixel off. It now rounds ties to even, as crops, watermarks, and
  padding do.
- With a processing pool, a streamed response that finished just after
  `processing_timeout`, before the pool's timer fired, ended with
  `{:session, {:producer_down, :normal}}` instead of
  `{:processing, :timeout}`.
- `output=blurhash` and `output=lqip-css` rendered transparency on black, so
  a transparent PNG's placeholder could be dark while the JPEG the same URL
  returns is light. Placeholders now render transparency on white, unless
  `bg` sets a background.
- An `ImagePipe.Plug` configured at compile time, such as in a router's
  `forward` options, could fail to compile with "does not implement
  ImagePipe.Transform.Detector" when its custom detector was compiled in the
  same pass. Configuration now waits for the detector module to compile.
- The `[:transform, :detect, :model]` span reported a model that is
  unavailable, such as a face model without `image_vision`, as `result:
  :error`, and the default Logger logged it as a model error. It now reports
  `result: :unavailable`, as `[:transform, :detect]` does.
- Watermarks, `bg`, `colorize` over transparent areas, JPEG output of an
  image with transparency, and resizing or rotating an image with
  transparency could make a color one level darker than the exact result,
  such as 169 for 169.51. These now round to the nearest level.
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
  models load, and logs at `info` when they do.
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
- A `detect`, `anchor=smart`, or `anchor=smart-face` crop whose box covers
  the whole image, such as `crop=8000,8000/detect=face` on a smaller image,
  ran the detector or saliency anyway. With a failing detector the response
  wasn't stored, or failed with `500` under `detector_required: true`. Such
  a crop now runs no detection.
- An HTTP source could run past `fetch_timeout` in two ways. Looking up the
  host name could take as long as the `address_resolver` allowed. A name
  that resolved to several addresses made the fetch wait for a response at
  each address in turn. Fetches now fail with `504` at `fetch_timeout`,
  except that a connection attempt can run past it by up to
  `connect_timeout`.
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
- A request that reached `processing_timeout` while its source was still
  downloading failed with `500` or got no response. It now fails with
  `{:processing, :timeout}`, which the Plug answers with `503`.
- A large `pixelate` block size, such as `pixelate=2000` on a 4000×2667
  JPEG, failed with `415`. It now works.
- A `region` whose width or height came to less than half a pixel, such as
  `region=0,0,0.3,1`, failed with `500`. It now keeps one pixel.
- With `detector_required: true`, an `anchor=smart-face` crop called the
  detector before its models were ready, so the built-in detector could
  download a model during the request. Until the face model is ready, such
  a crop now uses attention cropping without calling the detector, and the
  response isn't stored while the face model can still become ready.
- `ImagePipe.Source.S3.ContainerCredentials` accepted an `auth_token` with a
  line break or NUL, and every credential fetch then failed. Such a token is
  now rejected when the source is configured.
- A `region` that started inside the last pixel column or row, such as
  `region=2002.6,0,10,10` on a 2003-pixel-wide image or
  `region=99.99pct,0,10,10`, failed with `400` because its origin rounded
  past the edge. It now starts at the last pixel. Only a region that starts
  at or beyond the edge is rejected.
- `output=info` reported a `result` size for a URL whose image request fails
  with `422` because it exceeds `max_intermediate_pixels`, such as
  `w=20000/enlarge` on a small image. It now fails with `422` too, as
  `output=blurhash` and `output=lqip-css` already did.
- A request for another variant of a source that was still downloading, such
  as `w=50` while `w=100` was fetching the same image, could fail with `504`.
  It waited until the first request's processing, which can start before the
  download finishes, was done too, and gave up a second after the source's
  `fetch_timeout`. It now waits only for the download.
- An SVG source ignored `page`, so `page=1` on an SVG answered `200` with the
  only image, and each `page` value stored its own copy. A `page` past `0`
  now fails with `422`, as it does for any other single-page image.
- A FileSystem cache that restarted while a write was stuck on disk for more
  than 25 seconds, as on a hung network mount, kept counting the bytes the
  response still sent to that write as waiting to be written. Until the next
  restart, the cache dropped more writes and evicted more entries than it
  needed to. Those bytes are no longer counted.
- A FileSystem cache that was full and busy with other writes could turn
  away an original's new expiry time or content identity after checking the
  original with the origin, and keep the outdated ones. Requests then checked
  with the origin, or downloaded the changed original, every time until the
  cache stored the update. The cache now removes the outdated details when it
  turns an update away.

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

[Unreleased]: https://github.com/hlindset/image_pipe/compare/v0.4.0...HEAD
[0.4.0]: https://github.com/hlindset/image_pipe/compare/v0.3.0...v0.4.0
[0.3.0]: https://github.com/hlindset/image_pipe/compare/v0.2.0...v0.3.0
[0.2.0]: https://github.com/hlindset/image_pipe/compare/v0.1.0...v0.2.0
[0.1.0]: https://github.com/hlindset/image_pipe/releases/tag/v0.1.0
