# Monitoring with telemetry

Log ImagePipe's requests, and send them to your own metrics or logging
handlers. This guide assumes ImagePipe runs in your app, as a Plug or through
`ImagePipe.run/4`. `image_pipe_server` logs its requests by default (see its
[telemetry settings](../../image_pipe_server/docs/server-configuration.md#telemetry)).

ImagePipe emits [`:telemetry`](https://hexdocs.pm/telemetry) events and
attaches no handlers itself. The [event reference](telemetry-events.md) lists
every event.

## Logging with the default logger

Attach the bundled Logger handler once, when your application starts:

```elixir
# lib/my_app/application.ex
def start(_type, _args) do
  ImagePipe.Telemetry.attach_default_logger()
  # ...
end
```

Each request then logs one line: the method, path, status, duration, and
bytes sent, then what the request did as `key=value` fields:

```text
[info] GET /w=200/src/REDACTED 200 79ms 4.7kB source_url=beach.jpg cache=miss source=images source_fetch=ok fetch_ms=1 input=jpeg input_size=4000x2667 decode_ms=4 ops=resize output=jpeg output_size=200x133 encode_ms=6 admission=admitted queue_ms=0
[warning] GET /w=200/src/REDACTED 404 1ms source_url=missing.jpg error=source reason="source not found" source=images source_fetch=source_error fetch_ms=0
```

A `5xx`, or a response that failed partway through sending, logs at
`:error`. A `4xx` logs at `:warning`, and so does a result that didn't come
out as requested, such as a crop that used attention because detection
failed or no detector is configured, or an image scaled down to the limits.
A request whose cache read failed logs at `:warning` too. A
[low-priority request](processing/request.md#priority) that the processing
pool turned away logs at the base level, since its client retries. A cache write that
fails or is dropped logs its own `:warning` line, because the write can
finish after the request's line. The
[`[:request, :summary]`](telemetry-events.md#request-summary) event lists the
fields. The fields are also in the line's Logger metadata, as a map under
`:image_pipe`, so a JSON formatter such as
[`logger_json`](https://hexdocs.pm/logger_json) writes them as an
`image_pipe` object. One key keeps them clear of the fields a log collector
reserves, such as Datadog's `status`.

The path ends at the source, as in `/w=200/src/REDACTED`, and the source
follows as a `source_url=` field, without
[its credentials](#what-events-contain).

To debug a request, pass `stages: true` to also log one line for each of its
stages, such as each cache lookup, the decode, and the encode. If you set a
custom `telemetry_prefix`, pass the same list as `:prefix`.
`ImagePipe.Telemetry.attach_default_logger/1` lists the options.

## Attaching handlers

Attach your own handler to the events you need. This one logs each request's
result and duration:

```elixir
# lib/my_app/image_pipe_telemetry.ex
defmodule MyApp.ImagePipeTelemetry do
  require Logger

  def attach do
    :telemetry.attach(
      "my-app-image-pipe",
      [:image_pipe, :request, :stop],
      &__MODULE__.handle_event/4,
      nil
    )
  end

  def handle_event(_event, measurements, metadata, _config) do
    duration_ms = System.convert_time_unit(measurements.duration, :native, :millisecond)
    Logger.info("image_pipe result=#{metadata.result} duration_ms=#{duration_ms}")
  end
end
```

Call `MyApp.ImagePipeTelemetry.attach()` at startup. To subscribe to several
events, use `:telemetry.attach_many/4`. Event names start with
`telemetry_prefix`, `[:image_pipe]` by default (see
`ImagePipe.config/1`). If you set
another prefix, use it in the event names here.

For metrics, give the same event names to `Telemetry.Metrics` and choose
which metadata keys become tags.

## Request IDs

ImagePipe uses your app's request ID. Run `Plug.RequestId` before the
ImagePipe mount (Phoenix endpoints do by default). It sets the
`x-request-id` response header and `Logger.metadata[:request_id]`.

Every process that serves the request, including the processing pool and the
cache writer, keeps the caller's Logger metadata. Log lines and handlers
therefore see the same `:request_id` as the connection process:

```elixir
def handle_event(_event, _measurements, _metadata, _config) do
  request_id = Logger.metadata()[:request_id]
  # ...
end
```

Event metadata has no request ID field of its own. Background cache
refreshes run outside any request, so they have no request ID. Traces
correlate by trace ID instead (see [request tracing](tracing.md)).

## What events contain

Event metadata leaves out origin credentials and the signing and encryption
keys. The path on [`[:request]`](telemetry-events.md#request) and the summary
ends at the source, as in `/w=200/src/REDACTED`, and each `wm-src64=` value
is `REDACTED`. It keeps the URL signature, which authorizes only that URL.

Once a request parses, `:source_url` and `:watermark_source_urls` show its
sources as ImagePipe parsed them: decoded from `src64`, or decrypted from
`enc`, so an encrypted source is visible to anyone who reads your telemetry.
Each query value, such as a presigned URL's `X-Amz-Signature`, is replaced
with `REDACTED`. So is each query part without a value, such as `&token`,
and a user name and password. A request that fails before it parses, such
as one with a bad signature, has only the path.

Metadata does include values
that can have many distinct values, such as paths, preset names, operation
parameters, and image sizes. Choose which ones become metrics tags.

If your handler adds a source URL itself, for example from `conn`, strip any
credentials it carries before logging it or sending it to a third party.

## Next steps

- [Request tracing](tracing.md): turn events into traces and export them.
- [Exporting traces to Jaeger](cookbook/opentelemetry-jaeger.md): send traces
  to a local Jaeger through OpenTelemetry.
- [Debug response headers](debug_headers.md): see how one response was
  produced, from its headers.
