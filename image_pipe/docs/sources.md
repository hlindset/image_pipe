# Image sources

A source is a place ImagePipe reads original images from: a directory, an
HTTP origin, an S3 bucket, or a store of your own. Each source has a name,
an adapter that reads it, `match` rules for which image paths reach it, and
the adapter's options. Image URLs name the image after `src/`, and the
source whose rules match it serves the request.

## Routing image paths to sources

These sources serve paths under `media/` from one directory, other paths
from a second directory, and full HTTPS URLs from one host:

<!-- tabs-open -->

### Plug

```elixir
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
```

### image_pipe_server

```toml
[sources.media]
adapter = "file"
match = { prefix = "media" }
root = "/srv/images"
root_id = "media"

[sources.static]
adapter = "file"
match = "path"
root = "/srv/static"
root_id = "static"

[sources.web]
adapter = "http"
match = { scheme = ["http", "https"] }
allowed_hosts = ["assets.example.com"]
```

<!-- tabs-close -->

The match rules are the same on both surfaces:

| Rule | Serves | Example source |
| --- | --- | --- |
| `prefix` `media` | Paths whose first segment is `media`. The adapter receives the rest. | `media/photos/beach.jpg` |
| `path` | Paths that no prefix matches | `photos/beach.jpg` |
| `scheme` `http`, `https` | HTTP and HTTPS URLs | `https://assets.example.com/beach.jpg` |
| `scheme` `s3` | S3 objects | `s3://bucket/beach.jpg` |
| `scheme` `asset` | A custom scheme, served as a path | `asset://photos/beach.jpg` |

`prefix` and `scheme` each take one value or a list, and one source can have
both. A prefix is a single path segment. A custom scheme is another spelling
of a prefix: `asset://photos/beach.jpg` reaches its source as the path
`photos/beach.jpg`. Only `http`, `https`, and `s3` select URL and object
sources.

A prefix always wins, so the `path` source can't serve a top-level folder
named like a prefix. Each source has its own cache entries, even when two
sources read the same files. The source's name appears in
[telemetry events](telemetry-events.md#common-metadata) as `:source_mount`.

Requests that no source serves fail:

- A path that no source matches answers `404 source not found`, like a
  missing image. So does a path with nothing after its prefix or scheme, or
  with an empty, `.`, or `..` segment.
- A `scheme://` URL that no source matches, including `http`, `https`, and
  `s3`, answers `400 invalid source`.

The configuration fails to load when two sources claim the same prefix or
scheme, when more than one source matches `path`, or when a source matches
requests its adapter can't serve, such as a file source matching `https`,
an S3 source matching a prefix, or an HTTP source without a `base_url`
matching paths or a custom scheme.

## Adapters

| Adapter | Serves | Setup guide | Options |
| --- | --- | --- | --- |
| Local files | A directory on the ImagePipe host | [Serving images from local files](serving-local-files.md) | `ImagePipe.Source.File`, [`adapter = "file"`](../../image_pipe_server/docs/server-configuration.md#sources-name) |
| HTTP | Paths on one origin, or URLs from listed hosts | [Serving images from an HTTP origin](serving-from-http.md) | `ImagePipe.Source.HTTP`, [`adapter = "http"`](../../image_pipe_server/docs/server-configuration.md#sources-name) |
| S3 | Objects in S3 and S3-compatible storage | [Serving images from S3](serving-from-s3.md) | `ImagePipe.Source.S3`, [`adapter = "s3"`](../../image_pipe_server/docs/server-configuration.md#sources-name) |
| Custom | Any store your Elixir code can read | [Writing a custom source](custom-sources.md) | `ImagePipe.Source` |

Every adapter also takes the cache settings in
`ImagePipe.Source.CacheSettings`, explained in
[Caching and freshness](caching-and-freshness.md). In Elixir code,
`ImagePipe.run/4` reads the same sources, and also takes a file or bytes
that no source serves.
