defmodule ImagePipe.Telemetry.Trace.W3C do
  @moduledoc false
  alias ImagePipe.Telemetry.Trace.Context

  @all_zero_trace String.duplicate("0", 32)
  @all_zero_span String.duplicate("0", 16)

  @spec encode(String.t(), String.t(), non_neg_integer()) :: String.t()
  def encode(trace_id, span_id, flags \\ 1) do
    "00-" <> trace_id <> "-" <> span_id <> "-" <> flags_hex(flags)
  end

  @spec decode(String.t()) :: {:ok, Context.t()} | :error
  def decode(<<"00-", t::binary-size(32), "-", s::binary-size(16), "-", f::binary-size(2)>>)
      when t != @all_zero_trace and s != @all_zero_span do
    with true <- hex?(t),
         true <- hex?(s),
         true <- hex?(f) do
      {:ok, %Context{trace_id: t, span_id: s, trace_flags: String.to_integer(f, 16)}}
    else
      _ -> :error
    end
  end

  def decode(_), do: :error

  defp flags_hex(flags) do
    flags |> Integer.to_string(16) |> String.downcase() |> String.pad_leading(2, "0")
  end

  defp hex?(s), do: String.match?(s, ~r/\A[0-9a-f]+\z/)
end
