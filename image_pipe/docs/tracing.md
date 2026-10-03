# Request tracing

ImagePipe can turn its [telemetry events](telemetry-events.md) into trace
spans, with one trace per request. A trace shows which stages a request went
through, how they nest, and how long each took, even when the work moves
between processes. Tracing is off until you attach a tracer.

## Attaching a tracer

Attach the tracer once at startup, with an exporter that receives each
finished span. The bundled `ImagePipe.Telemetry.Trace.LogExporter` writes one
log line per span:

```elixir
# lib/my_app/application.ex
ImagePipe.Telemetry.attach_tracer(exporter: ImagePipe.Telemetry.Trace.LogExporter)
```

`ImagePipe.Telemetry.attach_tracer/1` lists the options. To send spans to an
OpenTelemetry backend, use `ImagePipe.Telemetry.Trace.OpenTelemetryExporter`,
as in [Exporting traces to Jaeger](cookbook/opentelemetry-jaeger.md). To send
them somewhere else, implement `ImagePipe.Telemetry.Trace.Exporter`.
`image_pipe_server` attaches the OpenTelemetry exporter itself when its
[tracing settings](../../image_pipe_server/docs/server-deployment.md#tracing)
are set.

## Spans and their hierarchy

Each span event becomes a span named after its event, so
`[:source, :fetch_decode]` becomes `image_pipe.source.fetch_decode`. A
request's trace has `image_pipe.request` as its root. Background cache work,
such as refreshing a stale original or a bounded cache's admission decisions,
forms its own traces. A one-shot event, such as
`[:output, :clamp]`, becomes an event on the span that is open when it fires.

A span's parent is the span that was open when it started. That works within
one process, and ImagePipe carries the request's trace into the other
processes that serve it: the processing pool, the encoder, watermark fetches,
and the cache writer. Their spans stay in the request's trace. For example,
`image_pipe.encode` runs in the encoder process but is a child of
`image_pipe.request`, or of `image_pipe.processing.execute` under a
processing pool. `image_pipe.deliver` is a child of `image_pipe.send`.

HTTP and S3 source requests add a client span, `image_pipe.http.client`. It
ends when the origin's status and headers arrive, because the body is
streamed afterwards. Finch spans for the connection pool, connecting,
sending, and receiving (`finch.connect`, `finch.recv`, and so on) nest in it,
unless the tracer is attached with `finch_spans: false`.
The request carries a `traceparent` header naming the client span, so an
origin that traces its own requests joins the trace. Without a tracer,
source requests send no `traceparent`.

A span's attributes are its event's start and stop metadata, limited to keys
known to be safe to export. Request paths, source URLs, signatures, and
credentials are never copied. A span's status comes from its `:result`.
`ImagePipe.Telemetry.Trace.Exporter` describes the span an exporter receives,
including how its status is set.

## Trace and span IDs

ImagePipe generates its own random trace and span IDs. A request with no
[inbound trace context](#inbound-trace-context) starts a new trace. Log lines
from `LogExporter` show these IDs.

`OpenTelemetryExporter` replays a trace into the OpenTelemetry SDK when the
request's root span finishes, so each span can be created under its real
parent. The SDK creates new span IDs, but the trace ID stays ImagePipe's, so
log lines and the OpenTelemetry trace share a trace ID. For a new trace,
that needs `ImagePipe.Telemetry.Trace.OtelIdGenerator` as the SDK's
`id_generator`. Without it, the exporter sets the trace ID through a made-up
remote parent, and backends report the root's parent as missing (Jaeger
calls it an invalid parent span ID).

Replay is best effort: buffered traces can be lost, delayed, or exported
with some spans missing their parent. `OpenTelemetryExporter` lists the
limits.

## Inbound trace context

When the tracer is attached with `extract_inbound: true`, a Plug request with
a valid W3C [`traceparent`](https://www.w3.org/TR/trace-context/#traceparent-header)
header continues the caller's trace. Its root span gets the caller's trace ID
and is a child of the caller's span. A request with a missing or invalid
header starts a new trace. `ImagePipe.run/4` never reads a header,
and always starts a new trace.

Extraction is off by default because any client can send a `traceparent`.
A client that does can attach its requests to a trace ID of its choosing,
for example one that belongs to another service's traces, and mark them as
sampled. Turn extraction on when a proxy you control sets the header or
removes it from outside requests.

`image_pipe_server` always extracts inbound context when tracing is on. If
clients reach it directly, have your proxy or CDN remove or replace
`traceparent` (see [server tracing](../../image_pipe_server/docs/server-deployment.md#tracing)).

## Sampling

ImagePipe doesn't sample. Every finished span goes to the exporter, carrying
the trace's sampled flag: the caller's flag for an inbound trace, and
sampled for a new one. An exporter or a downstream collector can drop
traces.

`OpenTelemetryExporter` starts an inbound trace's root as sampled, whatever
the caller's flag, so that every span of the trace reaches the SDK. With the
SDK's default parent-based sampler, inbound traces are therefore always
exported, and the sampler's setting applies only to new traces. To sample
traces from callers, sample in your OpenTelemetry collector.
