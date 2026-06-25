defmodule ImagePipe.Parser.Imgproxy.PercentEncoding do
  @moduledoc false

  # Shared percent-decoding helpers for the imgproxy path parser. Decoding
  # rejects malformed escapes rather than silently passing them through, so a
  # crafted `%`-sequence cannot smuggle bytes past validation.

  @malformed ~r/%($|[^0-9A-Fa-f]|[0-9A-Fa-f]$|[0-9A-Fa-f][^0-9A-Fa-f])/

  @doc "Percent-decodes `value`, rejecting malformed percent-escape sequences."
  @spec decode(String.t()) ::
          {:ok, String.t()} | {:error, {:invalid_percent_encoding, String.t()}}
  def decode(value) do
    if malformed?(value) do
      {:error, {:invalid_percent_encoding, value}}
    else
      {:ok, URI.decode(value)}
    end
  rescue
    ArgumentError -> {:error, {:invalid_percent_encoding, value}}
  end

  @doc "Returns true when `value` contains a malformed percent-escape sequence."
  @spec malformed?(String.t()) :: boolean()
  def malformed?(value), do: String.match?(value, @malformed)

  @doc """
  Percent-decodes each segment in order, halting on the first malformed one.
  """
  @spec decode_segments([String.t()]) ::
          {:ok, [String.t()]} | {:error, {:invalid_percent_encoding, String.t()}}
  def decode_segments(segments) do
    segments
    |> Enum.reduce_while({:ok, []}, fn segment, {:ok, decoded_segments} ->
      case decode(segment) do
        {:ok, decoded_segment} -> {:cont, {:ok, [decoded_segment | decoded_segments]}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, decoded_segments} -> {:ok, Enum.reverse(decoded_segments)}
      {:error, _reason} = error -> error
    end
  end
end
