# Operational notes

## Streaming failures

ImagePipe pulls the first encoded chunk before sending headers, so an early
failure can return a normal [error response](errors.md). Later source, decode,
encode, or client-close failures stop delivery and discard partial cache writes.
Cache errors fail open: delivery continues and telemetry records the failure.
A started response cannot be replaced with a new status or error body.

## Resource limits and timeouts

HTTP and S3 sources enforce redirect and receive-timeout limits. ImagePipe
identifies formats from image bytes rather than HTTP headers. Header inspection
rejects oversized inputs early where possible; decoded dimensions are always
checked before transforms.
See [resource limits](configuration.md#resource-limits) for defaults and
configuration.

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

Input body, pixel, and frame limits reject oversized sources with `413`.
Output limits instead downscale the final image uniformly before encoding.
Generation limits do not change cache identity: a successful cached response
can still be served after limits are lowered.

## Source identity

Built-in HTTP and S3 `req_options` are host-owned behavior. They must not vary
source bytes for the same resolved identity. Byte-selecting request options need
URI/object revision material, `internal_cache: :disabled`, or a custom adapter
identity field.

## S3 credentials

The `credentials` source option resolves the AWS credentials used to sign S3
requests. Use static keys or a provider that refreshes temporary credentials.

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
runtime, selected as `{:provider, Module, opts}`. ImagePipe ships these providers:

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

Decode uses sequential access and JPEG shrink-on-load or WebP scale hints
where geometry permits. Operations that need random pixel access copy the
image into RAM; orientation flushes and delivery can also allocate buffers.
Allow memory for these copies across concurrent requests. See
[streaming and materialization](transform_operations.md#streaming-and-materialization)
for execution details.

## libvips format support

ImagePipe decides a source's family from its signature before libvips sees it.
Sources with an unrecognised signature, and rejected families such as SVG, BMP,
and AVIF image sequences, fail with `415` without any libvips call. For accepted
families, the loader libvips chooses must belong to the detected family: JPEG
(including UltraHDR), PNG, WebP, TIFF, HEIF/AVIF, JPEG XL, JPEG 2000, or GIF. Other
loaders compiled into the host's libvips, such as ImageMagick, PDF, SVG, or
camera RAW loaders, therefore never decode a source. TIFF-signature files from
a file source are also checked before opening, because libvips lets a RAW
loader claim them by file name.

An accepted family still needs its loader in the deployed libvips build. A
missing loader fails the request with `415`.

## Automatic output

Automatic image responses use `Vary: Accept`. Configure the CDN to include
`Accept` in its cache key, or select an explicit output format. See
[output formats](processing/output.md#formats) for negotiation rules.

## Debug response headers

Enable `allow_debug_headers` on the mount and `debug` in the request to inspect
processing and cache decisions. Review the [header catalogue](debug_headers.md)
before exposing this operational data to clients.
