# Limiting work per request

Before exposing ImagePipe to real traffic, limit the work one request can
cause: how large an original may be, how long origins and clients may take,
and how much memory it uses.

This guide assumes ImagePipe is running in your app (see
[Getting started with Phoenix](phoenix-getting-started.md)) or as
`image_pipe_server` (see
[Getting started with the server](../../image_pipe_server/docs/server-getting-started.md)).

## Limiting originals

Three limits reject an original before it is processed, with `413`:

- `max_body_bytes`, 10 MB by default, limits the size of the file.
- `max_input_pixels`, 40 million by default, limits its decoded size. For an
  animation it counts the frames needed to reach the requested one.
- `max_input_frames`, 1,000 by default, limits the frames or pages a file may
  declare.

Lower them to the largest originals you expect to serve:

<!-- tabs-open -->

### Plug

```elixir
{ImagePipe,
 name: MyApp.Images,
 max_body_bytes: 5_000_000,
 max_input_pixels: 25_000_000,
 sources: [...]}
```

### image_pipe_server

```toml
[processing]
max_body_bytes = 5000000
max_input_pixels = 25000000
```

<!-- tabs-close -->

`max_result_width`, `max_result_height`, and `max_result_pixels` scale the
output down to fit before it is encoded. Changing them doesn't change images
that ImagePipe's cache, a CDN, or a browser already holds. To apply new limits
to those, change the URLs' [`cb`](processing/request.md#cb).

## Limiting intermediate images

Set `max_intermediate_pixels` to bound the size of decoded frames that are buffered
in memory, downsampled, or delivered. The default is 100 million pixels.
Larger frames fail with `422`, including before the output size is reduced
to its configured maximum.

<!-- tabs-open -->

### Plug

```elixir
{ImagePipe,
 name: MyApp.Images,
 max_intermediate_pixels: 50_000_000,
 sources: [...]}
```

### image_pipe_server

```toml
[processing]
max_intermediate_pixels = 50000000
```

<!-- tabs-close -->

A resize or padding step may create a larger image when a later crop reads
only a small part of it. The crop keeps the coordinates of the requested
image. A later downsampling step reads across that larger image and is
subject to the limit.

## Limiting blur and sharpen work

A large blur on a large image can take many seconds: `blur=1000` on a
10-megapixel photo takes about 7 seconds. `max_blur_work` limits the total
work of the [`blur`](processing/effects.md#blur),
[`progressive-blur`](processing/effects.md#progressive-blur), and
[`sharpen`](processing/effects.md#sharpen) steps in a request, across all its
[processing groups](requesting-images.md#processing-groups). Each step counts
the pixels of the image it runs on, times (sigma² + 10,000), or
(2 × sigma² + 50,000) for a progressive blur. A request over the limit fails
with `422`.

The default, 4,000,000,000,000, allows any one blur on a 2-megapixel image, a
blur with a sigma up to 624 on a 10-megapixel image, and up to 173 on a
100-megapixel image. A blur of 100 and a sharpen together on a 40-megapixel
image use less than a third of it. A progressive blur may use a sigma up to
987 on a 2-megapixel image and up to 418 on a 10-megapixel image, and fails
on a 100-megapixel image at any sigma. Lower the limit to allow less, or set it to
`:infinity` (`"infinity"` in the server's configuration) to turn it off:

<!-- tabs-open -->

### Plug

```elixir
{ImagePipe,
 name: MyApp.Images,
 max_blur_work: 1_000_000_000_000,
 sources: [...]}
```

### image_pipe_server

```toml
[processing]
max_blur_work = 1000000000000
```

<!-- tabs-close -->

## Limiting quality search work

[`autoquality`](processing/output.md#autoquality) and
[`max-bytes`](processing/output.md#max-bytes) encode the whole image once for
each quality they try: up to 6 times each, and up to 11 times when a request
uses both. AVIF and WebP take about 40 to 100 milliseconds per megapixel to
encode, so a search on a 40-megapixel result can take 10 to 45 seconds.
`max_search_pixels` limits the pixels a search encodes in one request. When
the next quality would pass the limit, the search stops early:

- `autoquality` delivers the lowest quality it tried that met the target, or
  the top of its quality range when none did.
- `max-bytes` delivers the highest quality it tried that fit, or the bottom of
  its quality range when none did.

The search still encodes the quality it delivers, so a request can encode the
image up to two more times than the limit allows.

The default, 100,000,000, lets a search finish on images up to 16 megapixels,
or 9 megapixels when a request uses both. On a 40-megapixel image the search
tries two qualities. Lower the limit to allow less, or set it to `:infinity`
(`"infinity"` in the server's configuration) to turn it off:

<!-- tabs-open -->

### Plug

```elixir
{ImagePipe,
 name: MyApp.Images,
 max_search_pixels: 50_000_000,
 sources: [...]}
```

### image_pipe_server

```toml
[processing]
max_search_pixels = 50000000
```

<!-- tabs-close -->

The limit is part of the cache key of a request that searches, so changing
it replaces the cached copies of those requests only.

## Timeouts for origins

HTTP and S3 sources wait at most 5 seconds for a connection
(`connect_timeout`), 5 seconds for each part of the response
(`receive_timeout`), and 30 seconds for the whole download
(`fetch_timeout`). All three are set per source:

<!-- tabs-open -->

### Plug

```elixir
sources: [
  web: [
    adapter: ImagePipe.Source.HTTP,
    match: [scheme: ["https"]],
    options: [
      allowed_hosts: ["assets.example.com"],
      receive_timeout: 3_000,
      fetch_timeout: 10_000
    ]
  ]
]
```

### image_pipe_server

```toml
[sources.web]
adapter = "http"
match = { scheme = ["https"] }
allowed_hosts = ["assets.example.com"]
receive_timeout = 3000
fetch_timeout = 10000
```

<!-- tabs-close -->

A download that runs past `fetch_timeout` fails, even when the origin keeps
sending a little data within each `receive_timeout`. Other requests waiting
for the same original give up after waiting `fetch_timeout` plus one second,
with `504`. Give the proxy or load balancer in front a total request timeout
as well.

## Slow clients

ImagePipe streams each image as it is encoded, and frees the request's
processing slot when the encode ends. The part of the response that a client
hasn't read yet waits in memory, up to 4 MB per request, and anything beyond
that in a file in the system temporary directory, kept until the download
ends (see [deadlines](processing-controls.md#deadlines)). Across all
requests, a node keeps about 256 MB in memory and 2 GB in those files at
most, plus up to one chunk per response. Give that directory room for a
little more than 2 GB, and point `TMPDIR` elsewhere if it can't hold that
(see [downloaded originals](cache.md#downloaded-originals)). When it is a
`tmpfs`, those files use memory.

When the encode has nowhere left to put what a slow client hasn't read, it
waits for the client (see [deadlines](processing-controls.md#deadlines) for
when). The client then holds its processing slot until the encode ends, and
that waiting counts toward `processing_timeout`.

A proxy or CDN in front that reads the whole response at once keeps that
memory and disk use low. Examples are nginx with response buffering or the
CDN described in [serving images through a CDN](serving-through-a-cdn.md).

A response cut short by the deadline ends the
[`[:deliver]` span](telemetry-events.md#deliver) with
`result: :processing_error`. [Failures during streaming](streaming-failures.md)
explains what the client receives.

## Memory

ImagePipe reads most images in one pass, without holding the whole decoded
image in memory. Some operations need the whole image at once: trimming,
blurring, sharpening, rotating by an arbitrary angle, smart and
object-detection cropping, and rotating a photo whose EXIF orientation says
it is turned. These copy the decoded image into memory, so a 40-megapixel
original can take over a hundred megabytes while it is processed.

Allow for that across the requests that run at once. The instance's
[processing pool](processing-controls.md) caps how many that is. An
`ImagePipe.Plug` mount without an instance has a pool only if it names one
in `processing_pool`.
`max_input_pixels` caps the decoded original, and `max_intermediate_pixels`
caps frames read during processing.

An instance also keeps two things in memory that `max_size_bytes` doesn't
count:

- The originals it remembers, about 1 KB each for a local file and 1.4 KB
  for an image from an origin, up to `max_remembered_originals`: at most
  about 280 MB by default. See
  [originals and processed images](caching-and-freshness.md#originals-and-processed-images).
- The metadata of recently served cache entries, about 1.8 KB each, up to
  the cache's `max_remembered_entries` (see `ImagePipe.Cache.FileSystem`):
  at most about 90 MB by default. See
  [Cache process and restarts](cache.md#cache-process-and-restarts).

libvips also keeps its recent operations and their images in an operation
cache, 100 operations by default. Each request decodes its original again, so
the cache rarely gets a hit and mostly keeps decoded images in memory. In a
run of 160 resizes of four 24-megapixel JPEGs, resident memory after garbage
collection was 480–730 MB with the cache and 310–340 MB without it, at the
same speed.

<!-- tabs-open -->

### Plug

Turn the cache off when your app starts:

```elixir
# lib/my_app/application.ex, in start/2
Vix.Vips.cache_set_max(0)
```

`Vix.Vips.cache_get_max()` then returns `0`. The setting applies to all
libvips work in the VM, including your app's own use of `Image` or Vix.

### image_pipe_server

The server turns the cache off when it starts.

<!-- tabs-close -->

## Next steps

- [Limiting concurrent processing](processing-controls.md): a processing pool
  and its deadlines.
- [Serving images through a CDN](serving-through-a-cdn.md): a cache in front
  that also absorbs slow clients.
- [Deploying image_pipe_server](../../image_pipe_server/docs/server-deployment.md):
  the server's connection limits, health checks, and shutdown.
