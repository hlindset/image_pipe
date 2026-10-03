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

Large results don't fail. `max_result_width`, `max_result_height`, and
`max_result_pixels` scale the output down to fit before it is encoded.

## Timeouts for origins

HTTP and S3 sources wait at most 5 seconds for a connection
(`connect_timeout`) and 5 seconds for each part of the response
(`receive_timeout`). Both are set per source:

<!-- tabs-open -->

### Plug

```elixir
sources: [
  web: [
    adapter: ImagePipe.Source.HTTP,
    match: [scheme: ["https"]],
    options: [allowed_hosts: ["assets.example.com"], receive_timeout: 3_000]
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
```

<!-- tabs-close -->

An origin that sends a little data just within each timeout can still keep a
fetch open for a long time. When the original is read while the image is
processed, the [processing pool](processing-controls.md)'s
`processing_timeout` bounds the whole fetch. With an
[originals cache](cache.md#originals-cache), the original is fetched before
processing starts, so only the source's own timeouts apply. Give the proxy
or load balancer in front a total request timeout as well.

## Slow clients

ImagePipe streams each image as it is encoded. A client that reads slowly
keeps that request's processing slot and memory until it finishes, and the
processing pool's deadline counts that time too.

Put a proxy or CDN in front that reads the whole response from ImagePipe and
sends it to the client itself, such as nginx with response buffering or the
CDN described in [serving images through a CDN](serving-through-a-cdn.md).
Set `processing_timeout` well above the time your largest images take to
make and send to that proxy.

A response cut short by the deadline ends the
[`[:deliver]` span](telemetry-events.md#deliver) with
`result: :processing_error`. [Failures during streaming](streaming-failures.md)
explains what the client receives.

## Memory

ImagePipe reads most images in one pass, without holding the whole decoded
image in memory. Some operations need the whole image at once: trimming,
rotating by an arbitrary angle, smart and object-detection cropping, and
rotating a photo whose EXIF orientation says it is turned. These copy the
decoded image into memory, so a 40-megapixel original can take over a
hundred megabytes while it is processed.

Allow for that across the requests that run at once. A
[processing pool](processing-controls.md) caps how many that is, and
`max_input_pixels` caps the size of each.

## Next steps

- [Limiting concurrent processing](processing-controls.md): a processing pool
  and its deadlines.
- [Serving images through a CDN](serving-through-a-cdn.md): a cache in front
  that also absorbs slow clients.
- [Deploying image_pipe_server](../../image_pipe_server/docs/server-deployment.md):
  the server's connection limits, health checks, and shutdown.
