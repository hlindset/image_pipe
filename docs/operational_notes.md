# Operational notes

ImagePipe verifies path signatures and parses options before fetching
source bytes. Invalid signatures return `403`; invalid processing requests
return `400`. Neither causes source traffic.

Parser and plan validation finish before source resolution, cache lookup, or
fetch. Source resolution finishes before cache lookup. Requests whose resolved
source has `internal_cache: :enabled` look up the cache before source fetch and
decode. Fetch and decode run only on a cache miss. They also run when a source
uses `internal_cache: :disabled`.

Requests that cannot use a cache hit run in a supervised source session for
lazy response streaming. The session owns the source-backed image and encoder
continuation. The Plug process receives prepared response metadata, the first
encoded chunk, and callbacks that pull later chunks.

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
bytes. `:max_input_pixels` defaults to `40_000_000` stored pixels. The existing
32 KiB format peek also reads PNG IHDR, JPEG SOF, and WebP VP8X/VP8/VP8L
dimensions to reject oversized inputs before opening the libvips loader.
Incomplete, malformed, or unfamiliar headers fall back to libvips; its stored
dimensions are always checked before transforms. Override both limits in
`ImagePipe.Plug` init options.

Source adapter limits bound fetches per chunk and by total bytes.
`:receive_timeout` limits waits between chunks;
`:connect_timeout` and `:pool_timeout` bound connection setup and checkout.
`:max_body_bytes` limits total size. Use a front proxy or CDN to bound waits
for ImagePipe's response and handle slow clients:

- A trickling origin (each chunk arriving just under `:receive_timeout`) makes
  a transfer take a long time without reaching `:max_body_bytes`. Because the
  handler remains busy, a Bandit or Cowboy idle timeout may not fire either.
  Use an upstream-response timeout such as
  nginx `proxy_read_timeout`, Caddy `read_timeout`, or an ALB/CDN origin timeout.
- A slow-reading client that drains a chunked response one TCP window at a time
  holds the source session and suspended encode continuation open. Response
  buffering lets a proxy drain ImagePipe promptly and feed the client itself;
  the proxy's send timeout then bounds the client. Without a proxy, configure
  the server's outbound write or idle timeout.

An optional [processing pool](processing-controls.md) caps concurrent generation
and queued jobs across Plug and Elixir callers. Its processing deadline covers
admitted generation through stream cleanup, including source consumption and
downstream demand pauses. Source-cache acquisition and revalidation before the
output-cache lookup retain their independent source limits. Output-cache hits
and conditional responses bypass processing admission.

Static result limits run after transforms and before output resolution or
encoding. `:max_result_width` and `:max_result_height` default to `8_192`;
`:max_result_pixels` defaults to `40_000_000`. Oversize static results are
uniformly downscaled to fit. By contrast, `:max_input_pixels` is a hard `413`
image-bomb gate after decode. Animation frame limits are not implemented.

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
lifetime, fail-closed on expiry. `:region` is mandatory on both providers.

Hosts can implement their own provider with the
`ImagePipe.Source.S3.CredentialProvider` behaviour.

Provider results are cached per `{provider, opts, bucket}` and refreshed before
expiry. **Expired credentials are never sent to S3**: if refresh fails after the
cached credentials expire, the request fails closed with
`{:source, :credentials_unavailable}`. To avoid first-request latency, add the
optional warm-up worker to the host supervision tree:

```elixir
{ImagePipe.Source.S3.CredentialWarmup,
 provider: ImagePipe.Source.S3.InstanceRole, opts: [], scope: "my-bucket"}
```

## Decode planning

ImagePipe always opens decoded images with libvips sequential access. The decode
planner uses the request geometry to select JPEG shrink-on-load or WebP scale
hints when possible.

The executor keeps the image lazy and streaming until an operation needs random
pixel access. Smart or object-detection crops, trim, and arbitrary-angle rotate
trigger a RAM materialization immediately before that operation. Deferred EXIF
and user orientation handling manages its own materialization when required.
Other operations remain sequential when proven safe by the test gate.

Explicit `-` groups share the same transform state; a group boundary alone
does not materialize the image. The late delivery barrier materializes any chain
that reaches output without an earlier barrier. Source byte limits, timeouts,
decoded pixel limits, and decode error handling apply regardless of the chosen
load hint. Cache hits skip decoding and transforms entirely.

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
gated by the `allow_debug_headers` mount option and the request's `debug` flag.
They are off by default. The flag is covered by the path signature.
See [Debug response headers](debug_headers.md) for the
full catalogue and the security/disclosure details.
