defmodule ImagePipe.Telemetry.Trace do
  @moduledoc "Public facade for the opt-in span tracer."

  alias ImagePipe.Telemetry.Trace.{Inbound, W3C}

  @exporter_key {__MODULE__, :exporter}
  @extract_key {__MODULE__, :extract_inbound}

  @doc false
  def set_exporter(mod), do: :persistent_term.put(@exporter_key, mod)

  @doc "The active exporter module, or nil when no tracer is attached."
  def exporter, do: :persistent_term.get(@exporter_key, nil)

  @doc false
  @spec set_extract_inbound(boolean()) :: :ok
  def set_extract_inbound(flag), do: :persistent_term.put(@extract_key, flag == true)

  @doc false
  @spec maybe_extract_inbound(Plug.Conn.t()) :: :ok
  def maybe_extract_inbound(conn) do
    if :persistent_term.get(@extract_key, false) do
      conn |> Plug.Conn.get_req_header("traceparent") |> adopt_traceparent()
    else
      :ok
    end
  end

  defp adopt_traceparent([tp | _]) do
    case W3C.decode(tp) do
      {:ok, ctx} -> Inbound.put(ctx)
      :error -> :ok
    end
  end

  defp adopt_traceparent([]), do: :ok
end
