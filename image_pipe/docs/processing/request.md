# Request controls

These options set the download file name, pick a page or frame of the
original, bust cached copies, limit how long a URL works, and ask for debug
headers. Each one applies once to the whole request, wherever it appears in
the URL.

## Downloads

`filename` and `attachment` apply to cached responses too, and don't change
the stored image or its `ETag`. A `304 Not Modified` response has no
`Content-Disposition` header.

### filename

Accepts ASCII letters, digits, `.`, `_`, and `-`, at least one character.
Default: none.

`filename` names the file a browser saves. ImagePipe adds the extension of
the actual response: `.jpg`, `.webp`, and so on for images, `.txt` for
`output=blurhash` and `output=lqip-css`, and `.json` for `output=info`. With
`filename=beach`, a WebP response has the header
`Content-Disposition: inline; filename="beach.webp"`.

<!-- tabs-open -->

### URL

```text
/w=1200/filename=beach/src/photos/beach.jpg
```

### Elixir

```elixir
ImagePipe.URL.new(filename: "beach")
|> ImagePipe.URL.group(resize: [width: 1200])
```

<!-- tabs-close -->

### attachment

A [flag](../requesting-images.md#flags): `attachment` or `attachment=false`.
Default: off.

`attachment` makes the browser download the response instead of displaying
it, using `Content-Disposition: attachment`. `attachment=false` turns off an
`attachment` set by a [preset](../requesting-images.md#named-presets).

<!-- tabs-open -->

### URL

```text
/w=1200/format=jpeg/filename=beach/attachment/src/photos/beach.jpg
```

### Elixir

```elixir
ImagePipe.URL.new(filename: "beach", attachment: true)
|> ImagePipe.URL.group(resize: [width: 1200])
|> ImagePipe.URL.output(format: :jpeg)
```

<!-- tabs-close -->

## Pages and frames

### page

Accepts a whole [number](../requesting-images.md#numbers) of `0` or more.
Default: the original's default image. That is the primary image of a HEIF
or AVIF collection, the default image of an animated PNG, and the first page
or frame of anything else.

`page` picks one page or frame of a multi-page or animated original, such as
a TIFF, a GIF, or an animated WebP, counting from `0` in file order. The
result is a single still image. For HEIF and AVIF collections, `page=0` is
the first image in the file, which can differ from the primary image.

- A page past the last one fails with `422` and the body
  `requested page does not exist in the source image`. A still image has
  only `page=0`.
- Frame N of an animation is built from all the frames before it, so the
  server's image size limit counts N + 1 frames. A late frame of a long
  animation can fail as too large where the first frame doesn't.
- `page` also applies to `output=info`, which then describes that page. Its
  `pages` field gives the number of pages or frames.

<!-- tabs-open -->

### URL

```text
/w=400/page=2/src/scans/report.tiff
```

### Elixir

```elixir
ImagePipe.URL.new(page: 2)
|> ImagePipe.URL.group(resize: [width: 400])
```

<!-- tabs-close -->

## Cache busting and expiry

### cb

Accepts ASCII letters, digits, `.`, `_`, and `-`, at least one character.
Default: none.

`cb` makes ImagePipe process the image again and store a separate copy,
instead of serving a copy it stored for the same URL without `cb`. Because
the URL changes, browsers and CDNs fetch it as a new URL. `cb` doesn't change
the `ETag`, so a client that already has the image gets `304 Not Modified`.
[Caching and freshness](../caching-and-freshness.md) explains when stored
copies are refreshed, and [ETag](../cdn-http-cache.md#etag) covers the
validators.

<!-- tabs-open -->

### URL

```text
/w=800/cb=release-2/src/photos/beach.jpg
```

### Elixir

```elixir
ImagePipe.URL.new(cachebuster: "release-2")
|> ImagePipe.URL.group(resize: [width: 800])
```

<!-- tabs-close -->

### expires

Accepts a positive whole number: a Unix time in seconds. Default: none.

The URL works up to and including that second. After it, the request fails
with `410` and the body `expired`, before the image is fetched or a cached
copy is served. Browsers and CDNs are never told to cache the response past
that time (see [expiring URLs](../cdn-http-cache.md#expiring-urls)).

Anyone can edit `expires` in an unsigned URL. When ImagePipe requires
[signed URLs](../requesting-images.md#signed-urls), the signature covers
`expires`, and you get it as part of the signed URL.

<!-- tabs-open -->

### URL

```text
/w=800/expires=2000000000/src/photos/beach.jpg
```

### Elixir

```elixir
ImagePipe.URL.new(expires: 2_000_000_000)
|> ImagePipe.URL.group(resize: [width: 800])
```

<!-- tabs-close -->

## Debugging

### debug

A flag: `debug` or `debug=false`. Default: off.

`debug` adds `X-ImagePipe-*` and `Server-Timing` response headers that
describe the original, the chosen output, the cache status, and the time
each stage took. They appear only when the server's configuration allows
debug headers (see [Plug configuration](`ImagePipe.Plug`) and
[server configuration](../../../image_pipe_server/docs/server-configuration.md#http)).
Otherwise `debug` is ignored. It never changes the image, the stored copy, or
the `ETag`. [Debug headers](../debug_headers.md) lists each header.

<!-- tabs-open -->

### URL

```text
/w=400/debug/src/photos/beach.jpg
```

### Elixir

```elixir
ImagePipe.URL.new(debug: true)
|> ImagePipe.URL.group(resize: [width: 400])
```

<!-- tabs-close -->
