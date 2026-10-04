# Deploying image_pipe_server

`image_pipe_server` runs as a Docker image that you configure with a TOML
file and environment variables. The
[configuration reference](server-configuration.md) lists every setting.

## Images

There are two variants:

- `ghcr.io/hlindset/image_pipe_server:0.1.0`, without content-aware detection.
- `ghcr.io/hlindset/image_pipe_server:0.1.0-vision`, which adds face and object
  detection with the models baked into the image, so detection works without
  network access at runtime.

Both read every input format ImagePipe supports, including JPEG XL.

To build an image yourself, run from the repository root, since the server
depends on its sibling projects. Add `--build-arg IMAGE_VISION=1` for the
detection variant:

```bash
docker build -f image_pipe_server/Dockerfile -t image_pipe_server .
```

The image runs as user `image_pipe` (uid 10001), listens on port 8080, and
checks `GET /health` for its Docker health status.

Erlang distribution is off in the image and the release, so
`bin/image_pipe_server remote` can't connect. To use it, set
`RELEASE_DISTRIBUTION=sname` and a `RELEASE_COOKIE` secret of your own, and
keep epmd (port 4369) and the node's distribution port off untrusted
networks.

## Running

To try the server locally first, follow
[Getting started with the server](server-getting-started.md).

Mount the configuration file at `/etc/image_pipe/config.toml` (or name
another path with `IPS_CONFIG`), mount your images, and give caches a volume:

```bash
docker run --read-only --tmpfs /tmp -p 8080:8080 -v ./config.toml:/etc/image_pipe/config.toml:ro -v ./images:/data/images:ro -v image-cache:/var/cache/image_pipe ghcr.io/hlindset/image_pipe_server:0.1.0
```

- The server writes only to `/tmp` and to cache directories, so the root
  filesystem can be read-only. Mount `/tmp` as a `tmpfs`.
- Put caches under `/var/cache/image_pipe`, which is writable by the server's
  user.
- Make your images and their directories readable by uid 10001, for example
  with `chmod -R a+rX images`. A request for a file the server can't read
  gets `500` with the body `source unavailable`.
- Pass secrets as `_FILE` variables pointing at mounted secret files, for
  example `IPS_URL__KEYS_FILE=/run/secrets/signing_keys`.

With Docker Compose:

```yaml
services:
  images:
    image: ghcr.io/hlindset/image_pipe_server:0.1.0
    read_only: true
    tmpfs:
      - /tmp
    ports:
      - "8080:8080"
    stop_grace_period: 20s
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

The server speaks plain HTTP. Terminate TLS at a load balancer, ingress, or
CDN in front of it.

- `[server] read_timeout` (10 seconds) closes connections that send nothing
  for that long, including idle keep-alive connections. A connection that
  hasn't finished sending a request gets a `408` first.
- `[server] max_connections` (2048) caps concurrent connections. Beyond it,
  new connections wait up to five seconds for room, then are closed.
- `[server] auth_token` requires `Authorization: Bearer <token>` on every
  request except `/health`, answering `401` otherwise. Use it when a trusted
  edge adds the header, for example with unsigned URLs. Pass it as a secret:
  `IPS_SERVER__AUTH_TOKEN_FILE=/run/secrets/auth_token`.

## Health and shutdown

`GET /health` answers `200 ok` once the configuration was accepted and the
server is listening. Invalid configuration stops the server before it
listens, so use it for both readiness and liveness checks.

The image's Docker health check requests `/health` on `127.0.0.1`, at the
port in `IPS_SERVER__PORT` (8080 when it's unset). Set a custom port with
`IPS_SERVER__PORT` rather than `[server] port` in the file, and the check
follows it. If `[server] bind` is an address other than `0.0.0.0` or
`127.0.0.1`, override the check, for example in Compose:

```yaml
services:
  images:
    healthcheck:
      test: ["CMD", "curl", "-fsS", "http://10.0.0.5:8080/health"]
```

On `SIGTERM` the server stops accepting connections and gives in-flight
requests `[server] shutdown_timeout` milliseconds (default 15 seconds) to
finish. Give the platform a longer grace period, or it kills requests first:
Docker's default is 10 seconds (`docker stop -t 20`, or `stop_grace_period`
in Compose), and Kubernetes' is 30 seconds (`terminationGracePeriodSeconds`).

## Kubernetes

```yaml
spec:
  terminationGracePeriodSeconds: 30
  securityContext:
    runAsNonRoot: true
    runAsUser: 10001
  containers:
    - name: images
      image: ghcr.io/hlindset/image_pipe_server:0.1.0
      ports:
        - containerPort: 8080
      env:
        - name: IPS_URL__KEYS_FILE
          value: /run/secrets/image-pipe/signing_keys
      readinessProbe:
        httpGet:
          path: /health
          port: 8080
      livenessProbe:
        httpGet:
          path: /health
          port: 8080
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

A bounded cache needs a `node_id`. With the per-pod `emptyDir` above, a fixed
one in the configuration file works. For cache volumes that are shared or
outlive the pod, see
[Run several replicas](../../image_pipe/docs/caching-processed-images.md#run-several-replicas).

## Caches

To set up `[cache.output]` for processed images and `[cache.input]` for
originals, and to bound their size, see
[Caching processed images](../../image_pipe/docs/caching-processed-images.md).

Whether a response is cached also depends on its source mount:

- HTTP and S3 mounts follow the origin's cache headers by default. Set
  `cache_policy` to override them.
- File mounts check each file for changes. Set `stable = "immutable"` for
  [immutable](../../image_pipe/docs/caching-and-freshness.md#immutable-sources)
  files to skip the check. On a network filesystem such as EFS, `copy = "keep"` keeps
  local copies of originals in the `[cache] input` pool.
- A file mount's `root_id` is part of the cache key of every result from that
  mount. Keep it the same across restarts and replicas, or cached results
  aren't reused. The `root` path can differ between replicas or change over
  time.

## Processing capacity

The server processes as many images at once as it has CPU cores, counting a
container's CPU limit, and up to 64 more requests wait for a slot. A request
that finds the queue full, or waits longer than `queue_timeout` (one second),
gets a `503`, so a burst of traffic is turned away instead of running the
server out of memory. Change the limits with `max_concurrency`, `max_queue`
and `queue_timeout` in `[pool]`. See
[limiting concurrent processing](../../image_pipe/docs/processing-controls.md).

Each image also uses several threads in libvips, the image library. Under a
container CPU limit, the server sets `VIPS_CONCURRENCY` to that limit, so an
image uses at most that many threads. Set `VIPS_CONCURRENCY` yourself to
change it.

## Memory allocator

The image runs the server with the jemalloc memory allocator, which returns
memory that image processing frees. glibc's default allocator keeps much of
it. Set `IMAGE_PIPE_ALLOCATOR=glibc` to use glibc instead. The server also
uses glibc when jemalloc can't load on the host. With glibc, the server sets
`MALLOC_ARENA_MAX=2`, which limits how much freed memory glibc keeps, unless
you set it yourself.

## Detection

Face and object detection need the `0.1.0-vision` image. Enabling it,
requiring it, and checking that it runs are covered in
[Enabling face and object detection](../../image_pipe/docs/enabling-detection.md).

## Logging

`[telemetry] log_level` turns on request logging: one line per request
stage at that level, with failures and degraded results at `warning`. The
[telemetry event reference](../../image_pipe/docs/telemetry-events.md)
describes each stage.

Every response carries an `x-request-id` header, and every log line for that
request is tagged `request_id=<id>`. The server keeps a valid incoming
`x-request-id` (20 to 200 characters), so an ID set by a proxy or CDN carries
through; otherwise it generates one.

## Tracing

The server exports ImagePipe's request and stage spans with OpenTelemetry,
configured by the standard `OTEL_*` variables. Export is off until an OTLP
endpoint or an exporter is set:

```bash
docker run -e OTEL_EXPORTER_OTLP_ENDPOINT=http://collector:4318 -e OTEL_SERVICE_NAME=images ghcr.io/hlindset/image_pipe_server:0.1.0
```

- `OTEL_EXPORTER_OTLP_ENDPOINT` or `OTEL_EXPORTER_OTLP_TRACES_ENDPOINT` turns
  on OTLP export (HTTP/protobuf by default).
- `OTEL_TRACES_EXPORTER=none` or `OTEL_SDK_DISABLED=true` turns it off.
- An empty variable counts as unset, so `OTEL_EXPORTER_OTLP_ENDPOINT=` leaves
  export off.
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

With `trust_traceparent` on, a request that carries the header joins the caller's trace,
under the caller's trace ID. With the default parent-based sampler, such
requests are always exported, and `OTEL_TRACES_SAMPLER` applies only to
requests without the header.

To try tracing locally, run Jaeger as in
[Exporting traces to Jaeger](../../image_pipe/docs/cookbook/opentelemetry-jaeger.md#run-jaeger)
and point `OTEL_EXPORTER_OTLP_ENDPOINT` at its port 4318.

[Request tracing](../../image_pipe/docs/tracing.md) explains how the spans
form a trace, and the
[telemetry event reference](../../image_pipe/docs/telemetry-events.md) lists
the metadata spans draw their attributes from.

## Without Docker

Build a release from `image_pipe_server/`:

```bash
MIX_ENV=prod mix release
```

By default the release uses the libvips that vix ships, which can't read
JPEG XL. For JPEG XL sources, install libvips 8.18 with JPEG XL support and
build against it, as described in
[using your system's libvips](https://vix.hexdocs.pm/readme.html#advanced-setup).
For palette PNGs (`png-options=palette`), build that libvips with
libimagequant too. The libvips vix ships includes it.
