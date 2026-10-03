# Serving images through a CDN

Set up ImagePipe so a CDN caches processed images at the edge and
revalidates them with ImagePipe when they go stale. This guide assumes
ImagePipe is already running in your app (see [Getting started with Phoenix](phoenix-getting-started.md)) or
as `image_pipe_server`, and that you can edit your CDN's cache settings. Why
images get the lifetimes they do is covered in
[Caching and freshness](caching-and-freshness.md).

## Turn on cache headers

By default ImagePipe sends an `ETag` but no cache lifetime for images from
write-once sources. Set `http_cache` to `auto` so responses carry a
`Cache-Control` the CDN can follow:

<!-- tabs-open -->

### Plug

```elixir
# lib/my_app_web/router.ex
forward "/images", ImagePipe.Plug,
  http_cache: :auto,
  sources: [
    media: [
      adapter: ImagePipe.Source.File,
      match: :path,
      options: [root: "/srv/images", root_id: "media"]
    ]
  ]
```

### image_pipe_server

```toml
[http]
http_cache = "auto"
```

<!-- tabs-close -->

The [header modes](cdn-http-cache.md#header-modes) table lists the other
values.

## Set source lifetimes

What the CDN may cache, and for how long, comes from each source:

- A source whose files never change gets a one-year lifetime once you mark it
  write-once (see [write-once sources](caching-and-freshness.md#write-once-sources)).
- HTTP and S3 sources pass on the lifetime their origin sends. S3 objects
  addressed by version count as write-once.
- Sources that can change and get no lifetime from their origin, including
  local files, get `max-age=0`, so the CDN revalidates every request. Set a
  fallback lifetime to let the CDN reuse them for a while.

Mark a write-once source like this:

<!-- tabs-open -->

### Plug

```elixir
options: [root: "/srv/images", root_id: "media", stable: :immutable]
```

### image_pipe_server

```toml
[sources.media]
adapter = "file"
match = "path"
root = "/srv/images"
root_id = "media"
stable = "immutable"
```

<!-- tabs-close -->

Or give a source whose files can change a one-hour fallback lifetime:

<!-- tabs-open -->

### Plug

```elixir
options: [
  root: "/srv/images",
  root_id: "media",
  cache_policy: [freshness: {:fallback, 3600}]
]
```

### image_pipe_server

```toml
[sources.media]
adapter = "file"
match = "path"
root = "/srv/images"
root_id = "media"
cache_policy = { freshness = { fallback = 3600 } }
```

<!-- tabs-close -->

A source can't have both. A changed file keeps being served from the CDN
until its lifetime runs out.

## Keep per-user images private

If a source serves images that differ per user, such as private uploads, set
`http_cache` to `private` on that source. Its responses get
`Cache-Control: private`, which a CDN doesn't store, while other sources
stay public:

<!-- tabs-open -->

### Plug

```elixir
uploads: [
  adapter: ImagePipe.Source.File,
  match: [prefix: "uploads"],
  options: [root: "/srv/uploads", root_id: "uploads", http_cache: :private]
]
```

### image_pipe_server

```toml
[sources.uploads]
adapter = "file"
match = { prefix = "uploads" }
root = "/srv/uploads"
root_id = "uploads"
http_cache = "private"
```

<!-- tabs-close -->

The `storage_inputs` setting lists request headers and cookies that select a
different cached image (see the
[Plug option](`ImagePipe.config/1`) or the
[server key](../../image_pipe_server/docs/server-configuration.md#cache)).
If it names a cookie, `auto` makes every response private, because `Vary`
can't name cookies.

## Configure the CDN

Apply these settings to the CDN route that serves your images:

- **Use ImagePipe's `Cache-Control`.** Don't replace it with an edge
  lifetime, or the CDN will cache `no-store` and `private` responses. A URL
  signed with an [expiry](urls.md#expiry) gets a lifetime that
  ends when the URL does, and an edge lifetime would outlast it.
- **Add `Accept` to the cache key.** URLs without a `format` option get WebP
  or AVIF chosen from the browser's `Accept` header, and carry
  `Vary: Accept`. Look for the CDN setting that adds request headers to the
  cache key. If you'd rather not, put a `format` in every URL. Those
  responses don't vary.
- **Add your `storage_inputs` headers to the cache key.** Each header named
  there is listed in `Vary` too.
- **Keep other headers out of the key.** ImagePipe doesn't read Client Hints
  such as `Width` or `DPR`, so they only split the cache.
- **Forward `If-None-Match`.** ImagePipe answers a matching request with
  `304 Not Modified` without processing the image again.

The CDN keys on the raw URL, so two spellings of the same options are two
cached copies. Generate URLs with the URL builder, `ImagePipe.URL`, to keep one
spelling per image.

If `[server]` sets `auth_token`, configure the CDN to send
`Authorization: Bearer <token>` on its requests to the server.

## Check the headers

Request an image from ImagePipe directly. If your URLs are signed, use a
signed one.

<!-- tabs-open -->

### Plug

```console
$ curl -sI http://localhost:4000/images/w=400/src/photos/beach.jpg
```

### image_pipe_server

```console
$ curl -sI http://localhost:8080/w=400/src/photos/beach.jpg
```

If `[server]` sets `auth_token`, add `-H "Authorization: Bearer <token>"` to
each request.

<!-- tabs-close -->

For a write-once source the response includes:

```http
cache-control: public, max-age=31536000, immutable
etag: "ipr1-..."
vary: Accept
```

Send the `ETag` back in `If-None-Match`:

<!-- tabs-open -->

### Plug

```console
$ curl -sI -H 'If-None-Match: "ipr1-..."' http://localhost:4000/images/w=400/src/photos/beach.jpg
HTTP/1.1 304 Not Modified
```

### image_pipe_server

```console
$ curl -sI -H 'If-None-Match: "ipr1-..."' http://localhost:8080/w=400/src/photos/beach.jpg
HTTP/1.1 304 Not Modified
```

<!-- tabs-close -->

Then request the same URL through the CDN twice. The second response should
carry the same `cache-control` and `etag`, and the CDN's own hit header,
such as `x-cache`.

A `cache-control: no-store` response has no `ETag` and is never cached. Either
storage is forbidden for that source, by its origin or by your configuration
(see [storage permission](caching-and-freshness.md#storage-permission)), or
the crop fell back to a default because
[content detection](content-aware-gravity.md) failed.

## Next steps

- [HTTP cache headers](cdn-http-cache.md) is the reference for every
  generated header and conditional request.
- [Caching processed images](caching-processed-images.md) stores images on
  the server, so a CDN miss isn't processed again.
