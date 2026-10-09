defmodule ImagePipe.ProcessingPool.Events do
  @moduledoc false

  alias ImagePipe.Telemetry
  alias ImagePipe.Telemetry.RequestContext

  # Each job's span opens and closes under the job's own request context: the
  # shared pool never retains one job's context while servicing another job.
  # The returned context has the span current, for the job's own work to nest
  # under.
  def start(config, stage, request, metadata) do
    RequestContext.within(request, fn ->
      handle = Telemetry.start_span(config, [:processing, stage], metadata)
      {handle, RequestContext.capture()}
    end)
  end

  def context({_handle, context}), do: context

  def stop({handle, context}, result) do
    RequestContext.within(context, fn ->
      Telemetry.stop_span(handle, %{result: result})
    end)
  end
end
