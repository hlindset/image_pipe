# Image sources

Configure source mounts once and use their identifiers in URLs or in
`ImagePipe.run(config, plan, {:source, identifier})`. Only sources a mount
serves are available. Raw Elixir file/binary inputs are also supported; see
below.

## Mounts and routing

Each entry under `sources:` is a named mount: an adapter, the sources it
serves, and the adapter's options.

```elixir
config = ImagePipe.config(
  sources: [
    media: [
      adapter: ImagePipe.Source.File,
      match: [prefix: "media"],
      options: [root: "/srv/images", root_id: "media"]
    ],
    static: [
      adapter: ImagePipe.Source.File,
      match: :path,
      options: [root: "/srv/static", root_id: "static"]
    ],
    web: [
      adapter: ImagePipe.Source.HTTP,
      match: [scheme: ["http", "https"]],
      options: [allowed_hosts: ["assets.example.com"]]
    ]
  ]
)
```

`match` decides which sources reach the mount:

| Rule | Serves | Example source |
| --- | --- | --- |
| `[prefix: "media"]` | Paths whose first segment is `media`; the adapter sees the rest | `media/photos/beach.jpg` |
| `:path` | Paths no prefix matches | `photos/beach.jpg` |
| `[scheme: ["http", "https"]]` | HTTP(S) URL sources | `https://assets.example.com/beach.jpg` |
| `[scheme: "s3"]` | S3 object sources | `s3://bucket/beach.jpg` |
| `[scheme: "asset"]` | A custom scheme, served as a path | `asset://photos/beach.jpg` |

`prefix` and `scheme` each take a string or a list, and one mount can use
both. A prefix is a single path segment. A custom scheme is another spelling of
a prefix: `asset://photos/beach.jpg` reaches its mount as the path
`photos/beach.jpg`. Only `http`, `https`, and `s3` produce URL and object
sources.

Configuration fails when two mounts claim the same prefix or scheme, when more
than one mount matches `:path`, or when a rule would send an adapter a kind of
source it doesn't resolve (for example a File mount matching `https`). A prefix
always wins, so the `:path` mount can't serve a top-level folder named like a
prefix.

Paths with nothing after their prefix or scheme, or with empty, `.`, or `..`
segments, are rejected. A path no mount serves returns the same response as a
missing source. The mount name appears in [telemetry](telemetry.md) as
`:source_mount`, and each mount has its own cache entries.

## Local files

```elixir
config = ImagePipe.config(
  sources: [
    media: [
      adapter: ImagePipe.Source.File,
      match: :path,
      options: [root: "/srv/images", root_id: "media"]
    ]
  ]
)
```

The identifiers `photos/beach.jpg` and `/photos/beach.jpg` both select
`/srv/images/photos/beach.jpg` and produce the same generated URL. The optional
leading slash is normalized in Plug requests and `{:source, path}` execution.
The adapter confines paths to the configured root. `root_id` identifies that
source namespace. For immutable paths, `stable: :immutable` permits reuse based
on that promise; changed content must get a new identifier. The default
`:auto` stability does not assume immutability.

```text
/w=400/src/photos/beach.jpg
```

See `ImagePipe.Source.File` and [cache policy](cache.md) for adapter options.

## HTTP and HTTPS

```elixir
config = ImagePipe.config(
  sources: [
    web: [
      adapter: ImagePipe.Source.HTTP,
      match: [scheme: ["http", "https"]],
      options: [allowed_hosts: ["assets.example.com"]]
    ]
  ]
)

plan = ImagePipe.URL.new() |> ImagePipe.URL.group(resize: [width: 400])
{:ok, result} = ImagePipe.run(config, plan, {:source, "https://assets.example.com/beach.jpg"})
```

Match only `https` when plain HTTP isn't wanted, or use two mounts when the
schemes need different settings. The adapter rejects non-public addresses by
default and rechecks redirects. See [source network policy](source-network-policy.md)
for private origins, DNS, and connection pinning.

Generate remote-source URLs with `ImagePipe.URL.url!/3` so the source URL's own
escaping and query parameters survive the outer path encoding. Origin
freshness and validators govern [remote caching](cache.md).

### Serve paths from a base URL

Give an HTTP mount a `base_url` to serve paths from one origin, keeping the
origin out of your image URLs:

```elixir
config = ImagePipe.config(
  sources: [
    originals: [
      adapter: ImagePipe.Source.HTTP,
      match: [prefix: "originals", scheme: "originals"],
      options: [
        base_url: "https://images.example.com/originals",
        path_pattern: ~r/[a-zA-Z0-9_-]+\.(jpg|jpeg|png|webp)/,
        stable: :immutable
      ]
    ]
  ]
)
```

```text
/w=400/src/originals/beach.jpg          →  https://images.example.com/originals/beach.jpg
/w=400/src/originals%3A%2F%2Fbeach.jpg  →  https://images.example.com/originals/beach.jpg
```

Each path segment is percent-encoded and appended to the base URL, which must
be an HTTP(S) URL with a host and no query, fragment, or credentials. From
there the request is an ordinary HTTP fetch: the network policy, redirects,
freshness, and caching work as for a URL source. `allowed_hosts` defaults to
the base URL's host; list more hosts only to allow redirects to them.

The optional `path_pattern` regex must match the whole path the mount
receives, with segments joined by `/`; other paths return `404` before any
request to the origin. Without a pattern, any path below the base URL is
allowed. Match `:path` instead of a prefix to serve every bare path from the
origin.

## S3-compatible storage

Configure the shared bucket defaults and, optionally, per-bucket overrides:

```elixir
config = ImagePipe.config(
  sources: [
    buckets: [
      adapter: ImagePipe.Source.S3,
      match: [scheme: "s3"],
      options: [
        default: [
          region: "us-east-1",
          endpoint: "https://s3.us-east-1.amazonaws.com",
          credentials: {:static,
            access_key_id: System.fetch_env!("AWS_ACCESS_KEY_ID"),
            secret_access_key: System.fetch_env!("AWS_SECRET_ACCESS_KEY")}
        ]
      ]
    ]
  ]
)
```

Each effective bucket configuration requires credentials. Static credentials
accept an optional `token` for temporary sessions. Use
`{:provider, module, options}` with an `ImagePipe.Source.S3.CredentialProvider`
implementation for refreshable credentials. See `ImagePipe.Source.S3` for the
adapter and [S3 credential setup](s3-credentials.md) for
instance roles, container credentials, and STS providers. A `buckets` map,
when supplied, is an allowlist; each entry overrides `default` settings.

Identifiers use `s3://bucket/key` or `s3://bucket/key?revision`. The optional
revision is an S3 version ID, written as the entire query (`?3HL4kqtJlcpX`, not
`?versionId=3HL4kqtJlcpX`). The adapter requests that version, and the object
is then treated as immutable: it is cached without a freshness limit, though
storage still needs the origin's or your cache policy's permission. The store
must confirm the version with an `x-amz-version-id` response header; stores
that ignore version IDs fail the fetch with a 502 rather than serving the
current object as that version. A revision is not a cache-busting token: an
arbitrary string names a version that doesn't exist. Without a revision, the
object's `Cache-Control`, `ETag`, and `Last-Modified` govern caching as for
HTTP sources. Use the original identifier with `{:source, identifier}` or the
URL builder. Region, endpoint,
credentials, timeouts, and cache policy belong to the adapter.

## Source identity

Built-in HTTP and S3 `req_options` are host-owned behavior. They must not vary
source bytes for the same resolved identity. Byte-selecting request options need
URI/object revision material, `internal_cache: :disabled`, or a custom adapter
identity field.

## Custom adapters

Implement `ImagePipe.Source` when you need a new fetching/identity boundary.
The adapter declares the kinds of source it resolves with `source_kinds/0`,
and owns source access, cleanup, credentials, and source identity.
`ImagePipe.Source.CacheSettings` provides the standard `stable`,
`cache_policy`, `internal_cache`, and `http_cache` options and turns them into
the resolved cache fields, as the built-in adapters do. A custom
adapter that resolves paths can be mounted under a prefix, a custom scheme, or
both, so `asset://catalog/photo-123` and `assets/catalog/photo-123` can reach
the same adapter. See the [source contract](api_contract.md#sources) and the
behaviour reference. [Error responses](errors.md#custom-source-adapters)
describes how an adapter's error reasons become HTTP statuses.

## Direct files and uploads

```elixir
plan = ImagePipe.URL.new() |> ImagePipe.URL.group(resize: [width: 400])
{:ok, result} = ImagePipe.run(config, plan, {:file, "/tmp/upload.jpg"})
{:ok, result} = ImagePipe.run(config, plan, {:binary, uploaded_bytes})
```

These inputs need no mount and bypass input/output caches. Direct files
follow symlinks and resolve relative paths from the working directory; use
a File mount for root confinement. Both inputs obey source body and
decoded-pixel limits. Store uploads in an addressable source before
generating URLs for them.
