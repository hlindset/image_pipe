defmodule ImagePipe.ProcessingPool.Events do
  @moduledoc false

  alias ImagePipe.Telemetry
  alias ImagePipe.Telemetry.Trace.Stack

  # Each job has its own trace frame: the shared pool never retains one job's
  # context on its process stack while servicing another job.
  def start(config, stage, context, metadata) do
    Stack.adopt(context)
    handle = Telemetry.start_span(config, [:processing, stage], metadata)
    {handle, Stack.current(), Stack.context()}
  after
    Stack.clear()
  end

  def context({_handle, _frame, context}), do: context

  def stop({handle, frame, _context}, result) do
    if frame, do: Stack.push(frame)
    Telemetry.stop_span(handle, %{result: result})
  after
    Stack.clear()
  end
end
