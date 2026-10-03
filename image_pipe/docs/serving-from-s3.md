# Serving images from S3

Serve originals from Amazon S3 or S3-compatible storage, such as MinIO or
Cloudflare R2, in private buckets. This guide assumes ImagePipe is running in
your app (see [Plug usage](plug-usage.md)) or as `image_pipe_server` (see
[getting started with the server](../../image_pipe_server/docs/server-getting-started.md)).

## Add an S3 source

Give the source the bucket's region and endpoint, and credentials allowed to
read objects (`s3:GetObject`):

<!-- tabs-open -->

### Plug

```elixir
sources: [
  media: [
    adapter: ImagePipe.Source.S3,
    match: [scheme: "s3"],
    options: [
      default: [
        region: "eu-west-1",
        endpoint: "https://s3.eu-west-1.amazonaws.com",
        credentials: {:provider, ImagePipe.Source.S3.InstanceRole, []}
      ]
    ]
  ]
]
```

### image_pipe_server

```toml
[sources.media]
adapter = "s3"
match = { scheme = "s3" }
region = "eu-west-1"
endpoint = "https://s3.eu-west-1.amazonaws.com"
credentials = { provider = "instance_role" }
```

<!-- tabs-close -->

For other S3-compatible stores, set `endpoint` to their API URL. Objects are
requested path-style, as `<endpoint>/<bucket>/<key>`. Image URLs name an
object after `src/` as `s3://bucket/key`:

```text
/w=400/src/s3://my-bucket/photos/beach.jpg
```

## Choose credentials

Pick the credentials that match where ImagePipe runs:

- [Static keys](#use-static-keys) work anywhere, including outside AWS.
- [An EC2 instance role](#use-an-ec2-instance-role) on EC2 and Elastic
  Beanstalk.
- [Container credentials](#use-container-credentials) on ECS and Fargate.
- [A service account role](#use-an-eks-service-account-role) on EKS.
- [An assumed role](#assume-a-role-in-another-account) for a bucket in
  another account.

ImagePipe refreshes temporary credentials before they expire, and never
sends expired ones. If they can't be refreshed, requests fail with `500`
until they can.

## Use static keys

<!-- tabs-open -->

### Plug

```elixir
credentials:
  {:static,
   access_key_id: System.fetch_env!("AWS_ACCESS_KEY_ID"),
   secret_access_key: System.fetch_env!("AWS_SECRET_ACCESS_KEY")}
```

For temporary keys, add `token: System.fetch_env!("AWS_SESSION_TOKEN")`.
Leave `token` out when there is none, since a `nil` token fails the
configuration.

### image_pipe_server

Remove `credentials` from the file, and set the keys with environment
variables, reading the secret from a file:

```sh
IPS_SOURCES__MEDIA__CREDENTIALS__STATIC__ACCESS_KEY_ID=AKIA…
IPS_SOURCES__MEDIA__CREDENTIALS__STATIC__SECRET_ACCESS_KEY_FILE=/run/secrets/s3_secret
```

For temporary keys, also set
`IPS_SOURCES__MEDIA__CREDENTIALS__STATIC__TOKEN`.

<!-- tabs-close -->

## Use an EC2 instance role

Attach a role that can read the bucket to the instance. ImagePipe reads its
credentials from the instance metadata service (IMDSv2):

<!-- tabs-open -->

### Plug

```elixir
credentials: {:provider, ImagePipe.Source.S3.InstanceRole, []}
```

### image_pipe_server

```toml
credentials = { provider = "instance_role" }
```

<!-- tabs-close -->

## Use container credentials

Give the ECS task a task role that can read the bucket. ECS sets
`AWS_CONTAINER_CREDENTIALS_RELATIVE_URI` in the container, and ImagePipe
needs its value:

<!-- tabs-open -->

### Plug

```elixir
credentials:
  {:provider, ImagePipe.Source.S3.ContainerCredentials,
   relative_uri: System.fetch_env!("AWS_CONTAINER_CREDENTIALS_RELATIVE_URI")}
```

If the platform sets `AWS_CONTAINER_CREDENTIALS_FULL_URI` instead, pass it
as `full_uri:`, with the token from `AWS_CONTAINER_AUTHORIZATION_TOKEN` as
`auth_token:`.

### image_pipe_server

```toml
credentials = { provider = "container_credentials" }
```

The server doesn't read `AWS_` variables, so the value has to be copied
into the setting when the container starts. The image's entrypoint starts
the server directly. Replace it with a shell that sets the variable first,
as in this excerpt of an ECS container definition:

```json
"entryPoint": ["sh", "-c"],
"command": [
  "IPS_SOURCES__MEDIA__CREDENTIALS__RELATIVE_URI=\"$AWS_CONTAINER_CREDENTIALS_RELATIVE_URI\" exec /app/bin/image_pipe_server start"
]
```

<!-- tabs-close -->

## Use an EKS service account role

With IAM roles for service accounts (IRSA), EKS mounts a token file into the
pod. ImagePipe exchanges it for credentials of the service account's role:

<!-- tabs-open -->

### Plug

```elixir
credentials:
  {:provider, ImagePipe.Source.S3.WebIdentity,
   token_file: System.fetch_env!("AWS_WEB_IDENTITY_TOKEN_FILE"),
   role_arn: System.fetch_env!("AWS_ROLE_ARN"),
   region: System.fetch_env!("AWS_REGION")}
```

### image_pipe_server

```toml
[sources.media.credentials]
provider = "web_identity"
token_file = "/var/run/secrets/eks.amazonaws.com/serviceaccount/token"
role_arn = "arn:aws:iam::123456789012:role/image-read"
region = "eu-west-1"
```

<!-- tabs-close -->

## Assume a role in another account

To read a bucket in another account, assume a role there that can read it.
The `base` credentials, any of the forms above, must be allowed to assume
the role:

<!-- tabs-open -->

### Plug

```elixir
credentials:
  {:provider, ImagePipe.Source.S3.AssumeRole,
   base: {:provider, ImagePipe.Source.S3.InstanceRole, []},
   role_arn: "arn:aws:iam::123456789012:role/image-read",
   external_id: "image-pipe",
   region: "eu-west-1"}
```

### image_pipe_server

```toml
[sources.media.credentials]
provider = "assume_role"
base = { provider = "instance_role" }
role_arn = "arn:aws:iam::123456789012:role/image-read"
external_id = "image-pipe"
region = "eu-west-1"
```

<!-- tabs-close -->

`external_id` is needed only when the role's trust policy requires one.

## Serve only some buckets

By default the source serves any bucket the credentials can read. List
buckets to serve only those. Each one can override the source's settings,
such as its region or credentials:

<!-- tabs-open -->

### Plug

```elixir
options: [
  default: [
    region: "eu-west-1",
    endpoint: "https://s3.eu-west-1.amazonaws.com",
    credentials: {:provider, ImagePipe.Source.S3.InstanceRole, []}
  ],
  buckets: %{
    "photos" => [],
    "archive" => [
      region: "us-east-1",
      endpoint: "https://s3.us-east-1.amazonaws.com"
    ]
  }
]
```

### image_pipe_server

```toml
[sources.media.buckets.photos]

[sources.media.buckets.archive]
region = "us-east-1"
endpoint = "https://s3.us-east-1.amazonaws.com"
```

<!-- tabs-close -->

Other buckets then answer `404`.

## Fetch credentials at startup

Credentials from a provider are fetched on the first request for each
bucket, which adds a round trip to that request. To fetch them at startup
instead:

<!-- tabs-open -->

### Plug

Add a `ImagePipe.Source.S3.CredentialWarmup` per bucket to your supervision
tree, with the same provider and options as the source:

```elixir
# lib/my_app/application.ex
children = [
  {ImagePipe.Source.S3.CredentialWarmup,
   provider: ImagePipe.Source.S3.InstanceRole, opts: [], scope: "photos"},
  MyAppWeb.Endpoint
]
```

To warm more than one bucket, give each child its own id with
`Supervisor.child_spec/2`.

### image_pipe_server

The server fetches credentials at startup for each bucket listed under
`buckets` whose credentials come from a provider.

> #### One warmed bucket per server {: .warning}
>
> Two or more such buckets stop the server at boot, because their warmup
> processes share one id. List at most one bucket with provider
> credentials, or leave `buckets` out.

<!-- tabs-close -->

A failed fetch at startup is retried by the first request. Credentials that
no request uses are dropped after five to ten minutes, and the next request
fetches them again.

## Request object versions

In a bucket with versioning on, add a version ID as the whole query to
request that version, written `?` as `%3F`:

```text
/w=400/src/s3://my-bucket/photos/beach.jpg%3F3HL4kqtJlcpX
```

A versioned object never changes, so cached images made from it are served
without checking S3 (see
[write-once sources](caching-and-freshness.md#write-once-sources)). If the
store ignores version IDs, the request fails with `502` rather than serving
the current object.

## Confirm it works

Request an object through the source. If your URLs are signed, sign this
one too.

<!-- tabs-open -->

### Plug

```console
$ curl -s -o /dev/null -w '%{http_code} %{content_type}\n' http://localhost:4000/images/w=400/src/s3://my-bucket/photos/beach.jpg
200 image/jpeg
```

### image_pipe_server

The server listens on port 8080 and serves from `/` unless `[server]` sets
another `port` or `mount_path`.

```console
$ curl -s -o /dev/null -w '%{http_code} %{content_type}\n' http://localhost:8080/w=400/src/s3://my-bucket/photos/beach.jpg
200 image/jpeg
```

<!-- tabs-close -->

A missing object, or one the credentials can't read, answers `404`. A `500`
can mean the credentials couldn't be fetched.

## Next steps

- [Caching processed images](caching-processed-images.md) keeps downloaded
  originals and resized copies.
- `ImagePipe.Source.S3`, its credential providers, and the server's
  [`adapter = "s3"` reference](../../image_pipe_server/docs/server-configuration.md#sources-name)
  list every option.
