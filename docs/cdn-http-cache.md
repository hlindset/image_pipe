# CDN HTTP Caching

ImagePipe can emit shared HTTP cache headers for public image routes when a
resolved source identity names stable bytes. The feature is opt-in at the Plug
level, and a source adapter can override it.

```elixir
forward "/images",
  to: ImagePipe.Plug,
  init_opts: [
    dialect: ImagePipe.Dialect.IIIF,
    resolver: {MyApp.Resolver, []},
    http_cache: [mode: :enabled],
    sources: [
      path:
        {ImagePipe.Source.File,
         root: "/srv/images",
         root_id: "primary",
         stable: :trusted}
    ]
  ]
```

## Which mounts generate headers

Generated CDN cache headers are a **declarative-tier** capability today.
`http_cache: [mode: :enabled]` is one of
`ImagePipe.Dialect.Declarative.config_keys/0`, and a declarative dialect's
`%ImagePipe.Dialect.Resolved{}` carries `http_cache: :generated`, which runs
`ImagePipe.Response.CachePolicy` between building the representation and the
conditional gate. Without `mode: :enabled` the policy generates nothing at
all: no `Cache-Control`, no `ETag`.

The ordered dialects (`ImagePipe.Dialect.Native`, `ImagePipe.Dialect.Imgproxy`,
`ImagePipe.Dialect.TwicPics`) carry `http_cache: :dialect_owned`: the policy is
skipped, and their identity headers come straight from the representation
(`ImagePipe.Representation.response_headers/1` — the `ETag`, or
`Cache-Control: no-store` for a source with no byte identity). None of the
`[:http_cache, :prepare]`, `[:http_cache, :conditional, :match]`, or
`[:http_cache, :fallback, :no_store]` events fire on those mounts. Opting an
ordered dialect into the generated policy is separate, compatibility-reviewed
work.

A source adapter can override the mount-level mode per source:
`http_cache: :enabled` forces the generated path even when the mount is
`mode: :disabled`; `http_cache: :disabled` suppresses generated cache headers
even when the mount is `mode: :enabled`; the default `:inherit` follows the
mount. The override only reaches a mount whose dialect carries
`http_cache: :generated`: on a `:dialect_owned` mount the policy never runs, so
a source-level `:enabled` is inert there.

Source-level `http_cache: :enabled` doesn't force an ETag. The resolved source
still needs strong byte identity.

## Stable Source Bytes

`stable: :trusted` tells a source adapter that the resolved source identity names
the same bytes for every request. Use it only for write-once storage,
content-addressed paths, or storage where your application policy prevents
in-place replacement under the same identity.

For `ImagePipe.Source.File`, `stable: :auto` isn't enough to generate byte
identity. Files can be overwritten under the same path, so file sources need
`stable: :trusted` before ImagePipe derives a strong byte identity from
`root_id` and path segments.

For `ImagePipe.Source.HTTP`, `stable: :trusted` derives byte identity from the
URL components. ImagePipe doesn't put raw query strings into the identity. It
stores a query SHA-256 so signed query URLs and rotating query credentials don't appear in
ETags or telemetry. ImagePipe redacts query material instead of ignoring it:
different query strings still produce different generated ETags. If credentials
rotate while the source bytes stay the same, use a source identity without
credentials or a custom adapter.

For `ImagePipe.Source.S3`, objects with a revision are stable under
`stable: :auto` because the fetch includes the object version. S3 objects
without a revision need `stable: :trusted` if the bucket or key policy is
write-once.

`stable` and `internal_cache` are separate settings. `stable` is about whether
ImagePipe can create a public HTTP validator. `internal_cache` is about whether
ImagePipe may reuse an encoded body from its configured cache. A route can use
internal caching without generated HTTP cache headers.

## Generated Headers

For successful `GET` and `HEAD` responses with generated HTTP caching enabled and
strong byte identity, ImagePipe emits:

```http
Cache-Control: public, max-age=31536000, immutable
ETag: "ipr1-..."
```

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

## Conditional Requests

ImagePipe handles `If-None-Match` for explicit entity tags matching a generated
ETag. A matching `GET` or `HEAD` returns `304 Not Modified` after source resolution
and before cache lookup, source fetch, decode, transform, or encode. HEAD response
metadata (`ETag`/`Cache-Control`/`Vary`) matches the equivalent `GET`, per RFC 9110
§9.3.2.

`If-None-Match` uses weak comparison for `GET` and `HEAD`, so both of these match
the generated ETag `"ipr1-token"`:

```http
If-None-Match: "ipr1-token"
If-None-Match: W/"ipr1-token"
```

`If-None-Match: *` matches any current representation, but ImagePipe cannot prove
one exists pre-fetch — a request can still fail at source, decode, transform, or
encode. So the wildcard does **not** short-circuit before fetch; it proceeds into
the runner and is honored only on an **internal cache hit**, which proves a current
representation was successfully produced for the cache key. On a hit the response is
`304 Not Modified`, whether or not an ETag was generated; on a miss the request
generates and returns `200`. A header mixing `*` with explicit tags (invalid per
RFC 9110 §13.1.2) collapses to the wildcard.

ImagePipe serves only `GET` and `HEAD`. Any other method receives
`405 Method Not Allowed` with `Allow: GET, HEAD`, before parsing, source
resolution, or cache access.

ImagePipe doesn't interpret host-supplied ETags. If an earlier Plug sets
`ETag`, ImagePipe preserves it, suppresses its generated ETag, and doesn't use
that host ETag to return `304`.

## Host Headers

Existing host policy wins over generated policy.

If an earlier Plug sets `Cache-Control`, ImagePipe doesn't overwrite it. If the
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

## Missing Byte Identity

If HTTP caching uses `mode: :enabled` but the resolved source doesn't provide
strong byte identity, ImagePipe emits:

```http
Cache-Control: no-store
```

It doesn't emit a generated ETag. This is a safety fallback for a route that
asked for shared-cache behavior but couldn't prove validator material.

ImagePipe emits this required telemetry event:

```text
[:image_pipe, :http_cache, :fallback, :no_store]
```

Metadata is low-cardinality:

```elixir
%{
  adapter: :path,
  source_kind: :path,
  reason: :missing_byte_identity
}
```

If a host already set `Cache-Control`, ImagePipe preserves the host policy
instead of replacing it with `no-store`.

## Telemetry

HTTP cache preparation emits:

```text
[:image_pipe, :http_cache, :prepare]
```

Metadata includes `:effective_mode`, `:byte_identity`, and `:etag`. It doesn't
include paths, source identities, or ETag values.

A conditional `304` emits:

```text
[:image_pipe, :http_cache, :conditional, :match]
```

Metadata includes the method as `method: :get` or `method: :head`. It doesn't
include paths or ETag values.

Internal cache hits that receive freshly prepared HTTP cache headers emit:

```text
[:image_pipe, :http_cache, :cache_hit, :headers]
```

Metadata reports whether a generated ETag, generated cache headers, and
representation headers were present. It doesn't include cache keys, paths,
source identities, or ETag values.

## Cache Key Relationship

The CDN controls the CDN cache key. ImagePipe can't make two different URLs share
one CDN object by sending an ETag or custom header. ImagePipe normalizes request
material so matching URLs can produce the same ETag. A CDN that keys on the raw
URL still stores them as separate objects unless the CDN rewrites or redirects
them before cache lookup.

Both values come from `ImagePipe.Representation.build/3`, which derives them
from the same pre-fetch material but different slices of it:

- the **internal cache key** is storage identity, and includes the
  `storage_only` material — the cachebuster plus the request header and cookie
  values named by the mount's `storage_inputs`;
- the **generated ETag** identifies the client-visible representation and
  excludes `storage_only`, so a cachebuster change busts storage while leaving
  the validator — and therefore already-downloaded client copies — intact.

Detector and model identity, by contrast, are part of *both*: swapping a
detector or model changes the rendition, so it must change the validator too — a
conditional GET will not return `304` against a rendition produced by a
different detector.

`Plan.expires` is a request-validity field a dialect enforces at parse time. It
doesn't change generated `Cache-Control`.

## Versioning

Generated ETags carry a visible schema prefix from `ImagePipe.Representation`'s
`@etag_schema` constant (`"ipr1"` today). Changing it changes both the visible
prefix and the hashed material, invalidating validators already stored by
browsers and CDNs.

Two epochs ride the same material as the key and the ETag, so a bump can never
pair an old internal-cache body with a new validator:

- `ImagePipe.Representation`'s `@core_execution_epoch` — bump it when core
  encoder behavior, output policy behavior, default quality, metadata handling,
  color handling, or orientation behavior can change encoded bytes without
  changing public request syntax. It invalidates every representation every
  dialect has built.
- each dialect's own behavioral epoch, carried in the material's
  `dialect_behavior` — for the declarative tier,
  `ImagePipe.Dialect.Declarative.Identity`'s `@declarative_epoch`; ordered
  dialects carry theirs in their own `Identity` module. A bump there
  invalidates only that tier or dialect.

## Deferred In V1

These are deliberate v1 boundaries:

- no generated `Last-Modified`
- no `If-Modified-Since`
- no short public caching for mutable sources
- no `Vary` dimensions beyond `Accept` and the configured `storage_inputs`
  header names
- no Client Hints variation
- no generated ETags after source fetch
- no source metadata probing to discover upstream validators
- no per-route custom ETag override
- no dialect-provided `Cache-Control`

Routes that need custom validators or mutable freshness policy should leave
ImagePipe generated HTTP caching off and set response headers in their own Plug
chain.
