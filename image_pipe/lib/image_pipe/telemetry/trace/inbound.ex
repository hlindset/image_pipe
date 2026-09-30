defmodule ImagePipe.Telemetry.Trace.Inbound do
  @moduledoc false
  alias ImagePipe.Telemetry.Trace.Context

  @key :"$image_pipe_trace_inbound"

  @spec put(Context.t()) :: :ok
  def put(%Context{} = ctx) do
    Process.put(@key, ctx)
    :ok
  end

  @doc "Read and clear the inbound context (consumed once by the root span)."
  @spec take() :: Context.t() | nil
  def take, do: Process.delete(@key)
end
