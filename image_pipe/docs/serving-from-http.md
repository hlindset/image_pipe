# Serving images from an HTTP origin

Serve originals that ImagePipe downloads from a web server, a storage
bucket's public URL, or another image service. This guide assumes ImagePipe
is running in your app (see [Plug usage](plug-usage.md)) or as
`image_pipe_server` (see
[getting started with the server](../../image_pipe_server/docs/server-getting-started.md)).

There are two ways to name the original in an image URL:

- A path on one origin, such as `src/originals/beach.jpg`. The origin's
  address stays out of your image URLs.
- The full URL, such as `src/https://assets.example.com/beach.jpg`, from
  hosts you list.

## Serve paths from one origin

Give an HTTP source a `base_url`. Each path that reaches the source is
appended to it:

<!-- tabs-open -->

### Plug

```elixir
sources: [
  originals: [
    adapter: ImagePipe.Source.HTTP,
    match: [prefix: "originals"],
    options: [
      base_url: "https://images.example.com/originals",
      path_pattern: ~r/[a-zA-Z0-9_-]+\.(jpg|jpeg|png|webp)/
    ]
  ]
]
```

### image_pipe_server

```toml
[sources.originals]
adapter = "http"
match = { prefix = "originals" }
base_url = "https://images.example.com/originals"
path_pattern = '[a-zA-Z0-9_-]+\.(jpg|jpeg|png|webp)'
```

<!-- tabs-close -->

```text
/w=400/src/originals/beach.jpg  →  https://images.example.com/originals/beach.jpg
```

`path_pattern` is optional. Paths it doesn't match answer `404` before any
request to the origin. Without it, any path below the base URL is allowed.
To serve every bare path from the origin, set `match` to `path` instead of a
prefix.

## Accept URLs from listed hosts

List the hosts ImagePipe may download from, and match the URL schemes:

<!-- tabs-open -->

### Plug

```elixir
sources: [
  web: [
    adapter: ImagePipe.Source.HTTP,
    match: [scheme: "https"],
    options: [allowed_hosts: ["assets.example.com", "cdn.example.com"]]
  ]
]
```

### image_pipe_server

```toml
[sources.web]
adapter = "http"
match = { scheme = "https" }
allowed_hosts = ["assets.example.com", "cdn.example.com"]
```

<!-- tabs-close -->

The URL goes after `src/`, with any `?` written as `%3F` (see
[image paths](requesting-images.md#image-paths)):

```text
/w=400/src/https://assets.example.com/beach.jpg
```

Add `http` to `match` only if some hosts don't serve HTTPS. When the schemes
need different settings, use two sources.

## Authenticate to the origin

For an origin behind an API key or token, send it with every request:

<!-- tabs-open -->

### Plug

```elixir
options: [
  base_url: "https://images.example.com/originals",
  req_options: [
    headers: [{"x-api-key", System.fetch_env!("ORIGIN_API_KEY")}],
    auth: {:bearer, System.fetch_env!("ORIGIN_TOKEN")}
  ]
]
```

`req_options` takes `Req` options. `ImagePipe.Source.HTTP` lists the ones
the adapter drops.

### image_pipe_server

```toml
[sources.originals.request_headers]
x-api-key = "…"
```

Header names such as `x-api-key` contain `-`, which environment variable
names can't, so set `request_headers` in the file. A bearer token can come from a
secret file instead, with a `_FILE` variable (see
[environment variables](../../image_pipe_server/docs/server-configuration.md#environment-variables)):

```sh
IPS_SOURCES__ORIGINALS__BEARER_TOKEN_FILE=/run/secrets/origin_token
```

<!-- tabs-close -->

The origin must send the same bytes for the same URL on every request,
since cached originals and processed images are reused per URL. Headers
that select a variant, such as a different size or format, break that.

## Follow redirects

Redirects aren't followed by default, and the request fails with `502`. To
follow them, set `max_redirects`. Every redirect target must be in
`allowed_hosts`, so list the hosts the origin redirects to:

<!-- tabs-open -->

### Plug

```elixir
options: [
  base_url: "https://images.example.com/originals",
  allowed_hosts: ["images.example.com", "images-eu.example.com"],
  max_redirects: 2
]
```

### image_pipe_server

```toml
max_redirects = 2
allowed_hosts = ["images.example.com", "images-eu.example.com"]
```

<!-- tabs-close -->

With `base_url`, `allowed_hosts` must include the base URL's host.

## Allow a private origin

By default ImagePipe connects only to public internet addresses, so an
origin on your private network answers `404`. Allow the address range the
origin lives in:

<!-- tabs-open -->

### Plug

```elixir
options: [
  base_url: "http://images.internal/originals",
  address_policy: [allow: ["10.0.5.0/24"]]
]
```

### image_pipe_server

```toml
[sources.originals.address_policy]
allow = ["10.0.5.0/24"]
```

<!-- tabs-close -->

Allow the smallest range that works. Category switches such as
`allow_private` and the function form are listed under
[address policy](`m:ImagePipe.Source.HTTP#module-address-policy`), and
[Source network policy](source-network-policy.md) explains what the
default protects against.

## Confirm it works

Request an image through the source. If your URLs are signed, sign this one
too.

<!-- tabs-open -->

### Plug

```console
$ curl -s -o /dev/null -w '%{http_code} %{content_type}\n' http://localhost:4000/images/w=400/src/originals/beach.jpg
200 image/jpeg
```

### image_pipe_server

The server listens on port 8080 and serves from `/` unless `[server]` sets
another `port` or `mount_path`.

```console
$ curl -s -o /dev/null -w '%{http_code} %{content_type}\n' http://localhost:8080/w=400/src/originals/beach.jpg
200 image/jpeg
```

<!-- tabs-close -->

A `404` with `source not found` means the origin doesn't have the image, or
the source refused it: a host outside `allowed_hosts`, a path outside
`path_pattern`, or a private address. ImagePipe gives the same answer for
all of these. The source's [telemetry events](telemetry-events.md) carry
the reason in their `:error` metadata.

## Next steps

- [Caching processed images](caching-processed-images.md) keeps downloaded
  originals and resized copies.
- [Caching and freshness](caching-and-freshness.md) explains how the
  origin's cache headers set lifetimes.
- `ImagePipe.Source.HTTP` and the server's
  [`adapter = "http"` reference](../../image_pipe_server/docs/server-configuration.md#sources-name)
  list every option, including timeouts.
