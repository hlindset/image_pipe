# Request-ID correlation and health checks

Beads `image_plug-yql`. Draft for agreement; nothing here is implemented.

## Summary

Use the host's request ID rather than inventing one. Hosts already run
`Plug.RequestId` (or an edge sets `x-request-id`), which puts the ID on the
response and into `Logger.metadata[:request_id]` for the connection process.
ImagePipe's job is to keep that Logger metadata intact across its own process
hops, so every log line and every telemetry handler invocation for a request
can see it. The standalone server adds `Plug.RequestId` and logs the ID.
Health checks need no library work: embedding hosts have their own, and the
server's `/health` already covers standalone use.

## Findings

**The ID already reaches the request process.** `:telemetry` runs handlers
synchronously in the emitting process, and `Logger` adds process metadata to
every line. In a Phoenix host, `[:request]`, `[:parse]`, cache lookup, and the
default Logger's lines for those already carry `request_id`.

**It is lost after the first hop.** Generation leaves the connection process
at five points, all of which already carry trace context as data
(`Trace.Stack.context/0` → `adopt/1`):

- `ProcessingPool.run/3` — the admitted worker task (source, decode,
  transform, encode, and their spans).
- `Execution.Overlap` — the source-overlap prepare task.
- `Execution.Watermarks` — watermark acquisition tasks.
- `Delivery.Producer` — the streaming producer.
- `Delivery.Coordinator` — the cache-commit session (`[:cache, :write]`).

Logger metadata is not copied, so log lines and handler-side
`Logger.metadata()` lookups from those processes have no `request_id`.
Background cache refresh (`Cache.Work`) is deliberately detached from the
request and keeps no request metadata.

**Request/failure fields are sufficient.** `[:request]` stop already has
`:result`, `:status`, and `:error` (a stable category). Representative
source/decode/cache/encode failures are classified the same way on their
stage spans. No new failure field is needed; correlation is the missing
piece, not taxonomy.

**The server has `/health` but no request ID.** `GET /health` answers `200 ok`
and the docs already say to use it for readiness and liveness. Responses carry
no `x-request-id`, and the console formatter prints no metadata.

## Design

### Logger metadata follows the request

Capture `Logger.metadata()` wherever trace context is captured and set it
wherever trace context is adopted. Rather than threading a second value
through five call sites, widen the carried context: a small
`ImagePipe.Telemetry.RequestContext` (`capture/0`, `adopt/1`) holding the
trace context and the Logger metadata. The five hops switch to it. Copying
the full metadata keyword (not just `:request_id`) keeps whatever else the
host attached, such as user or tenant IDs or OTel log correlation, without
ImagePipe knowing about them.

Telemetry metadata gets no `:request_id` key. Handlers read
`Logger.metadata()[:request_id]` — this works in every ImagePipe process after
the change, needs no Capture allowlist change, and leaves the ID's name and
header to the host. OTel users correlate by trace ID, which already
propagates.

### Standalone server

- Run `Plug.RequestId` first in `ImagePipeServer.Router.call/2`, so every
  response, including `/health` and `401`s, carries `x-request-id` and an
  incoming valid `x-request-id` is kept.
- Configure the console formatter with `metadata: [:request_id]`.
- Document both in `deployment.md`.

### Health checks

No library helper and no library docs. An embedding host already has its own
health check, and standalone deployments should use the server, whose `/health`
already serves as both readiness and liveness probe. Probing sources, caches,
or the processing pool would turn an origin outage or a load spike into
instances going unready, so the server's probe stays as is.

## Tests

- Wire test in `image_pipe`: a request through a pipeline with
  `Plug.RequestId` and a processing pool; a handler on a private prefix
  records `Logger.metadata()[:request_id]` per event. Assert the response
  `x-request-id` equals the ID on `[:request]` and on stage events emitted
  from the pool worker (`[:source, :fetch_decode]`, `[:encode]`) and from the
  delivery producer/cache write.
- Failure correlation: source-not-found, a decode failure, and an
  encode-path failure each report the same ID on `[:request]` stop as on the
  failing stage, with the expected `:result`/`:error`.
- Default Logger: a captured log line from a pool-side stage carries
  `request_id` metadata.
- Server: responses (image, `/health`, `401`) carry `x-request-id`; an
  incoming one is echoed.

## Out of scope

Request IDs in background cache refresh logs, a `:request_id` telemetry
field or OTel span attribute, a library health-check helper or recipe, and any
readiness probe that inspects pool or source state.
