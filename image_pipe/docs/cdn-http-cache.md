# HTTP cache headers

ImagePipe generates `Cache-Control`, `ETag`, `Age`, and `Vary` headers for
successful `GET` and `HEAD` image responses, and answers `If-None-Match` with
`304 Not Modified`. The `http_cache` setting chooses which headers it sends:

<!-- tabs-open -->

### Plug

```elixir
forward "/images", ImagePipe.Plug,
  http_cache: :auto,
  sources: [...]
```

### image_pipe_server

```toml
[http]
http_cache = "auto"
```

<!-- tabs-close -->

Putting a CDN in front is covered in
[Serving images through a CDN](serving-through-a-cdn.md), and where cache
lifetimes come from in [Caching and freshness](caching-and-freshness.md). The
telemetry events are listed in
[HTTP cache events](telemetry-events.md#http-cache-events).

## Header modes

| Value | Headers |
| --- | --- |
| `validators` (default) | An `ETag`. Sources whose files can change also get their [source lifetime](#source-lifetimes) |
| `auto` | `Cache-Control: public, max-age=31536000, immutable` and an `ETag`. `private` in some cases (see [Vary](#vary)) |
| `public` | The same as `auto`, always `public` |
| `private` | The same as `auto`, always `private` |

In every mode:

- Sources whose files can change get their
  [source lifetime](#source-lifetimes) in place of the one-year lifetime.
- A response that may not be stored gets `Cache-Control: no-store` and no
  `ETag`. That covers a source whose storage is denied, by its origin or by
  configuration (see
  [storage permission](caching-and-freshness.md#storage-permission)), and a
  crop that fell back to a default because
  [content detection](content-aware-gravity.md) failed.
- A URL with an expiry gets a lifetime that ends with it (see
  [expiring URLs](#expiring-urls)).

## Per-source modes

A source's `http_cache` setting replaces the global value for that source.
Its default, `inherit`, uses the global value. A source of per-user uploads
can be `private` while other sources stay `public`:

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

## Source lifetimes

A response from a source whose files can change gets the original's
lifetime as `max-age`, and its age as `Age`. Making a
new size or format of the original doesn't restart that lifetime.

- An origin `no-cache` adds `no-cache`, or `must-revalidate` when the
  source forces a lifetime.
- An origin `must-revalidate`, `proxy-revalidate`, or `s-maxage` adds
  `must-revalidate`.
- A `stale-while-revalidate` window that applies to the original is added
  as `stale-while-revalidate`. A window forced by the source drops the
  `no-cache` and `must-revalidate` above.
- A source with no lifetime from its origin and no fallback lifetime gets
  `max-age=0`. Local files have no origin, so they get `max-age=0` unless
  their source sets a fallback lifetime (see the
  [Plug settings](cache.md#source-cache-settings) or the
  [server's `[sources.<name>]` keys](../../image_pipe_server/docs/server-configuration.md#sources-name)).

For example, an original fetched 60 seconds ago with
`Cache-Control: max-age=3600` gives:

```http
Cache-Control: public, max-age=3600
Age: 60
```

## Write-once source headers

A source marked write-once (`stable` set to immutable, see
[write-once sources](caching-and-freshness.md#write-once-sources)) is the
only kind that gets the one-year lifetime from the [header modes](#header-modes)
table, as long as storage is allowed. In `validators` mode it gets only an
`ETag`. Its `ETag` comes from the original's identifier instead of its
content:

- The file adapter: the source's `root_id` and the file's path.
- The http adapter: the URL, including its query string. Different query
  strings give different `ETag`s.
- The s3 adapter: the endpoint, bucket, key, and version. An object
  addressed by a version ID counts as write-once without being marked. The
  fetch requests that version, and the store must confirm it in
  `x-amz-version-id`.

For a write-once source, a change of origin credentials, such as a new S3
access key or a different result from an HTTP auth callback, also changes
the `ETag`. Credentials enter only as a hash, and never appear in telemetry.

## Expiring URLs

A URL with an [`expires`](processing/request.md) time never gets a cache
lifetime that outlasts it:

- `max-age` is lowered to the time left.
- `stale-while-revalidate` is shortened so it also ends by then, or dropped.
- `must-revalidate` is added.

In `validators` mode, a response from a write-once source gets
`Cache-Control: public, max-age=<seconds left>, must-revalidate`, with
`private` in place of `public` when `storage_inputs` names a cookie.

## Vary

A URL without a `format` option gets its format chosen from the request's
`Accept` header, and its response carries:

```http
Vary: Accept
```

A URL with a `format` option doesn't vary by `Accept`.

Headers named in `storage_inputs` are added to `Vary` too, in lower case,
sorted, without duplicates, and ahead of `Accept`. With these settings and no
`format` in the URL, the response carries `Vary: x-tenant, Accept`:

<!-- tabs-open -->

### Plug

```elixir
storage_inputs: [{:header, "x-tenant"}, {:cookie, "session"}]
```

### image_pipe_server

```toml
[cache]
storage_inputs = [{ header = "x-tenant" }, { cookie = "session" }]
```

<!-- tabs-close -->

Cookies never appear in `Vary`, since it names headers only. So when
`storage_inputs` names a cookie, `auto` and `validators` send `private` in
place of `public`, on cache hits and `304` responses as well. `public` sends
`public` anyway, for a host that guarantees the responses are the same for
every user.

In a Plug app, a `Vary` header set by an earlier Plug is handled by mode:

- In `auto`, `public`, and `private` modes it is merged with ImagePipe's.
  After `Vary: Accept-Encoding`, the response carries
  `Vary: Accept-Encoding, Accept`. An earlier `Vary: *` is kept as it is
  (see [headers set by the host](#headers-set-by-the-host)).
- In `validators` mode, ImagePipe's `Vary` replaces it. After
  `Vary: Accept-Encoding` or `Vary: *`, the response carries `Vary: Accept`.

## ETag

A generated `ETag` is strong and looks like `"ipr1-<hash>"`. It is computed
from the request before the original is fetched or processed. It changes
when any of these change:

- The original's content, or for a write-once source its identifier.
- The processing options. Two spellings of the same options give the same
  `ETag`.
- The output format.
- The content detector or model, when the crop uses detection. A `304` is
  never sent for an image made by a different detector.

The URL's cachebuster and the `storage_inputs` values select a different
entry in ImagePipe's own cache, but don't change the `ETag`. A new cachebuster
on an unchanged image stores a new copy, and clients that already have the
image still get a `304` (see [cache key inputs](cache.md#cache-key-inputs)).

A CDN keys on the raw URL. Two URLs that spell the same options differently
get the same `ETag` but are stored as two CDN objects.

An origin's own `ETag` is used only to check the original with the origin. It
never becomes a response `ETag`.

## Conditional requests

A `GET` or `HEAD` whose `If-None-Match` lists the generated `ETag` gets
`304 Not Modified` without decoding, processing, or encoding the image. The
comparison is weak, so both of these match `"ipr1-token"`:

```http
If-None-Match: "ipr1-token"
If-None-Match: W/"ipr1-token"
```

Whether ImagePipe contacts the source first depends on the source:

- A local write-once source answers `304` without reading the file, unless
  the source keeps copies of its files in the originals cache.
- A remote write-once source whose storage is allowed in its cache policy
  answers `304` without contacting the origin.
- Any other source answers `304` without contacting the origin while its
  original is within its lifetime. This needs one of ImagePipe's caches,
  which store the original's lifetime. Without them, the original is
  downloaded or read on every request, and the `304` is sent once its
  content matches.
- An original past its lifetime is checked with its origin before the `304`
  is sent (see
  [originals and processed images](caching-and-freshness.md#originals-and-processed-images)).
- Within a `stale-while-revalidate` window, a processed image that is
  already cached gets its `304` at once (see
  [stale-while-revalidate](caching-and-freshness.md#stale-while-revalidate)).

`If-None-Match: *` matches only a response served from ImagePipe's cache.
On a cache miss the request is processed and returns `200`. A header that
mixes `*` with listed tags is treated as `*`.

A `HEAD` response carries the same `ETag`, `Cache-Control`, and `Vary` as the
matching `GET`. `OPTIONS` gets `204`. Other methods get `405` before the URL
is parsed or the cache is read.

## Headers set by the host

In a Plug app, headers set by an earlier Plug take precedence over generated
ones:

- An earlier `Cache-Control` is kept. ImagePipe may still add its `ETag`.
- An earlier `ETag` is kept, and ImagePipe sends no generated `ETag`. A
  request that matches the earlier `ETag` doesn't get a `304`.
- `Plug.Conn`'s default `Cache-Control: max-age=0, private, must-revalidate`
  counts as unset. The same directives in another order, such as
  `private, max-age=0, must-revalidate`, count as set.

In `auto`, `public`, and `private` modes:

- A response with `Set-Cookie` gets no generated `Cache-Control` or `ETag`.
- An earlier `Cache-Control: no-store` stops the generated `ETag`.
- An earlier `Vary: *` stops the generated `Cache-Control` and `ETag`.

A source whose storage is denied, by its origin or by configuration, gets
`Cache-Control: no-store` even when an earlier Plug set `Cache-Control`.
Allowing storage in the source's cache policy overrides an origin's denial
(see the [Plug settings](cache.md#source-cache-settings) or the
[server's `[sources.<name>]` keys](../../image_pipe_server/docs/server-configuration.md#sources-name)).

`Vary: Accept` is sent whenever the format comes from `Accept`, even when the
generated `Cache-Control` and `ETag` are not.

## Custom validators

ImagePipe generates only `ETag` validators and answers only
`If-None-Match`. It doesn't send `Last-Modified` or answer
`If-Modified-Since`. In a Plug app, those are left to Plugs that run before
ImagePipe.
