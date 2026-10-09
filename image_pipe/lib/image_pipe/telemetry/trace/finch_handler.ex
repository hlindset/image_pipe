defmodule ImagePipe.Telemetry.Trace.FinchHandler do
  @moduledoc false
  # Records a span for each Finch phase of a source's HTTP request (queue,
  # connect, send, recv, and the request as a whole), under the
  # `image_pipe.http.client` span that `ReqStep` puts in the request's
  # `finch_private`. Finch reports a phase when it ends, so each span is
  # created and ended at once, timed from the event's duration.

  @compile {:no_warn_undefined, [:otel_ctx, :otel_span, :otel_tracer]}

  alias ImagePipe.Telemetry.Trace.Handler

  @handler_id {__MODULE__, :finch}

  # Shared with ReqStep, which stamps the client span here.
  @finch_private_key :image_pipe_trace

  @events for phase <- [:request, :queue, :connect, :send, :recv],
              suffix <- [:stop, :exception],
              do: [:finch, phase, suffix]

  @spec attach() :: :ok
  def attach do
    _ = :telemetry.detach(@handler_id)
    _ = :telemetry.attach_many(@handler_id, @events, &__MODULE__.handle_event/4, nil)
    :ok
  end

  @spec detach() :: :ok
  def detach do
    _ = :telemetry.detach(@handler_id)
    :ok
  end

  def handle_event([:finch, phase, _suffix], measurements, meta, _config) do
    with %{private: %{@finch_private_key => parent}} <- Map.get(meta, :request) do
      end_time = :erlang.monotonic_time()
      parent_ctx = :otel_tracer.set_current_span(:otel_ctx.new(), parent)

      span_ctx =
        :otel_tracer.start_span(parent_ctx, Handler.tracer(), "finch.#{phase}", %{
          start_time: end_time - measurements.duration,
          kind: :client,
          attributes: attributes(meta)
        })

      if error?(meta), do: :otel_span.set_status(span_ctx, :error, "")
      :otel_span.end_span(span_ctx, end_time)
    end

    :ok
  rescue
    # A tracer must never crash the request path; drop the event on any internal error.
    _ -> :ok
  end

  defp error?(%{result: {:error, _reason}}), do: true
  defp error?(%{kind: _kind}), do: true
  defp error?(_meta), do: false

  defp attributes(%{result: {:ok, %{status: status}}}), do: %{"http.status_code": status}
  defp attributes(_meta), do: %{}
end
