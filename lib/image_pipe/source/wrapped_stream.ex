defmodule ImagePipe.Source.WrappedStream do
  @moduledoc false

  alias ImagePipe.Source.StreamError

  # Enforce source body limits while chunks are consumed.
  @spec new(Enumerable.t(), non_neg_integer() | :infinity) :: Enumerable.t()
  def new(stream, max_body_bytes) do
    Stream.transform(stream, 0, fn chunk, size ->
      binary = validate_chunk(chunk)
      new_size = add_size(size, binary, max_body_bytes)
      {[binary], new_size}
    end)
  end

  # Enumerable invokes the consumer inside its own stack. Tag consumer failures
  # so they escape unchanged while failures producing source chunks are classified.
  def reduce(stream, accumulator, consumer) do
    marker = make_ref()

    try do
      Enum.reduce(stream, accumulator, fn chunk, acc ->
        try do
          consumer.(chunk, acc)
        catch
          kind, reason -> throw({marker, kind, reason, __STACKTRACE__})
        end
      end)
    rescue
      exception in StreamError -> reraise exception, __STACKTRACE__
      _exception -> reraise StreamError, [reason: :stream_exception], __STACKTRACE__
    catch
      :throw, {^marker, kind, reason, stacktrace} -> :erlang.raise(kind, reason, stacktrace)
      _kind, _reason -> raise StreamError, reason: :stream_exception
    end
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
