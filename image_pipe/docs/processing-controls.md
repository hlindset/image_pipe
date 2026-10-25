# Limiting concurrent processing

A processing pool limits how many images ImagePipe processes at once. Requests
beyond the limit wait in a queue or get a `503`, and each image gets a
deadline. An `ImagePipe` instance runs one unless you turn it off, and
`image_pipe_server` always does, so a burst of requests waits its turn
instead of using all the CPU and memory.

This guide assumes ImagePipe is running in your app (see
[Getting started with Phoenix](phoenix-getting-started.md)) or as
`image_pipe_server` (see
[Getting started with the server](../../image_pipe_server/docs/server-getting-started.md)).

## Changing the limits

<!-- tabs-open -->

### Plug

An instance starts its pool with the defaults below. Change them with the
instance's `pool` option:

```elixir
# lib/my_app/application.ex
children = [
  {ImagePipe, name: MyApp.Images, pool: [max_concurrency: 8, max_queue: 16], sources: [...]},
  MyAppWeb.Endpoint
]
```

Calls to `ImagePipe.run/4` with the instance's name use the same pool, so
jobs and requests share its capacity.

### image_pipe_server

Change the server's limits in a `[pool]` section of `config.toml`:

```toml
[pool]
max_concurrency = 8
max_queue = 16
```

<!-- tabs-close -->

## Choosing values

- `max_concurrency` is how many images are processed at once. It defaults
  to the number of CPU cores. Lower it when other heavy work runs on the
  same machine.
- `max_queue` is how many requests may wait for a turn, 1,024 by default. A
  request that finds the queue full gets a `503`. Under sustained overload, a
  waiting request gets its `503` only after `queue_timeout`, so lower
  `max_queue` if clients should fail sooner. With `0`, every request
  beyond `max_concurrency` gets a `503` straight away. The second turn of a
  request (see [deadlines](#deadlines)) doesn't count toward it.
- `queue_timeout`, 10 seconds by default, is how long a request waits for a
  turn before it gets a `503`.
- `processing_timeout`, 30 seconds by default, is the request deadline once
  processing starts.
- `low_priority_max_concurrency` is how many
  [low-priority requests](#low-priority-requests) are processed at once. It
  defaults to half of `max_concurrency`, rounded down, and at least 1.

A `503` for a full queue or a queue timeout has a `Retry-After` header:
`queue_timeout` in whole seconds, rounded up.

`ImagePipe.ProcessingPool` lists the options, and the
[server reference](../../image_pipe_server/docs/server-configuration.md#pool)
their TOML keys.

## Low-priority requests

A request with [`priority=low`](processing/request.md#priority), or an
`ImagePipe.run/4` call whose builder sets `priority: :low`, waits for spare
capacity:

- It starts only when no normal request is waiting.
- It starts processing only after the original has finished downloading.
- At most `low_priority_max_concurrency` low-priority requests are processed
  at once.
- A normal request that finds the queue full takes the place of the newest
  waiting low-priority request, which gets a `503`.
- A normal request never waits for a low-priority request that is making the
  same image. It makes the image itself (see
  [request coalescing](caching-and-freshness.md#request-coalescing)).

A low-priority request that has started keeps its slot until it finishes, so
a burst of normal requests can find up to `low_priority_max_concurrency`
slots taken. Lower it if that wait matters more than how fast low-priority
work gets done.

While normal requests keep arriving, low-priority requests wait their full
`queue_timeout` and get a `503`. If they keep failing, the pool is too
small for the load, or the low-priority work should run when traffic is
lower.

## Sharing a pool between instances

In an Elixir app, two instances that should share one limit can name the
same pool in `processing_pool`. Start it before them:

```elixir
# lib/my_app/application.ex
children = [
  {ImagePipe.ProcessingPool, name: MyApp.Pool, max_concurrency: 8},
  {ImagePipe, name: MyApp.Images, processing_pool: MyApp.Pool, sources: [...]},
  {ImagePipe, name: MyApp.Avatars, processing_pool: MyApp.Pool, sources: [...]},
  MyAppWeb.Endpoint
]
```

An instance that names a pool starts none of its own, so it can't also take
`pool` options.

## Turning the pool off

In an Elixir app, an instance with `pool: false` starts no pool, and every
request starts processing as it arrives. An `ImagePipe.Plug` mount without an
instance, and `ImagePipe.run/4` with a configuration from
`ImagePipe.config/1`, have no pool unless they name one in
`processing_pool`. Turn the pool off only for tests, scripts, and callers
that limit their own concurrency.

## What uses the pool

Every image ImagePipe processes takes a turn: resized images, `info`,
BlurHash, and LQIP placeholders, whether a request or a call to
`ImagePipe.run/4` asked for it. These don't:

- Images served from the cache.
- `304 Not Modified` responses.
- Requests waiting for an identical request that is already being processed
  (see [request coalescing](caching-and-freshness.md#request-coalescing)).

## Deadlines

The `processing_timeout` starts when a request gets its turn, and covers
reading the original, processing, and encoding the response. The turn ends
when the encode does, even if the client is still downloading. Up to 4 MB of
the response that the client hasn't read yet waits in memory, and the rest in
a temporary file in the directory that
[downloaded originals](cache.md#downloaded-originals) use. All requests on a
node together keep at most 256 MB in memory and 2 GB in temporary files this
way. A slow client keeps the turn, and its download counts toward the
deadline, while both of these hold:

- No room in a temporary file: the directory isn't private to ImagePipe's
  user, a write to the file failed, or the node's 2 GB are in use.
- No room in memory: 4 MB are waiting for this request, or the node's 256 MB
  are in use.

When the deadline passes before the response starts, the request gets a
`503`. When the response has already started, ImagePipe cuts it short, as
described in [failures during streaming](streaming-failures.md). It also cuts
the response short when producing its next chunk takes longer than 60 seconds,
whatever the deadline.

A large original fetched from an HTTP or S3 source can be decoded while it
downloads, so its encode takes a second turn. That turn keeps the first
turn's deadline, waits ahead of other requests, and isn't turned away when
the queue is full.

After a timeout or client disconnect, the worker keeps its processing slot
until its current operation and resource cleanup finish. A libvips operation
already running may continue after the request ends. Waiting requests enter
only when a slot is released, and a cancelled request in the queue leaves
immediately. Keep the [size limits](deployment.md) as well.

## Monitoring the pool

The pool emits [`[:processing, :admission]`](telemetry-events.md#processing-admission)
for each wait for a turn and
[`[:processing, :execute]`](telemetry-events.md#processing-execute) for each
processed image. Both carry the request's `:priority`. In Elixir,
`ImagePipe.ProcessingPool.stats/1` returns how many workers hold slots and
how many requests are waiting, each in total and for low priority. Workers
finishing after a timeout still count. An instance's own pool is named after
the instance, so `MyApp.Images` has `MyApp.Images.ProcessingPool`. The processing execution span ends when the
worker finishes. `ImagePipe.ProcessingPool` lists the errors
`ImagePipe.run/4` returns for each
case that gives a `503` over HTTP.
