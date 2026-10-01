# Tracing

ImagePipe also provides an opt-in tracer that converts [telemetry events](telemetry-events.md) into
`ImagePipe.Telemetry.Trace.Span` values. It preserves request-wide trace IDs and
parentage across transform nesting and delivery processes. Producer-side
`:encode` spans parent to the request root; `:deliver` nests under `:send`.

Attach the tracer at startup with `ImagePipe.Telemetry.attach_tracer/1` and
remove it with `ImagePipe.Telemetry.detach_tracer/0`. Invalid options raise
`ArgumentError`.

```elixir
# Attach the bundled stdlib-Logger exporter:
ImagePipe.Telemetry.attach_tracer(exporter: ImagePipe.Telemetry.Trace.LogExporter)

# ... later ...
ImagePipe.Telemetry.detach_tracer()
```

## Options

| Option            | Type            | Default                   | Meaning                                                                 |
| ----------------- | --------------- | ------------------------- | ----------------------------------------------------------------------- |
| `:exporter`       | module (atom)   | — (required)              | Module implementing the `ImagePipe.Telemetry.Trace.Exporter` behaviour. |
| `:prefix`         | list of atoms   | `[:image_pipe]`           | Telemetry event prefix to subscribe to. Reuses `ImagePipe.Telemetry.default_prefix()`; match your configured `telemetry_prefix`. |
| `:extract_inbound`| boolean         | `false`                   | Extract an inbound W3C `traceparent` header so the root span continues an upstream trace. Off by default — only enable behind a trusted edge. |
| `:finch_spans`    | boolean         | `true`                    | Also capture physical Finch wire spans for outbound source fetches.     |

Reattaching replaces the tracer configuration. Setting `finch_spans: false`
removes any previously attached Finch capture handler.

## The exporter contract

A host implements `ImagePipe.Telemetry.Trace.Exporter`:

```elixir
@callback export(ImagePipe.Telemetry.Trace.Span.t()) :: :ok
```

- `export/1` is called **synchronously** in the process that emitted the span's
  `:stop` / `:exception`. Keep it cheap and non-blocking — hand real I/O off to a
  batch processor. It must return `:ok` and should not raise.
- Span **attributes are pre-filtered for sensitivity** by the capture layer
  (allowlist only — source URLs, request paths, signatures, and tokens are never
  copied in). Exporters that fan out to third parties remain responsible for
  their own egress policy.
- Logical HTTP client spans record monotonic elapsed time through receipt of
  status and headers for streamed source fetches. One-shot trace annotations use
  their `:monotonic_time` measurement when present, or the synchronous capture
  time otherwise. OTel replay retains these durations and occurrence times.
- Attributes carry **both the start metadata and the allowlisted stop
  metadata** — the per-result verdict (e.g. the encode-search `chosen_quality` /
  `final_score` / `scorer`, the HTTP `status`, the classified `error` tag, the
  decoded shape). Stop keys win on collision. Exporters need not read the
  telemetry events separately to recover the outcome.
- The allowlist covers **attributes only**. A span's `status_message` and the
  `reason` on a folded `exception` event carry the raw exception reason
  (`inspect/1`, standard tracing behavior) and are **not** allowlist-filtered,
  so an exporter that renders them to third parties should be aware they may
  embed an exception message. (The bundled `LogExporter` renders neither.)

## `LogExporter`

`ImagePipe.Telemetry.Trace.LogExporter` logs one structured `Logger.info` line
as each span closes. Use the `parent=` field to reconstruct nesting:

```
image_pipe.trace trace=<trace_id> span=<span_id> parent=<parent_span_id|-> <name> dur=<duration_native|-> status=<ok|error|unset>
```

## Inbound extraction and sampling

Inbound `traceparent` extraction is **opt-in** (`extract_inbound: true`) because
trusting an inbound trace header from an untrusted client lets a caller pin your
`trace_id`; enable it only behind a gateway you control. When enabled and a valid
W3C `traceparent` is present, the request root span continues that trace and
parents to the inbound span; otherwise it mints a fresh root.
The parser accepts version `00` with exact field widths, lowercase hexadecimal
IDs and flags, and nonzero trace and parent IDs, following the
[W3C field syntax](https://www.w3.org/TR/trace-context/#traceparent-header-field-values).

**Sampling is deferred to the host.** ImagePipe propagates `trace_flags` but does
not implement a sampler. A host that wants head- or tail-based sampling does it in
its exporter (e.g. drop spans whose `trace_flags` indicate "not sampled", or
batch and sample in the downstream collector).

## OpenTelemetry export

`ImagePipe.Telemetry.Trace.OpenTelemetryExporter` replays captured spans into a
host-running OpenTelemetry SDK via the public OTel API. Optional dependency: ImagePipe
compiles against `:opentelemetry_api` only (declared `optional: true`); the **host**
adds `:opentelemetry` (+ an OTLP exporter) and starts the SDK.

```elixir
# host deps: {:opentelemetry, "~> 1.7"}, {:opentelemetry_exporter, "~> 1.8"}
# config/config.exs
config :opentelemetry, id_generator: ImagePipe.Telemetry.Trace.OtelIdGenerator

# at startup
ImagePipe.Telemetry.attach_tracer(
  exporter: ImagePipe.Telemetry.Trace.OpenTelemetryExporter,
  extract_inbound: true
)
```

**Hierarchy and correlation:** the exporter buffers each trace and replays it
top-down when the request root finishes, preserving the tree in Jaeger or Tempo.
The bounded, supervised buffer is best-effort: crashes or shutdown drop buffered
traces, and overload sheds new traces. Logs and OTel spans share `trace_id`, but
OTel mints different span IDs.

With inbound extraction, the request root is a real child of the caller. When
ImagePipe originates a trace, the root is exported as a true root span carrying
ImagePipe's trace ID, provided the SDK uses
`ImagePipe.Telemetry.Trace.OtelIdGenerator` (configured above; it mints random
IDs for everything else). Without it, a synthetic remote parent forces the trace
ID into OTel, and backends report the root's parent as missing (Jaeger: invalid
parent span ID; Tempo: root span not yet received). Only a span whose parent is
actually remote is marked so; replayed descendants have local parents.
Roots that never finish are flushed flat after about 10 seconds.
Cross-process spans finishing shortly after the root retain parentage when their
parent is already known; otherwise they may have a dangling parent.

If `:opentelemetry_api` is absent, `attach_tracer/1` raises. If the API is present
but the SDK is not running, the noop tracer drops spans. See the
[Jaeger cookbook](cookbook/opentelemetry-jaeger.md).

**Forced sampled flag:** the OTel exporter starts a root under a remote parent
(inbound or synthetic) with the W3C `-01` sampled flag set — trace-level
correlation requires every span to reach the SDK — so the inbound `trace_flags`
do not apply on this path. A true root goes through the SDK's root sampler
(`always_on` by default), and its descendants follow it. Do sampling in your
downstream OTel collector instead.
