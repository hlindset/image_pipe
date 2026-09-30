# Cookbook: OpenTelemetry traces to Jaeger (local)

ImagePipe emits `:telemetry` spans and provides an opt-in exporter that replays
them through the host's OpenTelemetry SDK while preserving ImagePipe's
`trace_id`. This recipe sends those traces to a local Jaeger.

> The `fiddle/` demo contains a runnable example gated by `FIDDLE_OTEL=1`. See
> `fiddle/docker-compose.yml`, `fiddle/config/config.exs`, and the
> `attach_tracer/1` call in `fiddle/lib/image_pipe_fiddle/application.ex`.

## 1. Run Jaeger

```yaml
# docker-compose.yml
services:
  jaeger:
    image: cr.jaegertracing.io/jaegertracing/jaeger:2.19.0
    ports: ["16686:16686", "4317:4317", "4318:4318"]
```

`docker compose up -d`, then open http://localhost:16686. Jaeger v2 accepts OTLP
natively on 4317 (gRPC) and 4318 (HTTP).

## 2. Add the OTel SDK (host side)

```elixir
# mix.exs
# list :opentelemetry_exporter BEFORE :opentelemetry so the exporter app
# starts first (otherwise the SDK's processor can't reach it at boot)
{:opentelemetry_exporter, "~> 1.8"},
{:opentelemetry, "~> 1.7"},
```

ImagePipe declares only the optional `:opentelemetry_api` dependency. The host
provides the SDK; `:opentelemetry` brings the API transitively.

## 3. Point the SDK at Jaeger

```elixir
# config/config.exs
config :opentelemetry,
  span_processor: :batch,
  traces_exporter: :otlp,
  # the Jaeger "service" name (otherwise a default like "Erlang/OTP"); ImagePipe
  # itself only sets the `image_pipe` instrumentation scope, not the resource
  resource: [service: %{name: "my_app"}]

config :opentelemetry_exporter,
  otlp_protocol: :http_protobuf,
  otlp_endpoint: "http://localhost:4318"
```

```elixir
# config/test.exs — never export during tests
config :opentelemetry, traces_exporter: :none
```

For releases, this configuration can live in `config/runtime.exs` and read the
endpoint from an environment variable. Keep the test override.

## 4. Activate at startup

```elixir
ImagePipe.Telemetry.attach_tracer(
  exporter: ImagePipe.Telemetry.Trace.OpenTelemetryExporter,
  extract_inbound: true
)
```

If `:opentelemetry_api` is absent, this raises at startup. After a request and a
batch flush, Jaeger shows an `image_pipe.request` trace with descendants such as
`image_pipe.send`, its nested `image_pipe.deliver`, `image_pipe.encode`,
`image_pipe.transform.execute`, and `image_pipe.transform.operation`.

When ImagePipe starts the trace, Jaeger may show a missing parent on the root.
The synthetic remote parent forces ImagePipe's `trace_id` onto the OTel trace.
Behind a traced caller, `extract_inbound: true` instead makes the root a real
child of the inbound span.

## Troubleshooting: no traces appear

The exporter detects the OTel API at **compile time**. If the SDK was added after
ImagePipe was compiled, the exporter remains unavailable and
`ImagePipe.Telemetry.Trace.OpenTelemetryExporter.available?/0` returns `false`.
Force a recompile:

```sh
mix deps.compile image_pipe --force   # or: mix clean && mix compile
```

A fresh build sees `:opentelemetry_api` during compilation and needs no forced
recompile.
