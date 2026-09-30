defmodule ImagePipe.Telemetry.Trace.Id do
  @moduledoc false

  @spec trace_id() :: String.t()
  def trace_id, do: 16 |> :crypto.strong_rand_bytes() |> Base.encode16(case: :lower)

  @spec span_id() :: String.t()
  def span_id, do: 8 |> :crypto.strong_rand_bytes() |> Base.encode16(case: :lower)
end
