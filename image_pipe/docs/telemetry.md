# Monitoring with telemetry

Log each stage of ImagePipe's requests, and send them to your own metrics
or logging handlers. This guide assumes ImagePipe runs in your app, as a
Plug or through `ImagePipe.run/4`. When you run `image_pipe_server`, set
`log_level` in its [telemetry settings](../../image_pipe_server/docs/server-configuration.md#telemetry)
instead.

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

Each request stage then logs one line, such as:

```text
image_pipe source fetch: ok (mount images)
image_pipe output negotiate: ok (webp)
image_pipe request: ok
```

Failures and degraded results log at `:warning`. To log only some stages,
pass `:events`, for example `events: [:request, :source, :cache]`. If you set
a custom `telemetry_prefix`, pass the same list as `:prefix`.
`ImagePipe.Telemetry.attach_default_logger/1` lists the groups and options.

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

Event metadata leaves out anything that grants access or identifies a
private image: signatures, credentials, source URLs, and request paths, which
often carry signatures or presigned credentials. It does include values that
are safe but can have many distinct values, such as preset names, operation
parameters, and image sizes. Choose which ones become metrics tags.

If your handler adds the request path or source URL itself, for example from
`conn`, strip signatures and credentials before logging it or sending it to
a third party.

## Next steps

- [Request tracing](tracing.md): turn events into traces and export them.
- [Exporting traces to Jaeger](cookbook/opentelemetry-jaeger.md): send traces
  to a local Jaeger through OpenTelemetry.
- [Debug response headers](debug_headers.md): see how one response was
  produced, from its headers.
