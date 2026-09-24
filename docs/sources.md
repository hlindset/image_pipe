# Image sources

Configure adapters once and use their identifiers in URLs or in
`ImagePipe.run(plan, {:source, identifier})`. Only configured source types are
available. Raw Elixir file/binary inputs are also supported; see below.

## Local files

```elixir
config = ImagePipe.config(
  sources: [
    path: {ImagePipe.Source.File, root: "/srv/images", root_id: "media"}
  ]
)
```

The identifiers `photos/beach.jpg` and `/photos/beach.jpg` both select
`/srv/images/photos/beach.jpg` and produce the same generated URL. The optional
leading slash is normalized in Plug requests and `{:source, path}` execution.
Repeated slashes and traversal segments remain subject to adapter validation.
The adapter confines paths to the configured root. `root_id` identifies that
source namespace. For immutable paths, `stable: :trusted` permits reuse based
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
    url: {ImagePipe.Source.HTTP, allowed_hosts: ["assets.example.com"]}
  ]
)

plan = ImagePipe.new(config) |> ImagePipe.group(resize: [width: 400])
{:ok, result} = ImagePipe.run(plan, {:source, "https://assets.example.com/beach.jpg"})
```

`:url` enables both schemes. Configure `:http` or `:https` separately when
only one is wanted or their settings differ. The adapter rejects non-public
addresses by default and rechecks redirects. See [source network policy](source-network-policy.md)
for private origins, DNS, and connection pinning.

Generate remote-source URLs with `ImagePipe.url!/2` so the source URL's own
escaping and query parameters survive the outer path encoding. Origin
freshness and validators govern [remote caching](cache.md).

## S3-compatible storage

Configure the shared bucket defaults and, optionally, per-bucket overrides:

```elixir
config = ImagePipe.config(
  sources: [
    s3: {ImagePipe.Source.S3,
         default: [
           region: "us-east-1",
           endpoint: "https://s3.us-east-1.amazonaws.com",
           credentials: {:static,
             access_key_id: System.fetch_env!("AWS_ACCESS_KEY_ID"),
             secret_access_key: System.fetch_env!("AWS_SECRET_ACCESS_KEY")}
         ]}
  ]
)
```

Each effective bucket configuration requires credentials. Static credentials
accept an optional `token` for temporary sessions. Use
`{:provider, module, options}` with an `ImagePipe.Source.S3.CredentialProvider`
implementation for refreshable credentials. See `ImagePipe.Source.S3` for the
adapter and [S3 credential setup](operational_notes.md#s3-credentials) for
instance roles, container credentials, and STS providers. A `buckets` map,
when supplied, is an allowlist; each entry overrides `default` settings.

Identifiers use `s3://bucket/key?revision`. The optional query is the entire
immutable revision value, not a `versionId=` parameter. Use the original
identifier with `{:source, identifier}` or the URL builder. Region, endpoint,
credentials, timeouts, and cache policy belong to the adapter.

## Application identifiers and custom adapters

Use `source_schemes: %{"asset" => {MyApp.AssetSource, options}}` to translate an
application scheme such as `asset://catalog/photo-123`. Implement
`ImagePipe.Source.Scheme` to translate the decoded identifier into one of the
canonical source values. Built-in `http`, `https`, and `s3` cannot be replaced
by scheme translators.

Implement `ImagePipe.Source` when you need a new fetching/identity boundary.
The adapter owns source access, cleanup, credentials, and source identity.
See the [source contract](api_contract.md#sources) and the behaviour reference.

## Direct files and uploads

```elixir
plan = ImagePipe.new() |> ImagePipe.group(resize: [width: 400])
{:ok, result} = ImagePipe.run(plan, {:file, "/tmp/upload.jpg"})
{:ok, result} = ImagePipe.run(plan, {:binary, uploaded_bytes})
```

These inputs need no adapter and bypass input/output caches. Direct files
follow symlinks and resolve relative paths from the working directory; use
the configured file adapter for root confinement. Both inputs obey source
body and decoded-pixel limits. Store uploads in an addressable source before
generating URLs for them.

Next: [URL source encoding](urls.md#source-encoding), [shared usage](combined-usage.md),
or [source configuration](configuration.md#sources-caches-and-url-protection).
