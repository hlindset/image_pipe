# HTTP and CDN caching

ImagePipe can emit shared HTTP cache headers for public image routes. Immutable
sources use their authoritative identity; mutable remote sources use the current
original-byte identity and retained origin freshness. Generated policy is opt-in
at the Plug level, and a source can override it. See [internal caching](cache.md)
for pool configuration and origin-policy overrides.

```elixir
forward "/images",
  to: ImagePipe.Plug,
  init_opts: [
    http_cache: :auto,
    sources: [
      images: [
        adapter: ImagePipe.Source.File,
        match: :path,
        options: [root: "/srv/images", root_id: "primary", stable: :immutable]
      ]
    ]
  ]
```

## Header modes

The `http_cache` option takes one of four values:

| Value | Headers |
| --- | --- |
| `:validators` (default) | An `ETag`, and no generated `Cache-Control` |
| `:auto` | `Cache-Control: public, max-age=31536000, immutable` and an `ETag`. `private` instead of `public` when `storage_inputs` include a cookie |
| `:public` | The same policy, always `public` |
| `:private` | The same policy, always `private` |

In every mode, a source without strong byte identity, or one whose cache policy
denies storage, gets `Cache-Control: no-store` and no `ETag`. Mutable remote
sources replace the one-year lifetime with the origin's freshness, sent as
`Cache-Control` and `Age`.

A source can set the same option. Its default, `:inherit`, uses the mount's
value, and any other value replaces it for that source. For example, a mount
with `http_cache: :public` can serve per-user uploads from a source set to
`http_cache: :private`.

## Stable source bytes

`stable: :immutable` tells a source adapter that the resolved source identity names
the same bytes for every request. Use it only for write-once storage,
content-addressed paths, or storage where your application policy prevents
in-place replacement under the same identity.

For `ImagePipe.Source.File`, `stable: :auto` isn't enough to generate byte
identity. Files can be overwritten under the same path, so file sources need
`stable: :immutable` before ImagePipe derives a strong byte identity from
`root_id` and path segments.

For `ImagePipe.Source.HTTP`, `stable: :immutable` derives byte identity from URL
components. Raw query strings never enter ETags or telemetry; a query SHA-256
preserves their identity effect. Different query strings therefore produce
different ETags. HTTP authentication callbacks and S3 credentials are resolved
once per request and the effective credential snapshot partitions both caches.
Credential changes also partition immutable validators. Secrets are
hashed before entering storage keys and are never emitted in telemetry.

For `ImagePipe.Source.S3`, objects with a revision are stable under
`stable: :auto`: the revision is an S3 version ID, the fetch requests that
version, and the store must confirm it with `x-amz-version-id`. S3 objects
without a revision need `stable: :immutable` if the bucket or key policy is
write-once.

`stable` and `internal_cache` are separate settings. `stable` is about whether
ImagePipe can derive byte identity before a fetch. `internal_cache` controls
storage and reuse in both pools. A route can use internal caching without
generated HTTP cache headers. Mutable remote sources obtain byte identity from
the complete original bytes; their output validators require current source
evidence. `stable: :immutable` removes expiry, but origin storage restrictions
still apply unless the host explicitly sets `cache_policy: [storage: :allow]`.

## Generated headers

For successful `GET` and `HEAD` responses with generated HTTP caching enabled and
immutable byte identity, ImagePipe emits:

```http
Cache-Control: public, max-age=31536000, immutable
ETag: "ipr1-..."
```

Mutable sources instead emit the source-derived lifetime and current `Age`.
Generating a new variant does not restart that lifetime. Origin `no-cache` and
mandatory revalidation survive in downstream policy; a permitted
`stale-while-revalidate` window is advertised too. Origin `no-store`, `private`,
and other storage prohibitions produce `Cache-Control: no-store` unless the
host explicitly overrides storage permission. A forced TTL alone does not
override storage permission.

When automatic output format selection depends on the request `Accept` header,
ImagePipe also emits:

```http
Vary: Accept
```

Configure the CDN cache key to include `Accept` for routes that use automatic
output. Explicit output formats don't emit `Vary: Accept`.

Configured `storage_inputs` header names also enter `Vary`. A mount with
`storage_inputs: [{:header, "x-tenant"}, {:cookie, "session"}]` and automatic
output sends:

```http
Vary: x-tenant, Accept
```

Cookie entries never enter `Vary` — it names headers only. Header names
normalize to lower case, drop duplicates, and sort deterministically, so the
header doesn't depend on the configured list's order or spelling.

Configuring any cookie storage input makes generated cache policy `private`
by default, including on cache hits and `304` responses. Storage partitioning
does not make a response safe to share through a CDN. A host that guarantees
public responses can use `http_cache: :public`, and `http_cache: :private`
forces private policy even without cookie inputs. Existing host headers and
`Set-Cookie` retain precedence.

For CDN configuration:

- honor origin `Cache-Control`, including `no-store`
- forward `If-None-Match` to ImagePipe for revalidation
- include `Accept` in the cache key when using automatic output
- don't add Client Hints such as `Width` or `DPR` to the cache key for v1
- expect raw URL cache keys unless the CDN rewrites or redirects before lookup

ImagePipe merges an existing `Vary` header with `Accept`. If an earlier Plug set
`Vary: Accept-Encoding`, the final header for automatic output is:

```http
Vary: Accept-Encoding, Accept
```

If an earlier Plug set `Vary: *`, ImagePipe preserves `Vary: *` and suppresses
generated public cache headers.

## Conditional requests

ImagePipe handles `If-None-Match` for explicit entity tags matching a generated
ETag. A matching `GET` or `HEAD` returns `304 Not Modified` without decode,
transform, or encode. Local immutable sources can do this immediately after
resolution. Coordinated remote sources first consult retained source evidence;
fresh evidence avoids origin access and the encoded-body read. Immutable remote
sources with explicit storage permission can skip that evidence lookup too.

Expired mutable sources validate upstream with `If-None-Match` or
`If-Modified-Since` before answering a client conditional. An upstream `304`
refreshes shared evidence without downloading the original or re-encoding a
surviving output. A changed `200` changes the original-byte identity and every
derived key and validator. A valid SWR output may be served immediately,
including a matching client `304`, while one supervised refresh runs in the
background. Failed refreshes never extend the stale deadline.

HEAD response
metadata (`ETag`/`Cache-Control`/`Vary`) matches the equivalent `GET`, per RFC 9110
§9.3.2.

`If-None-Match` uses weak comparison for `GET` and `HEAD`, so both of these match
the generated ETag `"ipr1-token"`:

```http
If-None-Match: "ipr1-token"
If-None-Match: W/"ipr1-token"
```

`If-None-Match: *` needs proof that a current representation exists, which is not
available before source processing. ImagePipe therefore honors it only on an
**internal cache hit**. A hit returns `304 Not Modified` with or without a
generated ETag; a miss processes the request and returns `200`. A header mixing
`*` with explicit tags, invalid under RFC 9110 §13.1.2, is treated as the
wildcard.

ImagePipe serves `GET` and `HEAD` images and answers `OPTIONS` with `204`.
Other methods receive `405` before parsing, source resolution, or cache access.

ImagePipe doesn't interpret host-supplied ETags. If an earlier Plug sets
`ETag`, ImagePipe preserves it, suppresses its generated ETag, and doesn't use
that host ETag to return `304`.

## Host headers

Existing host policy wins over generated policy within the source storage
permission. An origin storage prohibition forces `no-store`; use the explicit
source policy override to change that decision.

If an earlier Plug sets `Cache-Control` and storage is permitted, ImagePipe
doesn't overwrite it. If the
source has strong byte identity and no host ETag, ImagePipe may still add a
generated ETag.

ImagePipe treats the default `Cache-Control` value set by `Plug.Conn` as unset
before response delivery:

```http
Cache-Control: max-age=0, private, must-revalidate
```

A Plug that needs to force that exact policy should set another explicit policy
or disable generated HTTP caching for the route.

If the selected `Cache-Control` contains `no-store`, ImagePipe doesn't generate
an ETag.

If the response has `Set-Cookie`, ImagePipe suppresses generated public cache
headers.

Required representation headers are separate from generated cache policy.
Suppressing generated `Cache-Control` or `ETag` leaves `Vary: Accept` in place
when automatic output uses `Accept`.

## Missing byte identity

If the resolved source doesn't provide strong byte identity, ImagePipe emits:

```http
Cache-Control: no-store
```

It emits no generated ETag. This prevents shared caching when the route cannot
prove byte identity.

With `:auto`, `:public`, or `:private`, a `Cache-Control` the host already set
is preserved instead of replaced with `no-store`.

## Telemetry

HTTP cache events report policy preparation, conditional matches, missing byte
identity, and cache-hit headers. See [HTTP cache telemetry](telemetry-events.md#http-cache-events)
for event names, metadata, and Logger output.

## Cache key relationship

The CDN controls its cache key. An ETag cannot make two URLs share one CDN
object. ImagePipe may produce the same ETag for equivalent request material, but
a CDN keyed on raw URLs stores separate objects unless it rewrites or redirects
before lookup.

ImagePipe derives its storage key and ETag from the request and source byte
identity:

- the **internal cache key** includes the cachebuster and the request header and cookie
  values named by the mount's `storage_inputs`;
- the **generated ETag** excludes those storage-only inputs, so a cachebuster
  change selects a new storage entry while preserving the validator for
  byte-identical output.

Detector and model identity enter both values because changing either can change
the rendition. A conditional GET cannot return `304` for a rendition made by a
different detector.

Request expiry is enforced before source resolution. It
doesn't change generated `Cache-Control`.

## Custom validators

ImagePipe generates ETags and handles `If-None-Match`. Routes needing
`Last-Modified`, `If-Modified-Since`, or custom validators can disable generated
HTTP caching and set headers in their own Plug chain.
