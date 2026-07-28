defmodule ImagePipe.Source.WrappedStream do
  @moduledoc false

  alias ImagePipe.Source.StreamError

  # Wraps a source body stream to enforce `max_body_bytes` and reject non-binary
  # chunks while it is drained. The sole production consumer drains it eagerly
  # (`ImagePipe.Decode`), which classifies any *other* failure of the underlying
  # source as `{:source, :stream_exception}`. This wrapper only raises the two
  # source-side `StreamError`s it is responsible for.
  @spec new(Enumerable.t(), non_neg_integer() | :infinity) :: Enumerable.t()
  def new(stream, max_body_bytes) do
    Stream.transform(stream, 0, fn chunk, size ->
      binary = validate_chunk(chunk)
      new_size = add_size(size, binary, max_body_bytes)
      {[binary], new_size}
    end)
  end

  defp validate_chunk(chunk) when is_binary(chunk), do: chunk
  defp validate_chunk(_chunk), do: raise(StreamError, reason: :invalid_stream_chunk)

  defp add_size(size, binary, :infinity), do: size + byte_size(binary)

  defp add_size(size, binary, max_body_bytes)
       when is_integer(max_body_bytes) and max_body_bytes >= 0 do
    new_size = size + byte_size(binary)

    if new_size <= max_body_bytes do
      new_size
    else
      raise StreamError, reason: :body_too_large
    end
  end
end
