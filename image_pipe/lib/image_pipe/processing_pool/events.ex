defmodule ImagePipe.ProcessingPool.Events do
  @moduledoc false

  alias ImagePipe.Telemetry
  alias ImagePipe.Telemetry.RequestContext
  alias ImagePipe.Telemetry.Trace.Stack

  # Each job has its own trace frame and Logger metadata: the shared pool never
  # retains one job's context while servicing another job.
  def start(config, stage, request, metadata) do
    RequestContext.within(request, fn ->
      handle = Telemetry.start_span(config, [:processing, stage], metadata)
      {handle, Stack.current(), RequestContext.capture()}
    end)
  end

  def context({_handle, _frame, request}), do: request

  def stop({handle, frame, request}, result) do
    RequestContext.within(request, fn ->
      if frame, do: Stack.push(frame)
      Telemetry.stop_span(handle, %{result: result})
    end)
  end
end
