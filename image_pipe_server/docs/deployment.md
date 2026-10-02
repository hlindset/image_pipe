# Deploying image_pipe_server

The server is a Mix release, packaged as a Docker image. This guide covers
building and running the image, then the settings that matter in production.
See [configuration](configuration.md) for the configuration language.

## Images

There are two variants, built from the same Dockerfile:

- `image_pipe_server`, without content-aware detection.
- `image_pipe_server` built with `IMAGE_VISION=1`, which adds `image_vision`
  with ONNX Runtime and bakes the face and object detection models into the
  image, so detection works without network access at runtime.

Both build libvips from source, so they read JPEG XL sources and write
palette PNGs. Build from the repository root, since the server depends on
its sibling projects:

```bash
docker build -f image_pipe_server/Dockerfile -t image_pipe_server .
```

```bash
docker build -f image_pipe_server/Dockerfile --build-arg IMAGE_VISION=1 -t image_pipe_server:vision .
```

The image runs as user `image_pipe` (uid 10001), listens on port 8080, and
checks `GET /health` for its Docker health status.

## Running

Mount a configuration file at `/etc/image_pipe/config.toml` (or name another
path with `IPS_CONFIG`), and give caches a volume:

```bash
docker run --read-only --tmpfs /tmp -p 8080:8080 -v ./config.toml:/etc/image_pipe/config.toml:ro -v ./images:/data/images:ro -v image-cache:/var/cache/image_pipe image_pipe_server
```

- The server writes only to `/tmp` and to cache directories, so the root
  filesystem can be read-only. Mount `/tmp` as a `tmpfs`.
- Put caches under `/var/cache/image_pipe`, which is writable by the server's
  user.
- Pass secrets as `_FILE` variables pointing at mounted secret files, for
  example `IPS_URL__KEYS_FILE=/run/secrets/signing_keys`.

With Docker Compose:

```yaml
services:
  images:
    image: image_pipe_server
    read_only: true
    tmpfs: [/tmp]
    ports: ["8080:8080"]
    stop_grace_period: 20s
    environment:
      IPS_URL__KEYS_FILE: /run/secrets/signing_keys
    secrets: [signing_keys]
    volumes:
      - ./config.toml:/etc/image_pipe/config.toml:ro
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
      image: image_pipe_server
      ports: [{ containerPort: 8080 }]
      env:
        - name: IPS_URL__KEYS_FILE
          value: /run/secrets/image-pipe/signing_keys
        - name: IPS_CACHE__OUTPUT__NODE_ID
          valueFrom: { fieldRef: { fieldPath: metadata.name } }
      readinessProbe: { httpGet: { path: /health, port: 8080 } }
      livenessProbe: { httpGet: { path: /health, port: 8080 } }
      securityContext:
        readOnlyRootFilesystem: true
      volumeMounts:
        - { name: config, mountPath: /etc/image_pipe, readOnly: true }
        - { name: secrets, mountPath: /run/secrets/image-pipe, readOnly: true }
        - { name: cache, mountPath: /var/cache/image_pipe }
        - { name: tmp, mountPath: /tmp }
  volumes:
    - { name: config, configMap: { name: image-pipe-config } }
    - { name: secrets, secret: { secretName: image-pipe } }
    - { name: cache, emptyDir: {} }
    - { name: tmp, emptyDir: { medium: Memory } }
```

Use a StatefulSet when a bounded cache persists across restarts: its
`node_id` must stay stable for the same node, and StatefulSet pod names do.

## Caches

`[cache.output]` stores encoded responses, `[cache.input]` stores source
bytes. Both grow without limit unless `max_size_bytes` is set, which also
requires a stable `node_id`. See the library's [cache guide](../../image_pipe/docs/cache.md).

Whether a response is cached also depends on its source mount:

- HTTP and S3 mounts follow the origin's cache headers by default. Set
  `cache_policy` to override them.
- File mounts use the output cache only with `internal_cache = "enabled"`.

## Processing capacity

Without `[pool]`, every request processes at once. Set `max_concurrency` to
about the number of CPU cores, and `max_queue` for how many requests may wait
for a slot. A request that finds the queue full, or waits longer than
`queue_timeout`, gets a `503`. See
[processing controls](../../image_pipe/docs/processing-controls.md).

## Detection

Detection-based gravity needs the vision image. Without it, detection
requests fall back to attention cropping. Set
`[processing] detector_required = true` to fail them instead, including when
detection errors while processing. The plain image then refuses to start,
which catches deploying the wrong variant. See
[content-aware gravity](../../image_pipe/docs/content-aware-gravity.md).

## Logging

`[telemetry] log_level` attaches the library's default Logger, which logs
each request stage at that level. See [telemetry](../../image_pipe/docs/telemetry.md).

Every response carries an `x-request-id` header, and every log line for that
request is tagged `request_id=<id>`. The server keeps a valid incoming
`x-request-id` (20 to 200 characters), so an ID set by a proxy or CDN carries
through; otherwise it generates one.

## Tracing

The server exports ImagePipe's request and stage spans with OpenTelemetry,
configured by the standard `OTEL_*` variables. Export is off until an OTLP
endpoint or an exporter is set:

```bash
docker run -e OTEL_EXPORTER_OTLP_ENDPOINT=http://collector:4318 -e OTEL_SERVICE_NAME=images image_pipe_server
```

- `OTEL_EXPORTER_OTLP_ENDPOINT` or `OTEL_EXPORTER_OTLP_TRACES_ENDPOINT` turns
  on OTLP export (HTTP/protobuf by default).
- `OTEL_TRACES_EXPORTER=none` or `OTEL_SDK_DISABLED=true` turns it off.
- The service name defaults to `image_pipe_server`. The SDK reads the other
  variables itself, such as `OTEL_EXPORTER_OTLP_HEADERS`,
  `OTEL_EXPORTER_OTLP_PROTOCOL`, and `OTEL_TRACES_SAMPLER`.
- An incoming W3C `traceparent` header continues the caller's trace.

See the library's [telemetry guide](../../image_pipe/docs/telemetry.md) for
the spans and their attributes.

## Without Docker

Build a release from `image_pipe_server/`:

```bash
MIX_ENV=prod mix release
```

By default vix uses its precompiled libvips, which can't read JPEG XL. For
JPEG XL sources, install libvips 8.18 with JPEG XL support and build with
`VIX_COMPILATION_MODE=PLATFORM_PROVIDED_LIBVIPS`.
