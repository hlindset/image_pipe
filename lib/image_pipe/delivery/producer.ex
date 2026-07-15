defmodule ImagePipe.Delivery.Producer do
  @moduledoc false

  # Demand-driven producer process for a streaming delivery. Its message
  # protocol is `{:next, receiver, ref}` / `{:halt, receiver, ref}`, replying
  # `{ref, result}`. `build_fun` is opaque here (this module knows nothing
  # about decode/transform/encode): it is a 1-arity function that receives
  # `pump` and MUST call it exactly once, from inside its own nested brackets
  # (e.g. `ImagePipe.Decode.with_image/4`'s callback), once it has an encoder
  # `Enumerable` ready — see `ImagePipe.Delivery`'s moduledoc for
  # the bracket-containment invariant this enforces: the pump loop below runs
  # for as long as `build_fun` stays "inside" its own callback stack, so the
  # lazy image/encoder never escapes to another process.
  #
  # `pump/6` replies the FIRST chunk to the caller/ref that requested it (the
  # same demand that triggered `build_fun` to run in the first place), then
  # `pump_loop/1` continues answering later `:next`/`:halt` demand from
  # whichever process sends it (normally the coordinator).
  #
  # `pump`'s fourth argument is the calling dialect's `%Debug.Info{}` (or
  # `nil` for a dialect that collects none). The first-chunk reply is the only
  # channel it can take: debug facts are collected here, in the producer, from
  # values only this process sees (decoded dimensions, stage timings, encode
  # search metadata), and they are needed on the far side of the hop by both
  # the coordinator (which stores them on the cache entry) and the
  # `%PreparedStream{}` (which renders them as headers).

  alias ImagePipe.Debug.Info
  alias ImagePipe.Delivery.StreamPull
  alias ImagePipe.Telemetry.Trace

  @type pump_result :: :done | :halted | :empty
  @type pump :: (Enumerable.t(), String.t(), term(), Info.t() | nil -> pump_result())
  @type build_fun :: (pump() -> pump_result() | {:error, term()})

  @spec start_link(build_fun(), Trace.Context.t() | nil) :: {:ok, pid()}
  def start_link(build_fun, trace_context) when is_function(build_fun, 1) do
    caller_chain = Process.get(:"$callers", [])

    pid =
      spawn_link(fn ->
        Process.put(:"$callers", caller_chain)
        # Hop B: adopt the request's trace context (passed as data, since the
        # spawned process does not inherit the caller's trace stack) so spans
        # emitted from inside `build_fun` nest under the request root.
        Trace.Stack.adopt(trace_context)
        run(build_fun)
      end)

    {:ok, pid}
  end

  @spec request_next(pid(), pid()) :: reference()
  def request_next(pid, receiver) when is_pid(pid) and is_pid(receiver) do
    ref = make_ref()
    send(pid, {:next, receiver, ref})
    ref
  end

  @spec request_halt(pid(), pid()) :: reference()
  def request_halt(pid, receiver) when is_pid(pid) and is_pid(receiver) do
    ref = make_ref()
    send(pid, {:halt, receiver, ref})
    ref
  end

  defp run(build_fun) do
    receive do
      {:next, caller, ref} ->
        result =
          build_fun.(fn stream, content_type, resolved_output, debug ->
            pump(stream, content_type, resolved_output, debug, caller, ref)
          end)

        finish(result, caller, ref)

      {:halt, caller, ref} ->
        # Nothing was ever demanded (unreachable via the public Delivery API,
        # which always demands the first chunk before returning a
        # %PreparedStream{} to a caller who could then request a halt — kept
        # as a defensive terminal clause, not a real protocol state).
        send(caller, {ref, :ok})
    end
  end

  # `build_fun` returning an {:error, _} means it never reached `pump` (a
  # fetch/decode/transform/encode failure) — nobody has been replied to yet.
  # Any other return means `pump`/`pump_loop` already sent their own reply.
  defp finish({:error, _reason} = result, caller, ref), do: send(caller, {ref, result})
  defp finish(_pump_terminal, _caller, _ref), do: :ok

  defp pump(stream, content_type, resolved_output, debug, caller, ref) do
    case safe_reduce(stream) do
      {:ok, chunk, stream_state} ->
        send(caller, {ref, {:ok, {:first_chunk, chunk, content_type, resolved_output, debug}}})
        pump_loop(stream_state)

      :empty ->
        send(caller, {ref, {:error, {:encode, :empty_stream}}})
        :empty

      {:error, reason} ->
        send(caller, {ref, {:error, reason}})
        :empty
    end
  end

  defp pump_loop(stream_state) do
    receive do
      {:next, caller, ref} ->
        case safe_continue(stream_state) do
          {:ok, chunk, new_state} ->
            send(caller, {ref, {:ok, {:chunk, chunk}}})
            pump_loop(new_state)

          :done ->
            send(caller, {ref, {:ok, :done}})
            :done

          {:error, reason} ->
            send(caller, {ref, {:error, reason}})
            :done
        end

      {:halt, caller, ref} ->
        halt_stream(stream_state)
        send(caller, {ref, :ok})
        :halted
    end
  end

  # -- stream demand pull ---------------------------------------------------

  defp safe_reduce(stream) do
    StreamPull.translate(fn -> StreamPull.first_chunk(stream) end)
  end

  defp safe_continue(stream_state) do
    StreamPull.translate(fn -> StreamPull.continue(stream_state) end)
  end

  defp halt_stream(stream_state), do: StreamPull.halt(stream_state)
end
