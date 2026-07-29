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
  # The pull functions are raw: `first_chunk/1`, `continue/1` and `resume/2`
  # each let whatever the underlying stream raises propagate. `translate/2`
  # wraps a pull in the throw -> tagged-error taxonomy both callers share; the
  # phase-specific part (the tag for a non-`StreamError` throw) is the caller's,
  # passed as `fallback`.

  alias ImagePipe.Source.StreamError

  @type stream_state() :: {binary(), (term() -> term())}
  @type tagged_error() :: {:error, term()}
  @type fallback() :: (Exception.kind(), term() -> tagged_error())

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
  then resumes `stream_state`.

  Finalization of the underlying continuation happens exactly once, on every
  exit path: a halt (from either the consumer's reducer or the consumer's own
  `{:halt, acc}` demand) halts it; reaching the end does not, because a stream
  that ran to `:done` finalized itself; and a raise does not, because the
  exception already unwound through the underlying reduce, running its
  finalizer on the way out. This is why it is a hand-rolled `Enumerable` and
  not a `Stream.resource/3`: `Stream.resource/3` calls its `after_fun` with the
  accumulator it was about to advance, so a raise from `continue/1` would halt
  the continuation the raise had just spent, finalizing it a second time.
  """
  @spec resume(binary(), stream_state()) :: Enumerable.t()
  def resume(first_chunk, stream_state) do
    &resume_reduce({[first_chunk], stream_state}, &1, &2)
  end

  # State is `{chunks_to_replay, stream_state}`, so every clause below reaches
  # the same live continuation and a halt finalizes it in one place.
  defp resume_reduce({_replay, stream_state}, {:halt, acc}, _fun) do
    halt(stream_state)
    {:halted, acc}
  end

  defp resume_reduce(state, {:suspend, acc}, fun) do
    {:suspended, acc, &resume_reduce(state, &1, fun)}
  end

  defp resume_reduce({[chunk | replay], stream_state}, {:cont, acc}, fun) do
    emit(chunk, {replay, stream_state}, acc, fun)
  end

  defp resume_reduce({[], stream_state}, {:cont, acc}, fun) do
    # A raise here has already finalized the underlying stream on its way out;
    # it must propagate untouched, with no halt of the spent continuation.
    case continue(stream_state) do
      {:ok, chunk, stream_state} -> emit(chunk, {[], stream_state}, acc, fun)
      :done -> {:done, acc}
    end
  end

  defp emit(chunk, next_state, acc, fun) do
    case fun.(chunk, acc) do
      {:cont, acc} -> resume_reduce(next_state, {:cont, acc}, fun)
      {:halt, acc} -> resume_reduce(next_state, {:halt, acc}, fun)
      {:suspend, acc} -> {:suspended, acc, &resume_reduce(next_state, &1, fun)}
    end
  end

  @doc """
  Runs `fun` (a pull) under the shared throw -> tagged-error taxonomy.

  A `ImagePipe.Source.StreamError` escaping a pumped stream is a SOURCE
  failure and must keep the source's domain status (422/404/502) rather than
  degrading to the 500 an `{:encode, _}` tag would produce
  (`ImagePipe.Response.ErrorStatus`). Any other throw is a fault in the calling
  dialect's encode/stream; `fallback` builds its tag, so a caller can keep a
  phase-specific one while defaulting to the encode tag.
  """
  @spec translate((-> result)) :: result | tagged_error() when result: term()
  def translate(fun) when is_function(fun, 0), do: translate(&encode_fallback/2, fun)

  @spec translate(fallback(), (-> result)) :: result | tagged_error() when result: term()
  def translate(fallback, fun) when is_function(fallback, 2) and is_function(fun, 0) do
    fun.()
  rescue
    exception in [StreamError] -> {:error, {:source, exception.reason}}
    exception -> {:error, {:encode, exception, __STACKTRACE__}}
  catch
    :exit, {%StreamError{reason: reason}, _stacktrace} -> {:error, {:source, reason}}
    :exit, %StreamError{reason: reason} -> {:error, {:source, reason}}
    kind, reason -> fallback.(kind, reason)
  end

  defp encode_fallback(kind, reason), do: {:error, {:encode, {kind, reason}, []}}

  defp reduce_result({:suspended, chunk, continuation}) when is_binary(chunk),
    do: {:ok, chunk, {chunk, continuation}}

  defp reduce_result({:done, _previous}), do: :empty
  defp reduce_result({:halted, _previous}), do: :empty
end
