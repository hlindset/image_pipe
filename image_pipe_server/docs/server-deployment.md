# Deploying image_pipe_server

`image_pipe_server` runs as a Docker image that you configure with a TOML
file and environment variables. The
[configuration reference](server-configuration.md) lists every setting.

## Images

There are two variants:

- `ghcr.io/hlindset/image_pipe_server:0.3`, without content-aware detection.
- `ghcr.io/hlindset/image_pipe_server:0.3-vision`, which adds face and object
  detection with the models baked into the image, so detection works without
  network access at runtime.

Both read every input format ImagePipe supports, including JPEG XL.

The `0.3` tags move to each new 0.3 patch release, so pulling them again
picks up fixes. To pin one release, use its full version, such as `0.3.0` or
`0.3.0-vision`.

The `-vision` image loads the models for every detection class when it
starts. To save memory, load only the ones your URLs use by setting
[`detector_warmup`](server-configuration.md#processing) in `[processing]`,
such as `detector_warmup = ["face"]`.

To build an image yourself, run from the repository root, since the server
depends on its sibling projects. Add `--build-arg IMAGE_VISION=1` for the
detection variant:

```bash
docker build -f image_pipe_server/Dockerfile -t image_pipe_server .
```

The image runs as user `image_pipe` (uid 10001), listens on port 8080, and
checks `GET /health/ready` for its Docker health status.

## Running

To try the server locally first, follow
[Getting started with the server](server-getting-started.md).

Mount the configuration file at `/etc/image_pipe/config.toml` (or name
another path with `IPS_CONFIG`), mount your images, and give caches a volume:

```bash
docker run --read-only --tmpfs /tmp -p 8080:8080 -v ./config.toml:/etc/image_pipe/config.toml:ro -v ./images:/data/images:ro -v image-cache:/var/cache/image_pipe ghcr.io/hlindset/image_pipe_server:0.3
```

- On a platform that can't mount files, pass the file's contents in
  `IPS_CONFIG_TOML` instead, such as
  `-e IPS_CONFIG_TOML="$(cat config.toml)"`.
- The server writes only to `/tmp` and to cache directories, so the root
  filesystem can be read-only. Mount `/tmp` as a `tmpfs`.
- Put caches under `/var/cache/image_pipe`, which is writable by the server's
  user. Give each container its own cache volume. A container that finds
  another container using its cache runs without that cache and logs an
  error.
- Make your images and their directories readable by uid 10001, for example
  with `chmod -R a+rX images`. A request for a file the server can't read
  gets `500` with the body `source unavailable`.
- Pass secrets as `_FILE` variables pointing at mounted secret files, for
  example `IPS_URL__KEYS_FILE=/run/secrets/signing_keys`.

With Docker Compose:

```yaml
services:
  images:
    image: ghcr.io/hlindset/image_pipe_server:0.3
    read_only: true
    tmpfs:
      - /tmp
    ports:
      - "8080:8080"
    stop_grace_period: 25s
    environment:
      IPS_URL__KEYS_FILE: /run/secrets/signing_keys
    secrets:
      - signing_keys
    volumes:
      - ./config.toml:/etc/image_pipe/config.toml:ro
      - ./images:/data/images:ro
      - image-cache:/var/cache/image_pipe

secrets:
  signing_keys:
    file: ./signing_keys

volumes:
  image-cache:
```

## HTTP

The server speaks plain HTTP/1.1. Terminate TLS at a load balancer, ingress,
or CDN in front of it, and have it connect to the server with HTTP/1.1.

- `[server] read_timeout` (10 seconds) closes connections that send nothing
  for that long, including idle keep-alive connections. A connection that
  hasn't finished sending a request gets a `408` first.
- `[server] max_connections` (2048) caps concurrent connections. Beyond it,
  new connections wait up to five seconds for room, then are closed.
- `[server] auth_token` requires `Authorization: Bearer <token>` on every
  request except the health checks and the
  [cache stats](#cache-stats), answering `401` otherwise. A request outside
  the mount path also gets `401` without the token. The token
  needs at least 32 characters. Use `auth_token` when a trusted edge adds
  the header, for example with unsigned URLs. Pass it as a secret:
  `IPS_SERVER__AUTH_TOKEN_FILE=/run/secrets/auth_token`.

## Health and shutdown

The server has two health checks:

- `GET /health/live` answers `200 ok` while the server runs. Use it where a
  failed check restarts the server, such as a Kubernetes liveness probe.
- `GET /health/ready` answers `200 ok` while the server takes traffic, and
  `503` while it starts up, while it shuts down, and while its image
  processing restarts after a crash. Use it where a failed check stops traffic, such
  as a Kubernetes readiness probe, a proxy's active health check (Caddy,
  Traefik), or a platform that routes on Docker's health status, such as
  [uncloud](https://uncloud.run).

Invalid configuration stops the server before it listens, so neither check
passes with a configuration the server rejected.

Both checks share the image listener and its `max_connections`, so under
heavy load a check can wait for a free connection and time out. For
readiness that moves traffic to other replicas, as it should. Set
`[server] health_port` to also serve the checks on a separate listener with
its own small connection cap, and point liveness checks there, so load can't
fail them.

The health listener takes at most 16 connections, so clients that hold
them open can fail the checks on it. Let only the health checker reach
`health_port`: don't publish the port outside the host or cluster, or set
`[server] health_bind` to an internal IP address. To bind a pod's own
address, set `IPS_SERVER__HEALTH_BIND` from the pod's IP.

On `SIGTERM` the server shuts down in two steps:

1. For `[server] shutdown_delay` milliseconds (default 5 seconds),
   `/health/ready` answers `503`, but the server keeps serving. Every
   response closes its connection. Load balancers notice and move traffic to
   other replicas before then.
2. The server stops accepting connections and gives in-flight requests
   `[server] shutdown_timeout` milliseconds (default 15 seconds) to finish.

Give the platform a grace period longer than both together (20 seconds by
default), or it kills requests first. Docker's default is 10 seconds. Raise
it with `docker stop -t 25` or `stop_grace_period` in Compose. Kubernetes'
default is 30 seconds (`terminationGracePeriodSeconds`). With no load
balancer in front, set `shutdown_delay = 0`.

The image's Docker health check requests `/health/ready` on `127.0.0.1` every
two seconds, so the container turns unhealthy within the default delay. It
uses the port in `IPS_SERVER__HEALTH_PORT` when that names a fixed port, and
otherwise the one in `IPS_SERVER__PORT` (8080 when it's unset). With a health
port, load can't fail the check, so platforms that restart unhealthy
containers, such as Docker Swarm, don't restart a busy server. The check
reads only these variables, not the ports in the file or `_FILE` variables. If the server doesn't
listen on `127.0.0.1`, such as when `[server] bind` names one specific
address, override the check in Compose:

```yaml
services:
  images:
    healthcheck:
      test: ["CMD", "curl", "-fsS", "http://10.0.0.5:8080/health/ready"]
```

## Kubernetes

```yaml
spec:
  terminationGracePeriodSeconds: 30
  securityContext:
    runAsNonRoot: true
    runAsUser: 10001
  containers:
    - name: images
      image: ghcr.io/hlindset/image_pipe_server:0.3
      ports:
        - containerPort: 8080
        - containerPort: 8081
      env:
        - name: IPS_URL__KEYS_FILE
          value: /run/secrets/image-pipe/signing_keys
        - name: IPS_SERVER__HEALTH_PORT
          value: "8081"
      readinessProbe:
        httpGet:
          path: /health/ready
          port: 8080
      livenessProbe:
        httpGet:
          path: /health/live
          port: 8081
      securityContext:
        readOnlyRootFilesystem: true
      volumeMounts:
        - name: config
          mountPath: /etc/image_pipe
          readOnly: true
        - name: secrets
          mountPath: /run/secrets/image-pipe
          readOnly: true
        - name: cache
          mountPath: /var/cache/image_pipe
        - name: tmp
          mountPath: /tmp
  volumes:
    - name: config
      configMap:
        name: image-pipe-config
    - name: secrets
      secret:
        secretName: image-pipe
    - name: cache
      emptyDir: {}
    - name: tmp
      emptyDir:
        medium: Memory
```

The `emptyDir` gives each pod its own cache. Don't replace it with a volume
that pods share (see
[Run several replicas](../../image_pipe/docs/caching-processed-images.md#run-several-replicas)).

## Caches

To set up `[cache.output]` for processed images and its size limit, see
[Caching processed images](../../image_pipe/docs/caching-processed-images.md).

Whether a response is cached also depends on its source:

- HTTP and S3 sources follow the origin's cache headers by default. Set
  `cache_policy` to override them.
- File sources check each file for changes. Set `stable = "immutable"` for
  [immutable](../../image_pipe/docs/caching-and-freshness.md#immutable-sources)
  files to skip the check.
- A file source's `root_id` is part of the cache key of every result from that
  source. Keep it the same across restarts and replicas, or cached results
  aren't reused. The `root` path can differ between replicas or change over
  time.

### Cache stats

`GET /stats` reports the bytes and entries each cache holds, how often
requests find what they need in the cache, the space left on the cache's
disk, and how many originals the server remembers in memory.
`GET /metrics` reports the same numbers for Prometheus.

Turn both on in `[stats]`, with a token of their own. Use a token of at
least 32 characters, such as the output of `openssl rand -hex 16`:

```toml
[stats]
enabled = true
token = "3b9f6c1e8a2d4f7b0c5e9a1d6f2b8c4e"
```

To keep the token out of the file, set `IPS_STATS__TOKEN`, or pass it as a
secret with `IPS_STATS__TOKEN_FILE=/run/secrets/stats_token`.
The stats token is separate from `[server] auth_token`, and each opens only
its own endpoints. To serve the stats on the health listener as well, set
[`health_port`](server-configuration.md#server).

Check that it works:

```bash
curl -H "Authorization: Bearer 3b9f6c1e8a2d4f7b0c5e9a1d6f2b8c4e" http://localhost:8080/stats
```

```json
{
  "output": {
    "bytes": 812345678, "max_bytes": 1073741824, "entries": 5120,
    "counting": false, "hits": 9120, "misses": 1310, "read_errors": 0,
    "remembered_entries": 3100, "max_remembered_entries": 21474,
    "available": true, "refused": false,
    "disk_free_bytes": 40213000000, "disk_total_bytes": 107374182400,
    "disk_age_seconds": 4
  },
  "originals": { "entries": 4800, "max_entries": 21474 }
}
```

- `hits` and `misses` count this replica's requests since it started, each
  request once. `read_errors` are stored entries the cache couldn't read,
  also counted as misses.
- `remembered_entries` is how many recently served entries the cache keeps
  in memory, up to `max_remembered_entries`. A hit on one of them reads
  less from disk.
  `originals` counts the originals the server remembers, up to
  [`max_remembered_originals`](server-configuration.md#cache). In
  `/metrics` these are `image_pipe_cache_remembered_entries`,
  `image_pipe_cache_max_remembered_entries`,
  `image_pipe_remembered_originals`, and
  `image_pipe_max_remembered_originals`.
- `counting` is `true` for a short time after startup, while the cache
  counts the entries an earlier run left on disk. Until then, `bytes` and
  `entries` leave out the ones it hasn't reached.
- `disk_free_bytes` and `disk_total_bytes` are for the filesystem that
  holds the cache's `root` directory, such as the volume mounted there.
  The server reads them with `df` every 15 seconds, and both endpoints
  answer with the last sizes it read. `disk_age_seconds` is how many
  seconds ago that was. It grows past 15 when `df` fails or hangs, such as
  on a network volume that stopped answering. All three are `null` until
  the first read succeeds.
- A cache whose `root` another replica
  [owns](../../image_pipe/docs/cache.md#cache-root-owner-file) isn't used by
  this replica. It has `"refused": true`, `max_bytes`, and the disk sizes.
  In `/metrics` it has only `image_pipe_cache_refused`,
  `image_pipe_cache_max_bytes`, and the disk metrics.
- A cache that doesn't report its size within a second, such as while it
  restarts after a crash or is busy evicting entries, has
  `"available": false`. It has `max_bytes`, `hits`, `misses`,
  `read_errors`, and the disk sizes, but no `bytes`, `entries`, or
  `counting`. In `/metrics`, `image_pipe_cache_available` is `0` and
  `image_pipe_cache_bytes`, `image_pipe_cache_entries`, and
  `image_pipe_cache_counting` are missing for that cache. Every other cache
  that isn't refused has `"available": true`, and
  `image_pipe_cache_available` is `1`.
- A cache that isn't configured isn't listed.

`/metrics` leaves the disk metrics out until the first read succeeds.
`image_pipe_cache_disk_age_seconds` gives the age, so an alert on a value
well above 15, such as 120, catches a `df` that stopped answering.

Both endpoints answer `503` while image processing isn't running: early in
startup, late in shutdown, and while it restarts after a crash.

To collect the numbers with Prometheus, put the token alone in a file, such
as `/etc/prometheus/image-pipe-stats-token`, and name it in the scrape
configuration. The metrics are named `image_pipe_cache_*` and carry a
`cache` label:

```yaml
scrape_configs:
  - job_name: image_pipe_server
    authorization:
      credentials_file: /etc/prometheus/image-pipe-stats-token
    static_configs:
      - targets: ["image-server:8080"]
```

Once the target shows as up on Prometheus's Targets page,
`image_pipe_cache_bytes` returns each cache's size. This query gives each
cache's hit rate over the last five minutes:

```text
sum by (cache) (rate(image_pipe_cache_lookups_total{result="hit"}[5m]))
  / sum by (cache) (rate(image_pipe_cache_lookups_total[5m]))
```

## DNS lookups

An HTTP source keeps the addresses an origin's hostname resolves to for 10
seconds, whatever the record's TTL, so a busy origin is looked up about once
every 10 seconds instead of for every request. Each lookup asks for the IPv4
and IPv6 addresses at the same time, through the resolver in the container's
`/etc/resolv.conf`. When none of the addresses accepts a connection or
answers in time, the source looks the hostname up again.

A dropped DNS reply holds every request waiting on that lookup for at least
the resolver's timeout, 5 seconds by default. That wait counts toward the
source's [`fetch_timeout`](server-configuration.md#sources-name), 30 seconds
by default. To make such waits rarer, point the container at a caching
resolver close to the server, such as one on the host.

If the resolver in `/etc/resolv.conf` already caches and its TTLs should
apply exactly, turn off the source's cache:

```toml
[sources.web]
adapter = "http"
match = { scheme = "https" }
allowed_hosts = ["images.example.com"]
dns_cache = false
```

With `dns_cache = false`, the source looks the hostname up for every request
to the origin, including a check whether a cached original is still current
and each redirect it follows.

On Kubernetes, CoreDNS already caches answers, so you can set
`dns_cache = false`. The default `ndots: 5` sends each lookup of a name such as
`images.example.com` through every cluster search domain, once for IPv4 and
once for IPv6 addresses, before looking it up as written. When the origins
are outside the cluster, lower `ndots` in the pod spec:

```yaml
spec:
  dnsConfig:
    options:
      - name: ndots
        value: "1"
```

With `ndots: 1`, give cluster services their full names, such as
`minio.storage.svc.cluster.local`, in `base_url` and `allowed_hosts`. A
shorter name such as `minio.storage` is first looked up outside the cluster,
which adds a failed lookup before each successful one.

## Processing capacity

The server processes as many images at once as it has CPU cores, counting a
container's CPU limit, and up to 1,024 more requests wait for a turn. A request
that finds the queue full, or waits longer than `queue_timeout` (10 seconds),
gets a `503`. Change the limits with `max_concurrency`, `max_queue`, and
`queue_timeout` in `[pool]`. See
[limiting concurrent processing](../../image_pipe/docs/processing-controls.md).

Each image also uses several threads in libvips, the image library. Under a
container CPU limit, the server sets `VIPS_CONCURRENCY` to that limit, rounded
up, which sets how many threads libvips uses for each image. Set
`VIPS_CONCURRENCY` yourself to change it.

## Memory allocator

The Docker image runs the server with the jemalloc memory allocator, set
with `MALLOC_CONF=background_thread:true` so it returns memory that image
processing frees, even while the server is idle. glibc's default allocator
keeps much of it. After a burst of requests, most of the memory the burst
used goes back to the system within about 15 seconds. If you set
`MALLOC_CONF` yourself, it replaces this value, so include
`background_thread:true` in it. Set `IMAGE_PIPE_ALLOCATOR=glibc` to use glibc
instead. The server also
uses glibc when jemalloc can't load on the host, and logs a line saying so.
With glibc, the server sets
`MALLOC_ARENA_MAX=2`, which limits how much freed memory glibc keeps, unless
you set it yourself.

## Code loading

The server loads its code when it first needs it rather than all at
startup, which keeps about 140 MiB less in memory. Before it reports ready,
it processes a small image in each output format, so requests don't wait for
the image-processing code to load or for an encoder to start. The first
request still takes a few tens of milliseconds longer than later ones. Set
`RELEASE_MODE=embedded` to load everything at startup instead.

## Detection

Face and object detection need the `-vision` image. Enabling it,
requiring it, and checking that it runs are covered in
[Enabling face and object detection](../../image_pipe/docs/enabling-detection.md).

## Logging

The server logs one line per image request: the method, path, status,
duration, and bytes sent, then what the request did as `key=value` fields.

```text
2026-10-15 21:42:21.809 request_id=GN7LZj3hjwjJ8MUAAAAB [info] GET /w=200/src/REDACTED 200 79ms 4.7kB source_url=beach.jpg cache=miss source=static source_fetch=ok fetch_ms=1 input=jpeg input_size=4000x2667 decode_ms=4 ops=resize output=jpeg output_size=200x133 encode_ms=6 admission=admitted queue_ms=0
2026-10-15 21:42:21.832 request_id=GN7LZkQkDAOjtZsAAACB [warning] GET /w=200/src/REDACTED 404 1ms source_url=missing.jpg error=source reason="source not found" source=static source_fetch=source_error fetch_ms=0
```

A `5xx`, or a response that failed partway through sending, logs at
`error`. A `4xx` logs at `warning`, and so does a result that didn't come
out as requested, such as a crop that used attention because detection
failed or no detector is configured, or an image scaled down to the limits.
A [low-priority request](../../image_pipe/docs/processing/request.md#priority)
that the full processing pool turned away logs its `503` at `info`. A
request without a valid
[`auth_token`](server-configuration.md#server) logs its `401` at `warning`,
and a path outside [`mount_path`](server-configuration.md#server) logs its
`404` at `info`. These two lines have only the method, path, status, and
duration. Health checks and stats requests aren't logged. The
[`[:request, :summary]`](../../image_pipe/docs/telemetry-events.md#request-summary)
event lists the fields.

The path is logged with `mount_path`, and ends at the source: the `src`,
`src64`, or `enc` segment is followed by `REDACTED`, and each `wm-src64=`
value is `REDACTED`. The source follows as a `source_url=` field, decoded
from `src64` or decrypted from `enc`, with each query value, such as a
presigned URL's `X-Amz-Signature`, replaced with `REDACTED`. A watermark
given by its source URL (`wm-src64=`, `wm-enc=`, or a preset) gets a
`watermark_source_url=` field the same way. A request that fails before its
URL parses, such as one with a bad signature, has no `source_url=` field.

Change what's logged in `[telemetry]`:

- `log_level` is the lowest level the server logs, `"info"` by default.
  `"warning"` keeps only failed and degraded requests, and failed cache
  reads and writes.
- `log_requests = false` turns the request lines off.
- With `log_requests` on, `log_stages = true` also logs a line for each stage
  of each request, such as each cache lookup, the decode, and the encode,
  for debugging.
- `log_format` writes each line as one JSON object instead of text:
  `"json"`, or `"gcp"`, `"datadog"`, or `"elastic"` for those collectors'
  field names. The request's fields are under an `image_pipe` key, next to
  `request_id`.
- `log_colors = true` colors `text` lines by level. Lines are plain by
  default, so a host that attaches a terminal to the container, such as
  `docker run -t`, doesn't store color codes.

The request log can miss lines under heavy load, so count requests at the
CDN, or count cache hits and misses with [`/metrics`](#cache-stats). Requests
never wait for their log line. When requests log faster than the server can
write, or than the log collector reads the container's output, lines queue
up. Once 10,000 are waiting, new lines are dropped until the queue is below
that again. Cache hits are the likeliest to fill the queue, since they are
the cheapest requests. The server logs a `notice` line when it starts
dropping lines and another when it stops, at any `log_level`:

```text
2026-10-15 21:42:22.104 [notice] Handler :default switched from :async to :drop mode
2026-10-15 21:42:22.391 [notice] Handler :default switched from :drop to :async mode
```

Under sustained overload the pair repeats each time the queue crosses
10,000 lines.

Every response carries an `x-request-id` header, and every log line for that
request is tagged `request_id=<id>`. The server generates the ID. Behind a
proxy or CDN that sets `x-request-id`, set `[telemetry] trust_request_id = true`
to keep its ID, so its logs and the server's share one ID. Only do this when
the proxy replaces any `x-request-id` a client sends. The server still
replaces an ID longer than 200 characters or with characters other than
letters, digits, and `-_.:+/=`.

## Tracing

The server exports ImagePipe's request and stage spans with OpenTelemetry,
configured by the standard `OTEL_*` variables. Export is off until an OTLP
endpoint or an exporter is set:

```bash
docker run -e OTEL_EXPORTER_OTLP_ENDPOINT=http://collector:4318 -e OTEL_SERVICE_NAME=images ghcr.io/hlindset/image_pipe_server:0.3
```

- `OTEL_EXPORTER_OTLP_ENDPOINT` or `OTEL_EXPORTER_OTLP_TRACES_ENDPOINT` turns
  on OTLP export (HTTP/protobuf by default).
- `OTEL_TRACES_EXPORTER=none` or `OTEL_SDK_DISABLED=true` turns it off.
- The service name defaults to `image_pipe_server`. The SDK reads the other
  variables itself, such as `OTEL_EXPORTER_OTLP_HEADERS`,
  `OTEL_EXPORTER_OTLP_PROTOCOL`, and `OTEL_TRACES_SAMPLER`.

Each request starts a new trace, and an incoming W3C `traceparent` header is
ignored. Any client can send `traceparent`. Set `trust_traceparent` in
[`[telemetry]`](server-configuration.md#telemetry) only when a proxy or CDN
you control sets or removes the header:

```toml
[telemetry]
trust_traceparent = true
```

With `trust_traceparent` on, a request that carries the header joins the
caller's trace. With the default parent-based sampler, such a request is
exported only when the caller's header marks the trace as sampled,
and `OTEL_TRACES_SAMPLER` applies only to requests without the header.

To try tracing locally, run Jaeger as in
[Exporting traces to Jaeger](../../image_pipe/docs/cookbook/opentelemetry-jaeger.md#run-jaeger)
and point `OTEL_EXPORTER_OTLP_ENDPOINT` at its port 4318.

[Request tracing](../../image_pipe/docs/tracing.md) explains how the spans
form a trace, and the
[telemetry event reference](../../image_pipe/docs/telemetry-events.md) lists
the metadata spans draw their attributes from.

## Remote console

The release's remote console, `bin/image_pipe_server remote`, needs Erlang
distribution (the network connection between Erlang nodes). It's off by
default, because anyone who can reach a node and knows its cookie can run
code on it.

Add `RELEASE_DISTRIBUTION: sname` and `RELEASE_COOKIE: <long random value>`
to the service's `environment` and restart it. The release reads the cookie
only from `RELEASE_COOKIE`, not from a `_FILE` variable. Then open the
console, here with the Compose service from [Running](#running):

```bash
docker compose exec images bin/image_pipe_server remote
```

With distribution on, the node and its port mapper (epmd, port 4369) listen on
127.0.0.1 only. `docker compose exec` runs the console inside the container,
so the console can connect, and other containers on the same network can't.

## Without Docker

Build a release from `image_pipe_server/` against the libraries published on
Hex:

```bash
export IMAGE_PIPE_LIBS=hex MIX_ENV=prod
mix deps.get --only prod
mix release
```

Without `IMAGE_PIPE_LIBS=hex`, the build uses the libraries in the same
checkout and compiles the SVG renderer from source, which needs a
[Rust toolchain](https://rustup.rs).

By default the release uses the libvips that vix ships, which can't read
JPEG XL. For JPEG XL sources, install libvips 8.18 with JPEG XL support and
build against it, as described in
[using your system's libvips](https://vix.hexdocs.pm/readme.html#advanced-setup).
For palette PNGs (`png-options=palette`), build that libvips with
libimagequant too. The libvips vix ships includes it.
