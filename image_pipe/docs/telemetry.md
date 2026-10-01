# Telemetry

ImagePipe emits telemetry spans for the request lifecycle and major runtime
stages. Hosts can attach logging, metrics, or tracing handlers. ImagePipe has no
required tracing backend; its OpenTelemetry exporter is optional and opt-in.

Use this guide to configure logging and handlers. See the
[event reference](telemetry-events.md) for schemas and [tracing](tracing.md)
for trace exporters and OpenTelemetry.

## Configuration

Set the telemetry prefix as a Plug option:

```elixir
forward "/",
  to: ImagePipe.Plug,
  init_opts: [
    sources: [
      images: [
        adapter: ImagePipe.Source.File,
        match: :path,
        options: [root: "/srv/images", root_id: "primary"]
      ]
    ],
    telemetry_prefix: [:my_app, :image_pipe]
  ]
```

The default prefix is `[:image_pipe]`. Prefixes must be non-empty lists of
atoms.

## Default logging

Attach the stdlib Logger handler at application startup:

```elixir
ImagePipe.Telemetry.attach_default_logger()
```

It logs outcomes at `:info` and escalates errors and exceptions to `:warning`.
To select event groups or match a custom telemetry prefix:

```elixir
ImagePipe.Telemetry.attach_default_logger(
  events: [:request, :source, :cache],
  prefix: [:my_app, :image_pipe],
  level: :info
)
```

Groups are `:request`, `:parse`, `:source`, `:transform`, `:cache`, `:output`,
`:http_cache`, and `:debug`; the default is `:all`. `debug: true` also prints raw
measurements and metadata. Invalid startup options raise `ArgumentError`.
Detach with `ImagePipe.Telemetry.detach_default_logger/0`.

## Metadata and metrics

Events exclude secrets, credentials, private content, and source-derived paths
that may contain them. Handlers choose which fields become metrics tags.
See [common metadata](telemetry-events.md#metadata) and
[measurements](telemetry-events.md#measurements) for field names and time units.

## Request IDs

ImagePipe uses the host's request ID rather than minting its own. Run
`Plug.RequestId` (Phoenix endpoints do by default) before the mount: it sets
the `x-request-id` response header and `Logger.metadata[:request_id]`.
ImagePipe carries the caller's Logger metadata into every process that serves
the request, including the processing pool, the streaming producer, and the
cache writer, so log lines and telemetry handlers see the same metadata as
the connection process. Correlate a response with its events by reading the
ID in a handler:

```elixir
def handle_event(event, measurements, metadata, _config) do
  request_id = Logger.metadata()[:request_id]
  # ...
end
```

Telemetry metadata carries no request ID field. Background cache refreshes
run detached from any request and keep no request metadata. Traces correlate
by trace ID instead; see [tracing](tracing.md).

## Attaching handlers

Attach handlers to the events you need. This example logs request outcomes:

```elixir
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

    Logger.info(
      "image_pipe result=#{metadata.result} duration_ms=#{duration_ms}"
    )
  end
end
```

When customizing `telemetry_prefix`, use the same prefix here. To subscribe to
several events, pass their names to `:telemetry.attach_many/4`. The
[event reference](telemetry-events.md) lists spans and one-shot events;
one-shot events do not have span suffixes.
