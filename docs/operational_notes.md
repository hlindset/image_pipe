# Operational notes

ImagePipe verifies Imgproxy signatures and parses Imgproxy path options before
fetching source bytes. Invalid signatures return `403`, and invalid processing
requests return `400`, both without source traffic.

Parser and plan validation finish before source resolution, cache lookup, or
fetch. Source resolution finishes before cache lookup. Requests whose resolved
source has `internal_cache: :enabled` look up the cache before source fetch and
decode. Fetch and decode run only on a cache miss. They also run when a source
uses `internal_cache: :disabled`.

No-cache requests, `internal_cache: :disabled` requests, cache misses, cache
read errors, and invalid cache hits use a supervised source session for lazy
response streaming. The session owns the source-backed image and encoder
continuation. The Plug request process receives only prepared response metadata,
the first encoded chunk, and callbacks for pulling later chunks.

ImagePipe pulls the first encoded chunk before committing response headers. A
failure before that point can still become a normal ImagePipe error response.
After `send_chunked/2`, late source, decode, encode, cache staging, and client-close
failures have different response effects. Source, decode, encode, and
client-close failures stop delivery and skip partial cache writes. Cache staging
over-limit, staging errors, and cache commit errors fail open, emit telemetry,
and keep the response delivery result. In all cases, ImagePipe can't replace an
already-started response with a new HTTP error body.

Runtime cache read, metadata, and write errors fail open. Invalid cache
configuration still fails during Plug initialization.

HTTP and S3 source fetches use non-bang Req calls with bounded redirects and
receive timeouts. ImagePipe reads the source format from the decoded image
rather than trusted HTTP headers. `:max_body_bytes` defaults to `10_000_000`
bytes. `:max_input_pixels` defaults to `40_000_000` pixels after decode. Override
both in `ImagePipe.Plug` init options.

ImagePipe bounds source fetches per chunk and per byte, not per total wall-clock.
`:receive_timeout` (and `:connect_timeout`/`:pool_timeout`) bound the gap between
streamed chunks, and `:max_body_bytes` bounds total size — but ImagePipe imposes
no deadline on a whole transfer, nor on how long a slow client may take to drain a
response. By deliberate decision those two wall-clock bounds belong to the
deployment's front proxy or CDN — the layer ImagePipe is designed to sit behind:

- A trickling origin (each chunk arriving just under `:receive_timeout`) makes
  per-chunk progress indefinitely while staying under `:max_body_bytes`, so
  neither in-library bound stops it — and because the handler is *busy* (not
  idle) during the fetch, a server-level request/idle timeout (Bandit, Cowboy)
  does not fire either. A front proxy bounds it: its upstream-response read
  timeout — nginx `proxy_read_timeout`, Caddy `read_timeout`, an ALB/CDN
  origin-response timeout — fires while waiting for ImagePipe to emit the first
  response byte and returns `504`. ImagePipe deliberately does not add a redundant
  in-library transfer deadline.
- A slow-reading client that drains a chunked response one TCP window at a time
  holds the source session open while the producer keeps a suspended encode
  continuation. With proxy response buffering on (nginx `proxy_buffering on`, the
  default; equivalently any CDN) the proxy drains ImagePipe quickly into its own
  buffer and feeds the slow client itself, so ImagePipe finishes and releases the
  session promptly rather than waiting on the slow reader; the proxy's
  `send_timeout` bounds the client. Without a proxy, the server's outbound
  write/idle timeout (Bandit, Cowboy) fires when the producer cannot write because
  the client is not reading.

Static result limits run after transform execution and before final output
resolution or encoding. `:max_result_width` and `:max_result_height` default
to `8_192`. `:max_result_pixels` defaults to `40_000_000`. Result dimensions
mean the final static image width, height, and pixel count. Oversize static
results now **downscale the served image to fit** these caps rather than erroring
(imgproxy `limitScale` parity); `:max_input_pixels` remains a hard `413`
image-bomb gate on oversize decoded input. Animation frame limits
remain out of scope and aren't implemented.

These limits gate response generation. They don't change cache identity.
ImagePipe can serve a successful cached response even when the current request
has stricter generation limits. The source fetch, decode, transform, and encode
work already completed before the response entered the cache.

Built-in HTTP and S3 `req_options` are host-owned behavior. They must not vary
source bytes for the same resolved identity. Byte-selecting request options need
URI/object revision material, `internal_cache: :disabled`, or a custom adapter
identity field.

S3 `buckets` is a map. When present, it's an allowlist. `default` supplies
shared defaults. Each bucket entry can override region, endpoint, credentials,
request options, and cache policy.

## S3 credentials

The `credentials` source option resolves the AWS credentials used to sign S3
requests. It takes one of two shapes.

**Static keys** — long-lived access key + secret (plus an optional session
token):

```elixir
credentials:
  {:static, [access_key_id: "AKIA…", secret_access_key: "…", token: nil]}
```

Reading the standard AWS environment variables is a host concern — map them to
static keys yourself:

```elixir
credentials:
  {:static,
   [
     access_key_id: System.fetch_env!("AWS_ACCESS_KEY_ID"),
     secret_access_key: System.fetch_env!("AWS_SECRET_ACCESS_KEY"),
     token: System.get_env("AWS_SESSION_TOKEN")
   ]}
```

**Provider** — a pluggable module that resolves temporary credentials at
runtime, selected as `{:provider, Module, opts}`. ImagePipe ships two:

- **EC2 instance role (incl. Elastic Beanstalk), via IMDSv2:**

  ```elixir
  credentials: {:provider, ImagePipe.Source.S3.InstanceRole, []}
  ```

- **ECS / Fargate / EKS container credentials:**

  ```elixir
  credentials:
    {:provider, ImagePipe.Source.S3.ContainerCredentials,
     relative_uri: System.get_env("AWS_CONTAINER_CREDENTIALS_RELATIVE_URI"),
     auth_token: System.get_env("AWS_CONTAINER_AUTHORIZATION_TOKEN")}
  ```

  `full_uri` is accepted only for a loopback host or over `https` (mirroring
  AWS), so a misconfigured URI cannot leak the auth token off-box. If your
  platform injects `AWS_CONTAINER_AUTHORIZATION_TOKEN_FILE` instead of an inline
  token, read the file in the host and pass its contents as `:auth_token`.

- **STS `AssumeRole` (cross-account):** a composing wrapper. It resolves a base
  provider's credentials and signs an STS `AssumeRole` call with them to obtain
  temporary credentials for a role in another account.

  ```elixir
  credentials:
    {:provider, ImagePipe.Source.S3.AssumeRole,
     base: {:provider, ImagePipe.Source.S3.InstanceRole, []},
     role_arn: "arn:aws:iam::123456789012:role/image-read",
     external_id: "optional-external-id",
     region: "eu-west-1"}
  ```

  The base config (`:base`) is any other credential shape (`{:static, …}` or
  `{:provider, …}`) whose role is allowed to assume `:role_arn`; it is resolved
  through its own cache entry. `:external_id` is optional. The base credentials
  and the assumed credentials are each cached and refreshed before expiry.

- **EKS / IRSA, via STS `AssumeRoleWithWebIdentity`:** reads the projected OIDC
  token file (re-read on every refresh, since it rotates) and exchanges it for
  temporary credentials with an unsigned STS call.

  ```elixir
  credentials:
    {:provider, ImagePipe.Source.S3.WebIdentity,
     token_file: System.get_env("AWS_WEB_IDENTITY_TOKEN_FILE"),
     role_arn: System.get_env("AWS_ROLE_ARN"),
     region: System.get_env("AWS_REGION")}
  ```

Both STS providers call the regional endpoint (`sts.<region>.amazonaws.com`) and
cache through the same refresh cache as the others — one STS call per credential
lifetime, fail-closed on expiry. Unlike imgproxy (which defaults the region to
`us-west-1`), `:region` is **mandatory** on both — there is no silent fallback.

Hosts can implement their own provider with the
`ImagePipe.Source.S3.CredentialProvider` behaviour.

Provider results are cached per `{provider, opts, bucket}` and refreshed shortly
before expiry, so the provider is consulted once per credential lifetime rather
than per request. **Expired credentials are never sent to S3** — when refresh is
failing and the cached credentials have expired, the request fails closed
(`{:source, :credentials_unavailable}`). To eliminate the latency of the first
request after boot, add the optional warm-up worker to the host's supervision
tree:

```elixir
{ImagePipe.Source.S3.CredentialWarmup,
 provider: ImagePipe.Source.S3.InstanceRole, opts: [], scope: "my-bucket"}
```

## Decode planning

For transform chains proven safe for one-pass reads, ImagePipe may open the
source image with libvips sequential access before executing the first pipeline.
The supported shapes are auto-orient-only pipelines and fit or stretch resize
requests with concrete target dimensions. These shapes may use sequential access
whether the result downscales or upscales.

Chains involving crop, cover result crops, canvas extension, unknown transform
intent, output-only requests, or no geometry transform continue to use random
access.

When a parsed plan contains more than one image pipeline, ImagePipe materializes the
image between pipelines. This preserves the explicit pipeline boundary and lets
source decode planning consider the first pipeline only. Later pipelines may
contain operations classified as requiring random access. Those operations use
a memory-backed intermediate image instead of changing how ImagePipe
opens the source image.

Sequential decode doesn't use JPEG shrink-on-load or WebP scale hints in this
pass. Source byte limits, receive timeouts, decoded pixel limits, and decode
error responses still apply. Cache hits serve stored response bodies directly
and skip source decode optimization.

## libvips format support

ImagePipe accepts source families only when the deployed libvips build can read
them. The test suite exercises SVG rejection and source-only TIFF fallback with
real libvips loaders. Development and CI builds should include SVG load support
and TIFF load/save support so missing loader support can't hide format support
drift.

## Automatic output

Automatic output format selection uses the request `Accept` header only to
detect optional modern format support. `q=0` excludes AVIF and WebP candidates,
including exact media-type exclusions over wildcard allowances.
Missing, empty, and global wildcard-only values such as `*/*` don't advertise
modern format support. Explicit `image/avif`, `image/webp`, and `image/*`
media ranges do.

Among detected modern candidates, ImagePipe uses server preference order rather
than relative q-value ordering. If ImagePipe detects no enabled modern
candidate, output-capable source families use the decoded source format. Source
families without encoder support fall back after transforms: PNG when the final
image has an alpha channel, JPEG otherwise. Automatic output responses use
`Vary: Accept`. Explicit formats bypass content negotiation and don't set
`Vary: Accept`.

## Debug response headers

ImagePipe can attach opt-in `X-ImagePipe-*` and `Server-Timing` debug headers,
gated by the `allow_debug_headers` mount option and a per-dialect per-request
trigger: imgproxy's signed `debug:1` processing option, TwicPics' `debug=1`
manipulation, or the IIIF `?debug=1` query parameter. They are off by default.
The imgproxy trigger is covered by the path signature; the TwicPics and IIIF
triggers are unprotected query/path segments — only enable
`allow_debug_headers: true` on those mounts if the disclosed facts are
acceptable to expose. See [Debug response headers](debug_headers.md) for the
full catalogue and the security/disclosure details.
