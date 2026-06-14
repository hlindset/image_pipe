# CDN HTTP Caching

ImagePipe can emit shared HTTP cache headers for public image routes when a
resolved source identity names stable bytes. The feature is opt-in at the Plug
level, and a source adapter can override it.

```elixir
forward "/images",
  to: ImagePipe.Plug,
  init_opts: [
    parser: ImagePipe.Parser.Imgproxy,
    sources: [
      path:
        {ImagePipe.Source.File,
         root: "/srv/images",
         root_id: "primary",
         stable: :trusted,
         http_cache: :enabled}
    ],
    http_cache: [mode: :enabled]
  ]
```

`http_cache: [mode: :enabled]` on the Plug turns on generated shared-cache
headers. `http_cache: :enabled` on a source forces that source to use the HTTP
cache path even when the Plug option uses `mode: :disabled`. `http_cache:
:disabled` on a source suppresses generated cache headers even when the Plug
option uses `mode: :enabled`.

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
ETag: "ip1-..."
```

When automatic output format selection depends on the request `Accept` header,
ImagePipe also emits:

```http
Vary: Accept
```

Configure the CDN cache key to include `Accept` for routes that use automatic
output. Explicit output formats don't emit `Vary: Accept`.

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

ImagePipe handles `If-None-Match` only for generated ETags. A matching `GET` or
`HEAD` returns `304 Not Modified` after source resolution and before cache lookup,
source fetch, decode, transform, or encode. HEAD response metadata
(`ETag`/`Cache-Control`/`Vary`) matches the equivalent `GET`, per RFC 9110 §9.3.2.

`If-None-Match` uses weak comparison for `GET` and `HEAD`, so both of these match
the generated ETag `"ip1-token"`:

```http
If-None-Match: "ip1-token"
If-None-Match: W/"ip1-token"
```

v1 ignores `If-None-Match: *`, including on internal cache hits.

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
one CDN object by sending an ETag or custom header. ImagePipe normalizes plan
material so matching URLs can produce the same ETag. A CDN that keys on the raw
URL still stores them as separate objects unless the CDN rewrites or redirects
them before cache lookup.

ImagePipe's internal cache key and HTTP ETag are different values. The internal
cache key includes storage concerns such as cachebuster and configured cache key
inputs. The generated ETag identifies the client-visible representation. For
example, `cachebuster` changes the internal cache key but leaves the generated
ETag unchanged.

`Plan.expires` is a parser validity field. It doesn't change generated
`Cache-Control`.

## Versioning

Generated ETags use a visible schema prefix built from the implementation
constant:

```elixir
"ip#{@etag_schema}-..."
```

Changing `@etag_schema` changes both the visible prefix and the hashed material.
That invalidates validators already stored by browsers and CDNs.

ImagePipe includes `@representation_version` in the shared plan material used by
generated ETags and the internal cache key. Bump it when encoder behavior,
output policy behavior, default quality, metadata handling, color handling,
orientation behavior, or symbolic output-rule semantics can change encoded
bytes without changing public request syntax.

The same version must be in both places. If it changed only the ETag, ImagePipe
could serve an old internal-cache body with a new validator.

## Deferred In V1

These are deliberate v1 boundaries:

- no generated `Last-Modified`
- no `If-Modified-Since`
- no short public caching for mutable sources
- no arbitrary `Vary` dimensions beyond `Accept`
- no Client Hints variation
- no generated ETags after source fetch
- no source metadata probing to discover upstream validators
- no per-route custom ETag override
- no parser-provided `Cache-Control`

Routes that need custom validators or mutable freshness policy should leave
ImagePipe generated HTTP caching off and set response headers in their own Plug
chain.
