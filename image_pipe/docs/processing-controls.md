# Limiting concurrent processing

A processing pool limits how many images ImagePipe processes at once. Requests
beyond the limit wait in a queue or get a `503`, and each image gets a
deadline. Without a pool, every request starts processing right away, so a
burst of requests can use all the CPU and memory. `image_pipe_server` always
runs one.

This guide assumes ImagePipe is running in your app (see
[Getting started with Phoenix](phoenix-getting-started.md)) or as
`image_pipe_server` (see
[Getting started with the server](../../image_pipe_server/docs/server-getting-started.md)).

## Adding a pool

<!-- tabs-open -->

### Plug

Start an `ImagePipe.ProcessingPool` before the instance, and name it in the
instance's `processing_pool`:

```elixir
# lib/my_app/application.ex
children = [
  {ImagePipe.ProcessingPool, name: MyApp.Pool, max_concurrency: 8, max_queue: 16},
  {ImagePipe, name: MyApp.Images, processing_pool: MyApp.Pool, sources: [...]},
  MyAppWeb.Endpoint
]
```

Calls to `ImagePipe.run/4` with the instance's name use the same pool, so
jobs and requests share its capacity.

### image_pipe_server

The server always runs a pool. Change its limits in a `[pool]` section of
`config.toml`:

```toml
[pool]
max_concurrency = 8
max_queue = 16
```

<!-- tabs-close -->

## Choosing the limits

- `max_concurrency` is how many images are processed at once. Start with
  about the number of CPU cores, which is the server's default.
- `max_queue` is how many requests may wait for a turn, 64 by default. A
  request that finds the queue full gets a `503`. With `0`, every request
  beyond `max_concurrency` gets a `503` straight away.
- `queue_timeout`, 10 seconds by default, is how long a request waits for a
  turn before it gets a `503`.
- `processing_timeout`, 30 seconds by default, is the request deadline once
  processing starts.

`ImagePipe.ProcessingPool` lists the options, and the
[server reference](../../image_pipe_server/docs/server-configuration.md#pool)
their TOML keys.

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
reading the original, processing, and sending the last byte of the response.
A client that reads the response slowly uses up the deadline too.

When the deadline passes before the response starts, the request gets a
`503`. When the response has already started, ImagePipe cuts it short, as
described in [failures during streaming](streaming-failures.md). ImagePipe
also gives up on a response when producing its next chunk takes longer than
60 seconds, whatever the deadline.

After a timeout or client disconnect, the worker keeps its processing slot
until its current operation and resource cleanup finish. A libvips operation
already running may continue after the request ends. Waiting requests enter
only when a slot is released, and a cancelled request in the queue leaves
immediately. Keep the [size limits](deployment.md) as well.

## Monitoring the pool

The pool emits [`[:processing, :admission]`](telemetry-events.md#processing-admission)
for each wait for a turn and
[`[:processing, :execute]`](telemetry-events.md#processing-execute) for each
processed image. In Elixir, `ImagePipe.ProcessingPool.stats/1` returns how many
workers still hold slots, including workers finishing after a timeout, and
how many requests are waiting. The processing execution span ends when the
worker finishes. `ImagePipe.ProcessingPool` lists the errors
`ImagePipe.run/4` returns for each
case that gives a `503` over HTTP.
