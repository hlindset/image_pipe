# Request tracing

ImagePipe can turn its [telemetry events](telemetry-events.md) into
OpenTelemetry spans that show each request in a trace. A trace shows which stages a
request went through, how they nest, and how long each took, even when the
work moves between processes. Tracing is off until you attach the tracer.

## Attaching the tracer

The tracer creates spans through the OpenTelemetry API, and your application
runs the OpenTelemetry SDK that exports them. Add the SDK to your
dependencies, then attach the tracer once at startup:

```elixir
# lib/my_app/application.ex
ImagePipe.Telemetry.attach_tracer()
```

- `ImagePipe.Telemetry.attach_tracer/1`: the tracer's options.
- [Exporting traces to Jaeger](cookbook/opentelemetry-jaeger.md): setting up
  the SDK with a backend.

To see spans without a backend, configure the SDK's stdout exporter, which
prints spans to the console:

```elixir
# config/dev.exs
config :opentelemetry, traces_exporter: {:otel_exporter_stdout, []}
```

`image_pipe_server` attaches the tracer itself when its
[tracing settings](../../image_pipe_server/docs/server-deployment.md#tracing)
are set.

## Spans and their hierarchy

Each span event becomes a span named after its event, so
`[:source, :fetch_decode]` becomes `image_pipe.source.fetch_decode`. A
`image_pipe.request` is the outermost ImagePipe span of a request. Background cache work,
such as refreshing a stale original, a bounded cache's admission decisions
and re-scans, or deleting files a crash left behind, forms its own traces. A
one-shot event, such as `[:output, :clamp]`, becomes an event on the span that
is current when it fires.

Evictions aren't traced.
[`[:cache, :eviction, :stop]`](telemetry-events.md#cache-eviction-stop)
reports their counts and bytes to telemetry handlers.

A span's parent is the span that was current when it started. ImagePipe
carries the request's context into the other processes that serve it: the
processing pool, the encoder, the detection models, watermark fetches, and
the cache writer. Their spans stay in the request's trace. For example,
`image_pipe.encode` runs in the encoder process but is a child of
`image_pipe.request`, or of `image_pipe.processing.execute` under a
processing pool. `image_pipe.deliver` is a child of `image_pipe.send`.

After a timeout or cancellation, `image_pipe.processing.execute` remains open
until the worker finishes its operation and cleanup.

HTTP and S3 source requests add a client span, `image_pipe.http.client`. It
ends when the origin's status and headers arrive, because the body is
streamed afterwards. Finch spans for the whole request, the connection pool,
connecting, sending, and receiving (`finch.request`, `finch.connect`,
`finch.recv`, and so on) nest in it,
unless the tracer is attached with `finch_spans: false`.
The request carries a `traceparent` header naming the client span, so an
origin that traces its own requests joins the trace. It carries no other
trace context, such as `tracestate` or `baggage`, whatever propagators the
SDK is configured with. Without the tracer, source requests send no
`traceparent`.

`image_pipe.http.client` has an `http.status_code` attribute, or `error.type`
when the request fails. A Finch span has `http.status_code` when a response
arrived.

A span's attributes are its event's start and stop metadata, limited to keys
known to be safe to export. Request paths, source URLs, signatures, and
credentials are never copied. Atoms become strings, a list of atoms,
strings, or numbers becomes a list of strings, and any other value that isn't
a string, number, or boolean becomes its `inspect/1` text.
`image_pipe.request` also carries a `request_id` attribute when Logger
metadata has a `:request_id`, such as the one `Plug.RequestId` sets, so you
can find a request's trace from its log lines.

A span's status is unset when its event has no `:result`, or one of these
results: `:ok`, `:admitted`, `:options`, `:not_modified`, `:detected`,
`:no_regions`, `:rejected`, `:client_closed`, and `:cancelled`. Any other
`:result`, or an exception, sets the status to error. The
[telemetry event reference](telemetry-events.md) lists which events emit
each result. A span that raised also gets an exception event, and its status
message is the `inspect/1` text of the raised reason, which can contain an
exception message.

## Where a trace starts

`image_pipe.request` starts under the span that is current in the process
handling the request. When your application traces its own requests, for
example with Phoenix or Bandit instrumentation, ImagePipe's spans join that
trace as children of your span. `ImagePipe.run/4` in an instrumented
background job joins the job's trace the same way. With no current span,
`image_pipe.request` starts a new trace.

## Inbound trace context

When the tracer is attached with `extract_inbound: true` and no span is
current, a Plug request with a valid W3C
[`traceparent`](https://www.w3.org/TR/trace-context/#traceparent-header)
header continues the caller's trace. Its request span gets the caller's trace
ID and is a child of the caller's span. A request with a missing or invalid
header starts a new trace. When a span is already current, that span is the
parent, and the header is ignored. `ImagePipe.run/4` never reads a header.

Extraction is off by default because any client can send a `traceparent`.
A client that does can attach its requests to a trace ID of its choosing,
for example one that belongs to another service's traces, and mark them as
sampled. Turn extraction on when a proxy you control sets the header or
removes it from outside requests. If your own HTTP instrumentation extracts
`traceparent`, ImagePipe's spans join that trace, and this option has no
effect.

`image_pipe_server` extracts inbound context only when `trust_traceparent`
is set in its
[`[telemetry]` configuration](../../image_pipe_server/docs/server-configuration.md#telemetry).
It is off by default.

## Sampling

The SDK's sampler decides which traces are recorded. With its default
parent-based sampler, a request under your own span or an inbound trace
follows that parent's sampled flag, and the root sampler (`always_on` unless
you configure another) applies to new traces. ImagePipe doesn't sample on
its own.
