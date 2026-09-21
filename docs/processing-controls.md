# Processing concurrency and deadlines

ImagePipe can share one processing budget across Plug mounts, direct Elixir
calls, and background cache refreshes. Configure an opt-in pool under the host's
supervision tree, before the endpoint or workers that use it:

```elixir
children = [
  {ImagePipe.ProcessingPool,
   name: MyApp.Images,
   max_concurrency: 4,
   max_queue: 8,
   queue_timeout: 1_000,
   processing_timeout: 30_000},
  MyAppWeb.Endpoint
]
```

Select that pool in shared configuration:

```elixir
config = ImagePipe.config(
  processing_pool: MyApp.Images,
  sources: [path: {ImagePipe.Source.File, root: "/srv/images", root_id: "images"}]
)

# In a Plug pipeline:
plug ImagePipe.Plug, config: config

# In an Elixir caller:
plan = config |> ImagePipe.new() |> ImagePipe.group(resize: [width: 400])
ImagePipe.run(plan, {:file, "/srv/images/photo.jpg"})
```

The pool is node-local. Use the same registered name or PID to share capacity;
separate pools have independent budgets. Omitting `processing_pool` leaves
generation unrestricted by these controls. A configured pool that is unavailable
fails closed. `ImagePipe.ProcessingPool.stats/1` returns `%{active: n, queued: n}`.

| Pool option | Default | Meaning |
| --- | --- | --- |
| `max_concurrency` | Required | Positive maximum number of admitted jobs |
| `max_queue` | `0` | Nonnegative number of waiting jobs; zero rejects overflow |
| `queue_timeout` | `1_000` | Positive maximum admission wait in milliseconds |
| `processing_timeout` | `30_000` | Positive execution deadline in milliseconds |

Both timeouts are finite. Queue order is FIFO. Queue time starts when a worker
requests admission; an expired waiter cannot start merely because a slot becomes
available before its timer message is handled. Admission reserves no source image
or encoder state. Waiting requests still have lightweight processes and request
data; this pool does not replace HTTP server connection or request limits.

## Work covered

Every generated output holds a permit: images, blurhash, CSS LQIP, and `info`.
Although `info` does not run transforms or encode image pixels, opening an image
and reading its headers can consume a remote source, so its misses share the
same budget. Uncached file and binary inputs follow the same admission path.

Output-cache hits and conditional `304` responses skip processing admission.
Source identity resolution and source-cache acquisition/revalidation that precede
the output-cache lookup remain outside the processing pool. Source consumption
performed by generation is inside it. Pool names, queue sizes, and deadlines do
not change cache keys or ETags.

The processing deadline starts when the slot is granted. It spans fetch/decode,
transforms, encoding, and cleanup. An image producer keeps its slot through the
last encoded chunk and resource-bracket exit. The deadline also includes pauses
between demands, so slow downstream consumption can expire an image stream.
Complete-body terminals release after their generated result and source cleanup,
before cache storage and HTTP delivery.

The existing delivery prepare/next call timeout remains a separate limit. Its
60-second default can expire before a longer processing deadline or queue wait.
Source connection/read limits also remain independent. A processing deadline
does not implement a total source-transfer deadline for work outside generation.

## Output-cache request coalescing

With an output `cache` configured, concurrent misses for the same configured
cache and representation share one generation on each node. This applies to
images, `info`, blurhash, and CSS LQIP across Plug, Elixir calls, and background
refreshes. Followers wait before processing admission; they consume no processing
slots or processing-queue entries. Uncacheable inputs and configurations with
only an `input_cache` use ordinary processing admission.

The leader streams normally and retains ownership until its output-cache commit
finishes. Followers then recheck the cache. The cache stores the shared result;
coalescing adds no image buffer or stream broadcast. If the entry is missing,
evicted, rejected, or unavailable, each follower falls back to ordinary generation
once. Failed generation also releases followers to run under their own safety
limits. A cancelled leader promotes one waiter after the delivery session ends.

Coordination is best effort, bounded to 64 distinct output keys and 1,024 waiting
requests per node. Followers wait at most 60 seconds. Saturation, expiry, or a
coordinator restart falls back to ordinary processing admission, which can still
reject an overloaded request. These bounds protect coordinator resources; they
do not introduce an HTTP retry requirement or change the processing pool limits.
Equivalent requests on different nodes can still generate independently.

## Failure and cancellation

| Elixir error | HTTP status before headers |
| --- | --- |
| `{:processing, :overloaded}` | `503` |
| `{:processing, :queue_timeout}` | `503` |
| `{:processing, :unavailable}` | `503` |
| `{:processing, :timeout}` | `504` |

Errors do not become successful cache entries. After streaming headers have been
sent, a failure ends the stream and aborts staged output instead of changing its
HTTP status. A prepared stream that expires while idle returns the timeout on its
next pull.

The pool monitors workers and their owners. Worker failures and request-owner
death recover capacity; queued owners are removed without running their work.
Delivery cancellation and disconnects use the coordinator's graceful halt, with
its existing forced-stop fallback. A deadline terminates the worker, so arbitrary
host callback `after` blocks cannot be guaranteed to run on forced cancellation.
Admitted workers are linked to the pool so a pool crash stops its active work.

Native libvips operations may finish after a BEAM cancellation signal. This is a
limit on admitted job lifetimes, not a hard CPU-preemption or native-memory bound.
The slot remains occupied until the worker has returned from its brackets or its
monitor reports termination. Hosts still need input-size limits and an appropriate
libvips concurrency/memory configuration.

## Observability

`[:processing, :admission]` measures admission wait and reports `:admitted`,
`:overloaded`, `:queue_timeout`, `:cancelled`, `:worker_down`, or `:unavailable`.
`[:processing, :execute]` measures the admitted lifetime and reports `:ok`,
`:processing_error`, `:timeout`, `:cancelled`, `:worker_down`, or `:unavailable`.
Both use `:start`/`:stop` spans with safe `:active` and `:queued` counts sampled
when the span opens. The pool closes spans even when a worker is terminated.

The default Logger includes both in its `:request` group, preserving the outcome
and warning on rejection, timeout, unavailability, and processing failure. Trace
Capture and the opt-in OpenTelemetry exporter include both spans and queue counts.
Execution spans retain their request parent; generation spans are their children.
See [telemetry](telemetry.md) for handler setup.
