defmodule ImagePipe.Delivery.StreamPull do
  @moduledoc false

  # The encoder-stream demand protocol, in one place: pull one encoded chunk at
  # a time off an `Enumerable` while keeping its suspended continuation, resume
  # it later, and halt it so the encoder finalizes.
  #
  # Two callers, because the first pull is load-bearing on both sides of the
  # producer boundary:
  #
  #   * `ImagePipe.Delivery.Producer` runs the chunk-demand loop.
  #   * a calling dialect may need to force the first chunk itself (pulling it
  #     is what makes libvips actually encode, so it has to happen inside that
  #     dialect's own encode span/timing) and then hand `pump` a `resume/2`
  #     enumerable that replays it.
  #
  # Raw and untranslated: every function here may raise whatever the underlying
  # stream raises. Callers own the throw -> tagged-error translation, because
  # they are the ones that know which phase the failure belongs to.

  @type stream_state() :: {binary(), (term() -> term())}

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
  An `Enumerable` that replays `first_chunk` (already pulled by the caller) and
  then resumes `stream_state`, propagating a halt into the underlying
  continuation — including when the halt lands while the replayed chunk is the
  current element, which is the common cancel-after-first-chunk case.
  """
  @spec resume(binary(), stream_state()) :: Enumerable.t()
  def resume(first_chunk, stream_state) do
    Stream.resource(
      fn -> {:first, first_chunk, stream_state} end,
      &resume_next/1,
      &resume_after/1
    )
  end

  defp resume_next({:first, chunk, stream_state}), do: {[chunk], stream_state}

  defp resume_next(stream_state) do
    case continue(stream_state) do
      {:ok, chunk, stream_state} -> {[chunk], stream_state}
      :done -> {:halt, :done}
    end
  end

  defp resume_after(:done), do: :ok
  defp resume_after({:first, _chunk, stream_state}), do: halt(stream_state)
  defp resume_after({_acc, _continuation} = stream_state), do: halt(stream_state)

  defp reduce_result({:suspended, chunk, continuation}) when is_binary(chunk),
    do: {:ok, chunk, {chunk, continuation}}

  defp reduce_result({:done, _previous}), do: :empty
  defp reduce_result({:halted, _previous}), do: :empty
end
