# Choosing an automatic quality target

Automatic quality gives each image the lowest encoder quality that still looks
as good as a target you choose, instead of one fixed quality for every image.

This guide assumes ImagePipe is running in your app (see
[Getting started with Phoenix](phoenix-getting-started.md)) or as
`image_pipe_server` (see
[Getting started with the server](../../image_pipe_server/docs/server-getting-started.md)).

## Turning on automatic quality

Automatic quality is off by default. Turn it on with the `autoquality`
setting:

<!-- tabs-open -->

### Plug

```elixir
# lib/my_app/application.ex
{ImagePipe, name: MyApp.Images, sources: [...], autoquality: true}
```

### image_pipe_server

```toml
[processing]
autoquality = true
```

<!-- tabs-close -->

These are options on the `ImagePipe` instance or on `forward ... ImagePipe.Plug`.
JPEG, WebP, and AVIF responses then search for their quality. PNG, lossless
WebP, and requests that set `q` are encoded once.

## Choosing a target

The target is an [SSIMULACRA2](https://github.com/cloudinary/ssimulacra2)
score from 0 to 100. Higher looks better and costs more bytes: 90 is very high
quality, 70 is high, and 50 is medium. The default is 75.

A benchmark over 53 photos and screenshots measured the file size at each
target, compared with each format's default quality (JPEG 80, WebP 79, AVIF
63, see [`q`](processing/output.md#q) and
[`format-q`](processing/output.md#format-q)):

| Target | JPEG | WebP | AVIF |
| --- | --- | --- | --- |
| 70 | 24% smaller | 18% smaller | 38% smaller |
| 72 | 19% smaller | 12% smaller | 33% smaller |
| 75 | 9% smaller | 1% larger | 24% smaller |
| 78 | 5% larger | 19% larger | 12% smaller |
| 80 | 16% larger | 33% larger | 2% smaller |
| 85 | 53% larger | 87% larger | 34% larger |

WebP can't reach the higher targets for some images even at q96: 13 percent
of them at 80, all screenshots, and 38 percent at 85. The WebP sizes at those
targets leave them out.

At a fixed quality, scores across the benchmark images varied by about 10
points between the best and worst tenth. At target 75, most images landed
within a point of the target, except screenshots that WebP couldn't bring up
to it.

Keep 75 unless the table shows a size you can't accept. Set the target next
to `autoquality`:

<!-- tabs-open -->

### Plug

```elixir
{ImagePipe, name: MyApp.Images, sources: [...], autoquality: true, autoquality_target: 80}
```

### image_pipe_server

```toml
[processing]
autoquality = true
autoquality_target = 80
```

<!-- tabs-close -->

## Overriding the target per request

A request can set its own target with the
[`autoquality`](processing/output.md#autoquality) option:

```text
/w=800/autoquality=85/src/photos/beach.jpg
```

A bare `autoquality` uses the server's target, `autoquality=false` turns the
search off, and a request that sets `q` skips the search.

## Weighing the search cost

A search makes about three encodes, and decodes and scores each one. A fixed
quality makes one encode. With a cache, only the first request for each image
pays for the search (see [caching processed images](caching-processed-images.md)).

## Checking the result

Turn on [debug headers](debug_headers.md) and add the
[`debug`](processing/request.md#debug) option to a request:

```text
/w=800/debug/src/photos/beach.jpg
```

The response then carries the search's result. A `hit` with a score at or
just above the target means the search worked:

```text
X-ImagePipe-AQ-Target: 75.0
X-ImagePipe-AQ-Score: 75.3
X-ImagePipe-AQ-Outcome: hit
```

A `best_effort` outcome means the image was delivered at the highest quality
the search tries without reaching the target (see
[debug headers](debug_headers.md#automatic-quality)). In the benchmark at
target 75, these were all screenshots. Lower the target
if those images come out too large.

## Next steps

- [`autoquality` reference](processing/output.md#autoquality) for the exact
  rules and errors.
- [`max-bytes`](processing/output.md#max-bytes) to cap file size as well.
