defmodule ImagePipe.Telemetry.Trace.FinchCapture do
  @moduledoc false
  alias ImagePipe.Telemetry.Trace.{Id, Span}

  @handler_id {__MODULE__, :finch}

  # Shared finch_private key — must match @priv in ReqStep (both stamp/read this atom).
  @finch_private_key :image_pipe_trace

  # Finch span events worth a physical wire span. We attach to the stop/exception
  # boundaries (durations are meaningful there). The logical client span comes from
  # ReqStep; these are the Finch-level children.
  @events [
    [:finch, :request, :stop],
    [:finch, :request, :exception],
    [:finch, :queue, :stop],
    [:finch, :queue, :exception],
    [:finch, :connect, :stop],
    [:finch, :connect, :exception],
    [:finch, :send, :stop],
    [:finch, :send, :exception],
    [:finch, :recv, :stop],
    [:finch, :recv, :exception]
  ]

  @spec attach(%{exporter: module()}) :: :ok
  def attach(%{exporter: exporter}) do
    _ = :telemetry.detach(@handler_id)

    _ =
      :telemetry.attach_many(
        @handler_id,
        @events,
        &__MODULE__.handle_event/4,
        %{exporter: exporter}
      )

    :ok
  end

  @spec detach() :: :ok
  def detach do
    _ = :telemetry.detach(@handler_id)
    :ok
  end

  # FinchCapture parents via finch_private (NOT the active span stack): Finch events
  # fire in the Producer/caller process and may interleave across retries, so the
  # parent identity is carried on the request struct rather than read off the stack.
  def handle_event([:finch | rest], measurements, meta, config) do
    with %{} = request <- Map.get(meta, :request),
         %{@finch_private_key => {trace_id, parent_span_id, flags}} <-
           Map.get(request, :private, %{}) do
      config.exporter.export(%Span{
        trace_id: trace_id,
        span_id: Id.span_id(),
        parent_span_id: parent_span_id,
        name: "finch." <> Enum.map_join(Enum.drop(rest, -1), ".", &Atom.to_string/1),
        kind: :client,
        start_time: measurements[:system_time],
        duration_native: measurements[:duration],
        trace_flags: flags,
        status: status(meta),
        attributes: attributes(meta),
        pid: self(),
        node: node()
      })

      :ok
    else
      _ -> :ok
    end
  rescue
    # A tracer must never crash the request path; drop the event on any internal error.
    _ -> :ok
  end

  defp status(%{result: {:error, _reason}}), do: :error
  defp status(%{kind: _kind}), do: :error
  defp status(_meta), do: :ok

  defp attributes(%{result: {:ok, %{status: status}}}), do: %{"http.status_code": status}
  defp attributes(_meta), do: %{}
end
