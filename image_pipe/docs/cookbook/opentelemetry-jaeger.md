# Exporting traces to Jaeger

See ImagePipe's request traces in a local
[Jaeger](https://www.jaegertracing.io/), sent through the OpenTelemetry SDK.
This recipe assumes ImagePipe runs in your app. How the traces are built is explained in
[Request tracing](../tracing.md). For `image_pipe_server`, set the
[tracing variables](../../../image_pipe_server/docs/server-deployment.md#tracing)
instead, and run Jaeger as below.

## Run Jaeger

```yaml
# docker-compose.yml
services:
  jaeger:
    image: cr.jaegertracing.io/jaegertracing/jaeger:2.19.0
    ports: ["16686:16686", "4317:4317", "4318:4318"]
```

Run `docker compose up -d`, then open http://localhost:16686. Jaeger accepts
OTLP on ports 4317 (gRPC) and 4318 (HTTP).

## Add the OpenTelemetry SDK

```elixir
# mix.exs
# :opentelemetry_exporter before :opentelemetry, so the exporter starts
# before the SDK needs it
{:opentelemetry_exporter, "~> 1.8"},
{:opentelemetry, "~> 1.7"},
```

ImagePipe only depends on `:opentelemetry_api`, which `:opentelemetry`
brings in.

## Point the SDK at Jaeger

```elixir
# config/config.exs
config :opentelemetry,
  span_processor: :batch,
  traces_exporter: :otlp,
  # the service name Jaeger shows
  resource: [service: %{name: "my_app"}],
  # keeps ImagePipe's trace IDs on new traces
  id_generator: ImagePipe.Telemetry.Trace.OtelIdGenerator

config :opentelemetry_exporter,
  otlp_protocol: :http_protobuf,
  otlp_endpoint: "http://localhost:4318"
```

```elixir
# config/test.exs
config :opentelemetry, traces_exporter: :none
```

The `id_generator` setting makes a request's root span a true root in
Jaeger, with the same trace ID as ImagePipe's log lines (see
[trace and span IDs](../tracing.md#trace-and-span-ids)). For a release, move
this configuration to `config/runtime.exs` and read the endpoint from an
environment variable.

## Attach the tracer

```elixir
# lib/my_app/application.ex
ImagePipe.Telemetry.attach_tracer(exporter: ImagePipe.Telemetry.Trace.OpenTelemetryExporter)
```

If a proxy you control sets `traceparent`, add `extract_inbound: true` so
ImagePipe's traces join the caller's (see
[inbound trace context](../tracing.md#inbound-trace-context)).

Request an image. After the SDK's next batch export, Jaeger shows an
`image_pipe.request` trace with child spans such as `image_pipe.send`,
`image_pipe.deliver`, `image_pipe.encode`, `image_pipe.transform.execute`,
and `image_pipe.transform.operation`.

## Troubleshooting missing traces

If `attach_tracer/1` raises, or no traces appear, check
`ImagePipe.Telemetry.Trace.OpenTelemetryExporter.available?/0`. ImagePipe
detects the OpenTelemetry API when it compiles, so it returns `false` when
you added the SDK after ImagePipe was compiled. Recompile ImagePipe:

```sh
mix deps.compile image_pipe --force
```
