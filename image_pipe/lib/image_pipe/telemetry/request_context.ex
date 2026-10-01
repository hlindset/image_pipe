defmodule ImagePipe.Telemetry.RequestContext do
  @moduledoc false
  # What a request carries across ImagePipe's process hops: its trace context
  # and the caller's Logger metadata, so spans nest under the request root and
  # log lines and telemetry handlers keep the host's metadata (such as
  # `Plug.RequestId`'s `:request_id`) in every process that serves it.

  alias ImagePipe.Telemetry.Trace.{Context, Stack}

  @type t :: {Context.t() | nil, keyword()}

  @spec capture() :: t()
  def capture, do: {Stack.context(), Logger.metadata()}

  @spec trace(t()) :: Context.t() | nil
  def trace({trace, _metadata}), do: trace

  # Seeds a process that serves only this request.
  @spec adopt(t()) :: :ok
  def adopt({trace, metadata}) do
    Logger.metadata(metadata)
    Stack.adopt(trace)
  end

  # Runs `fun` with the request's context in a process shared by many
  # requests, restoring that process's own trace stack and metadata after.
  @spec within(t(), (-> result)) :: result when result: term()
  def within({trace, metadata}, fun) do
    own = Logger.metadata()
    Logger.metadata(metadata)
    Stack.adopt(trace)

    try do
      fun.()
    after
      Stack.clear()
      Logger.reset_metadata(own)
    end
  end
end
