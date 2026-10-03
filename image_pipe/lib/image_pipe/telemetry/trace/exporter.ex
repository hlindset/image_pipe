defmodule ImagePipe.Telemetry.Trace.Exporter do
  @moduledoc """
  Behaviour for receiving the spans the tracer captures, one call per
  finished span.

      defmodule MyApp.SpanExporter do
        @behaviour ImagePipe.Telemetry.Trace.Exporter

        @impl true
        def export(%ImagePipe.Telemetry.Trace.Span{} = span) do
          MyApp.SpanBuffer.add(span)
          :ok
        end
      end

  Attach it with `ImagePipe.Telemetry.attach_tracer/1`. How spans form a
  trace is explained in [Request tracing](tracing.md).

  ## Calling `export/1`

  `export/1` runs synchronously, in the process that finished the span,
  which is often serving a request. Keep it cheap: hand any I/O to a batching
  process. It must return `:ok` and should not raise.

  ## The span

  An `ImagePipe.Telemetry.Trace.Span` carries:

    * `:name`: `"image_pipe."` followed by the event's stage, such as
      `"image_pipe.source.fetch_decode"`. HTTP source requests add
      `"image_pipe.http.client"` and Finch spans such as `"finch.connect"`.
    * `:attributes`: the event's start metadata merged with its stop
      metadata, stop values winning. Only keys on an allowlist of values that
      are safe to export are copied. Request paths, source URLs, signatures,
      and credentials are never among them. `"image_pipe.http.client"`
      instead carries `"http.status_code"`, or `"error.type"` on failure,
      and a Finch span carries `"http.status_code"` when a response arrived.
    * `:events`: the one-shot events that fired while the span was open, each
      with `:name`, `:time` (native monotonic time), and allowlisted
      `:attributes`. A span that raised also has an `"exception"` event with
      `:name` and `:attributes` (`:kind` and `:reason`), but no `:time`.
    * `:status`: `:ok` when the event has no `:result`, or its `:result` is
      one of `:ok`, `:admitted`, `:options`, `:not_modified`, `:detected`,
      `:no_regions`, `:rejected`, `:client_closed`, or `:cancelled`. Any
      other `:result`, and any exception, gives `:error`. The
      [telemetry event reference](telemetry-events.md) lists which events
      emit each result.
    * `:status_message`: on an exception, `inspect/1` of the raised reason.
      It isn't filtered and can contain an exception message, as can the
      `reason` attribute of an `"exception"` event.
    * `:duration_native`: the duration in native time units. For
      `image_pipe.http.client`, the time until the response's status and
      headers arrived.

  An exporter that sends spans to a third party is responsible for what it
  sends, including `:status_message`.
  """
  alias ImagePipe.Telemetry.Trace.Span

  @doc """
  Receives one finished span. Must return `:ok`.
  """
  @callback export(Span.t()) :: :ok

  @doc """
  Optional. Returns whether the exporter can run, checked by
  `ImagePipe.Telemetry.attach_tracer/1`.

  Return `false` when the exporter can't work, for example when an optional
  dependency isn't loaded. `attach_tracer/1` then raises `ArgumentError` at
  startup. An exporter without this callback is always ready.
  """
  @callback ready?() :: boolean()

  @optional_callbacks ready?: 0
end
