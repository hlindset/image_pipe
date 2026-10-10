defmodule ImagePipe.Delivery.StreamPull do
  @moduledoc false

  # Pull encoded chunks one at a time, retaining the suspended continuation for
  # later demands or halting it to finalize the encoder.
  #
  # Callers:
  #
  #   * `ImagePipe.Delivery.Producer` runs the chunk-demand loop.
  #   * The runner pulls the first chunk inside its encode span to time libvips'
  #     actual work, then hands pump the chunk and the suspended stream.
  #
  # first_chunk/1 and continue/1 propagate stream failures. translate/1
  # converts them to shared error tags.

  alias ImagePipe.Source.StreamError

  @type stream_state() :: {binary(), (term() -> term())}
  @type tagged_error() :: {:error, term()}

  @doc """
  Reduces `stream` until its first non-empty binary chunk, suspending there.
  """
  @spec first_chunk(Enumerable.t()) :: {:ok, binary(), stream_state()} | :empty
  def first_chunk(stream) do
    stream
    |> Enumerable.reduce({:cont, nil}, fn
      chunk, _previous when is_binary(chunk) and byte_size(chunk) > 0 -> {:suspend, chunk}
      _chunk, previous -> {:cont, previous}
    end)
    |> reduce_result()
  end

  @doc """
  Resumes a suspended stream for one more chunk.
  """
  @spec continue(stream_state()) :: {:ok, binary(), stream_state()} | :done
  def continue({acc, continuation}) do
    case continuation.({:cont, acc}) |> reduce_result() do
      {:ok, _chunk, _stream_state} = ok -> ok
      :empty -> :done
    end
  end

  @doc """
  Halts a suspended stream so the underlying encoder finalizes. Swallows
  throws: the stream is being abandoned, and a failure to finalize must not
  mask the reason it was abandoned.
  """
  @spec halt(stream_state()) :: :ok
  def halt({acc, continuation}) do
    continuation.({:halt, acc})
    :ok
  catch
    _kind, _reason -> :ok
  end

  @doc """
  Runs `fun` (a pull) under the shared throw -> tagged-error taxonomy.

  A `ImagePipe.Source.StreamError` escaping a pumped stream is a SOURCE
  failure and must keep the source's domain status (such as 502 or 413) rather than
  degrading to the 500 an `{:encode, _}` tag would produce
  (`ImagePipe.Response.ErrorStatus`). Any other throw is a fault in the calling
  runner's encode/stream and receives an encode tag.
  """
  @spec translate((-> result)) :: result | tagged_error() when result: term()
  def translate(fun) when is_function(fun, 0) do
    fun.()
  rescue
    exception in [StreamError] -> {:error, {:source, exception.reason}}
    exception -> {:error, {:encode, exception, __STACKTRACE__}}
  catch
    :exit, {%StreamError{reason: reason}, _stacktrace} -> {:error, {:source, reason}}
    :exit, %StreamError{reason: reason} -> {:error, {:source, reason}}
    kind, reason -> {:error, {:encode, {kind, reason}, []}}
  end

  defp reduce_result({:suspended, chunk, continuation}) when is_binary(chunk),
    do: {:ok, chunk, {chunk, continuation}}

  defp reduce_result({:done, _previous}), do: :empty
  defp reduce_result({:halted, _previous}), do: :empty
end
