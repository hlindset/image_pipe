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
  sources: [
    images: [
      adapter: ImagePipe.Source.File,
      match: :path,
      options: [root: "/srv/images", root_id: "images"]
    ]
  ]
)

# In a Plug pipeline:
plug ImagePipe.Plug, config: config

# In an Elixir caller:
plan = ImagePipe.URL.new() |> ImagePipe.URL.group(resize: [width: 400])
ImagePipe.run(config, plan, {:file, "/srv/images/photo.jpg"})
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

Queue order is FIFO; expired waiters cannot start. Waiting requests hold no
source image or encoder state, but still use processes and request data.
Configure HTTP server connection limits separately.

## Work covered

Every generated output holds a permit: images, BlurHash, CSS LQIP, and `info`.
Uncached file and binary inputs follow the same admission path.

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

Image delivery also waits at most 60 seconds for each encoded chunk. This
fixed backstop is not configurable; use `processing_timeout` to bound
generation. Before headers it returns `503` like a processing deadline, and it
can expire before a `processing_timeout` or queue wait longer than 60 seconds.
Source connection/read limits remain independent. A processing deadline
does not implement a total source-transfer deadline for work outside generation.

## Output-cache request coalescing

Concurrent requests for the same uncached output are processed once, as
described in [request coalescing](caching-and-freshness.md#request-coalescing).
This covers images, `info`, BlurHash, and CSS LQIP, from the Plug, Elixir calls,
and background refreshes. Waiting requests hold no processing slot or queue
entry. Coalescing allows 64 distinct outputs and 1,024 waiting requests per
node, and a request waits at most 60 seconds. Past those bounds, a request goes
through ordinary processing admission, which can still reject it when the pool
is overloaded.

## Failure and cancellation

| Elixir error | HTTP status before headers |
| --- | --- |
| `{:processing, :overloaded}` | `503` |
| `{:processing, :queue_timeout}` | `503` |
| `{:processing, :unavailable}` | `503` |
| `{:processing, :timeout}` | `503` |

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

`[:processing, :admission]` measures queue wait; `[:processing, :execute]`
measures the admitted lifetime. Both report outcomes and active/queued counts,
including worker termination. The default Logger warns on failures, and tracing
preserves request parentage. See [telemetry](telemetry-events.md#processing-admission-and-execution)
for event fields.
