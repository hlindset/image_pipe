defmodule ImagePipe.Telemetry.Trace.Exporter do
  @moduledoc """
  Behaviour a host implements to receive captured spans, one per completed span.

  `export/1` is called synchronously in the process that emitted the span's `:stop`/
  `:exception`. Keep it cheap and non-blocking — hand off to a batch processor for any
  real I/O. It must return `:ok` and should not raise. Attributes are pre-filtered for
  sensitivity (`ImagePipe.Telemetry.Trace.Capture` allowlists them), but exporters that
  fan out to third parties remain responsible for their own egress policy.
  """
  alias ImagePipe.Telemetry.Trace.Span

  @callback export(Span.t()) :: :ok

  @doc """
  Optional readiness gate, consulted by `ImagePipe.Telemetry.attach_tracer/1`.

  Return `false` when the exporter cannot run (e.g. an optional backend dependency
  is not loaded). `attach_tracer/1` raises `ArgumentError` instead of attaching,
  turning a missing dependency into an actionable startup error rather than a
  per-request crash. Exporters that omit this callback are always considered ready.
  """
  @callback ready?() :: boolean()

  @optional_callbacks ready?: 0
end
