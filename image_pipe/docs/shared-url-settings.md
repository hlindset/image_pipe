# Shared URL settings

These settings must match between an application that builds URLs with
`image_pipe_url` and the `image_pipe_server` or `ImagePipe.Plug` that serves
them. A mismatch makes the server reject URLs the builder produced.
[Building URLs for the server](building-server-urls.md) walks through
setting up both sides.

`ImagePipe.Plug` takes the builder's settings unchanged: pass the
value from `ImagePipe.URL.config/1` as `url:` to `ImagePipe.config/1`. Where
a Plug host spells a setting differently, the entry says so.

## Signing keys

The hex-encoded HMAC keys that sign each URL. The server's list must hold the
first key in the builder's list, which is the one the builder signs with.
When neither side has keys, URLs are unsigned. See
[signing URLs and rotating keys](signing-urls.md).

<!-- tabs-open -->

### Elixir (URL builder)

```elixir
ImagePipe.URL.config(keys: [System.fetch_env!("IMAGE_PIPE_SIGNING_KEY")])
```

### image_pipe_server

```toml
[url]
keys = ["0123abcd…"]
```

Or `IPS_URL__KEYS=0123abcd…`, comma-separated for several keys. See
[`[url]`](../../image_pipe_server/docs/server-configuration.md#url).

<!-- tabs-close -->

On a mismatch:

- A signature that no server key verifies answers `403` with the body
  `invalid signature`.
- An unsigned URL sent to a server with keys answers `403` with the body
  `invalid signature`.
- A signed URL sent to a server without keys answers `400`. The body points
  at the `sig=` segment with `sig is not accepted: no signing keys are
  configured`.

## Source encryption keys

The 32-byte keys, written as 64 hex digits, that encrypt the source into an
`enc/<token>` segment. Generate one with `openssl rand -hex 32`. The builder
encrypts with the first key. The server decrypts with any key in its list.
See [source concealment](urls.md#source-concealment).

<!-- tabs-open -->

### Elixir (URL builder)

```elixir
ImagePipe.URL.config(
  keys: [System.fetch_env!("IMAGE_PIPE_SIGNING_KEY")],
  source_encryption_keys: [System.fetch_env!("IMAGE_PIPE_SOURCE_KEY")],
  encrypt_source: true
)
```

### image_pipe_server

```toml
[url]
keys = ["0123abcd…"]
source_encryption_keys = ["89abcdef…"]
```

Or `IPS_URL__SOURCE_ENCRYPTION_KEYS=89abcdef…`, comma-separated for several
keys. See [`[url]`](../../image_pipe_server/docs/server-configuration.md#url).

<!-- tabs-close -->

`encrypt_source` (encrypt every source) and `iv_mode` (whether a source
always encrypts to the same token) are builder settings. The server decrypts
every token without them. Its `[url]` doesn't accept them, and the server
stops at boot with `url.encrypt_source: unknown setting`.

Encrypted watermark sources (`wm-enc`) use the same keys.
`ImagePipe.URL.config/1` raises, and the server stops at boot, for
encryption keys without signing keys or an encryption key equal to a signing
key.

On a mismatch:

- A token that no server key decrypts answers `404` with the body
  `not found`. A server without source encryption keys answers the same for
  every `enc/` URL.

## Base URL and mount path

The builder's `base_url` is the address clients use, including the path the
server serves images under. The signature covers only the path after that
prefix, so the prefix can change without re-signing.

<!-- tabs-open -->

### Elixir (URL builder)

```elixir
ImagePipe.URL.config(base_url: "https://images.example.com/images", keys: keys)
```

### image_pipe_server

```toml
[server]
mount_path = "/images"
```

The host part of the address comes from DNS, a proxy, or a CDN in front of
the server. With `auth_token` set in `[server]`, image requests must also
send `Authorization: Bearer <token>`. `[url]` doesn't accept `base_url`, and the server stops at boot
with `url.base_url: unknown setting`. See
[`[server]`](../../image_pipe_server/docs/server-configuration.md#server).

<!-- tabs-close -->

A Plug host's prefix is the path its router mounts `ImagePipe.Plug` at, such
as `forward "/images", ImagePipe.Plug, …`.

On a mismatch:

- A path outside `mount_path` answers `404` with an empty body.
- A `base_url` path longer than `mount_path` leaves extra segments in front
  of the signature. With signing keys, the request answers `403` with
  `invalid signature`. Without them, it answers `400` with the parse error.
- With `[server] auth_token` set, a request without the bearer token answers
  `401` with an empty body. A URL can't carry that header, so a browser
  loading builder URLs gets `401` unless a proxy or CDN in front of the
  server adds it.

## Preset names

URLs carry preset names, such as `preset=card`. The server applies its
current definition of each name, so the builder needs no definitions to build
URLs. The signature covers the name only, so changing a definition on the
server keeps signed URLs valid. Define a preset on the server before the app
builds URLs with it, and keep it there while those URLs are in use. The server
answers `400` to a URL with a preset it doesn't have. See
[presets](presets.md).

<!-- tabs-open -->

### Elixir (URL builder)

```elixir
ImagePipe.URL.config(
  keys: keys,
  mount_presets: [
    presets: %{"card" => "w=400/h=300/fit=cover"},
    request_defaults: "q=80"
  ]
)
```

`mount_presets` is optional. It lets `ImagePipe.URL.validate/1` and
`ImagePipe.URL.url/3` check plans against the server's presets and request
defaults. It never changes a generated URL. `preset_lookup: true` says the server
resolves names missing from `presets` with a lookup, so the builder leaves
them to it. See `ImagePipe.URL.validate/1`.

### image_pipe_server

```toml
[processing]
request_defaults = "q=80"

[processing.presets]
card = "w=400/h=300/fit=cover"
```

See [`[processing]`](../../image_pipe_server/docs/server-configuration.md#processing).

<!-- tabs-close -->

A Plug host defines them as `presets:` and `request_defaults:` in
`ImagePipe.config/1`, and may add a `preset_lookup:`. Its builder gets them
filled in with `ImagePipe.url_config/1`.

On a mismatch:

- A name the server doesn't define answers `400`. The body points at the
  `preset=` option with `unknown preset: card`.
- A `mount_presets` copy that differs from the server gives wrong validation
  results in the builder. The URLs stay the same, and the server checks them
  against its own definitions.

## Source prefixes and schemes

The URL carries the whole source string, escaped or encrypted, and the
server routes it by its first path segment or its scheme. The string must
start with a prefix or scheme a server source serves. The source's name
(`static` in `[sources.static]`) never appears in URLs. See
[routing image paths to sources](sources.md#routing-image-paths-to-sources).

<!-- tabs-open -->

### Elixir (URL builder)

```elixir
ImagePipe.URL.url!(builder, "media/photos/beach.jpg")
ImagePipe.URL.url!(builder, "https://assets.example.com/beach.jpg")
```

### image_pipe_server

```toml
[sources.media]
adapter = "file"
match = { prefix = "media" }
root = "/data/media"
root_id = "media"

[sources.web]
adapter = "http"
match = { scheme = ["http", "https"] }
allowed_hosts = ["assets.example.com"]
```

See [`[sources.<name>]`](../../image_pipe_server/docs/server-configuration.md#sources-name).

<!-- tabs-close -->

A Plug host configures the same rules as `match:` in `sources:` of
`ImagePipe.config/1`.

On a mismatch:

- A path that no prefix matches, on a server without a `match = "path"`
  source, answers `404` with `source not found`. With a `match = "path"`
  source, that source looks the path up and answers `404` when nothing is
  there.
- A URL whose scheme no source matches, such as `https://…`, `s3://…`, or
  `asset://…`, answers `400` with `invalid source`.

## Watermarks

`wm=<name>` selects a watermark image the server defines. The builder can't
check these names, since `mount_presets` doesn't carry them. See
[watermark assets](processing/watermark.md#watermark-assets).

<!-- tabs-open -->

### Elixir (URL builder)

```elixir
ImagePipe.URL.group(builder, watermark: :logo)
ImagePipe.URL.group(builder, watermark_source: "brand/badge.png")
```

### image_pipe_server

```toml
[processing]
request_watermarks = true

[processing.watermarks.logo]
source = "brand/logo.png"
```

See [`[processing]`](../../image_pipe_server/docs/server-configuration.md#processing).

<!-- tabs-close -->

A Plug host defines them as `watermarks:` and `request_watermarks:` in
`ImagePipe.config/1`. `request_watermarks` lets URLs name their own watermark
source (`watermark_source:` in the builder, `wm-src64` or `wm-enc` in the
URL).

On a mismatch:

- A name the server doesn't define answers `400`. The body points at the
  `wm=` option with `unknown watermark`.
- A watermark source in the URL, on a server without `request_watermarks`,
  answers `400` with `request watermark sources are not enabled`.
