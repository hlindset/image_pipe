defmodule ImagePipe.Dialect.Native.Delivery.Producer do
  @moduledoc false

  # Demand-driven producer process for the native dialect's streaming delivery,
  # modeled on `ImagePipe.Request.SourceSession.Producer`'s message protocol
  # (`{:next, receiver, ref}` / `{:halt, receiver, ref}`, replying
  # `{ref, result}`), with one structural difference from that precedent:
  # `build_fun` is opaque here (this module knows nothing about
  # decode/transform/encode). `build_fun` is a 1-arity function that receives
  # `pump` and MUST call it exactly once, from inside its own nested brackets
  # (e.g. `ImagePipe.Decode.with_image/4`'s callback), once it has an encoder
  # `Enumerable` ready — see `ImagePipe.Dialect.Native.Delivery`'s moduledoc for
  # the bracket-containment invariant this enforces: the pump loop below runs
  # for as long as `build_fun` stays "inside" its own callback stack, so the
  # lazy image/encoder never escapes to another process.
  #
  # `pump/5` replies the FIRST chunk to the caller/ref that requested it (the
  # same demand that triggered `build_fun` to run in the first place), then
  # `pump_loop/1` continues answering later `:next`/`:halt` demand from
  # whichever process sends it (normally the coordinator).

  @type pump_result :: :done | :halted | :empty
  @type pump :: (Enumerable.t(), String.t(), term() -> pump_result())
  @type build_fun :: (pump() -> pump_result() | {:error, term()})

  @spec start_link(build_fun()) :: {:ok, pid()}
  def start_link(build_fun) when is_function(build_fun, 1) do
    caller_chain = Process.get(:"$callers", [])

    pid =
      spawn_link(fn ->
        Process.put(:"$callers", caller_chain)
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
          build_fun.(fn stream, content_type, resolved_output ->
            pump(stream, content_type, resolved_output, caller, ref)
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

  defp pump(stream, content_type, resolved_output, caller, ref) do
    case safe_reduce(stream) do
      {:ok, chunk, stream_state} ->
        send(caller, {ref, {:ok, {:first_chunk, chunk, content_type, resolved_output}}})
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

  # -- stream demand pull (mirrors Request.SourceSession.Producer) ----------

  defp safe_reduce(stream) do
    reduce_stream(stream)
  rescue
    exception -> {:error, {:encode, exception, __STACKTRACE__}}
  catch
    kind, reason -> {:error, {:encode, {kind, reason}, []}}
  end

  defp reduce_stream(stream) do
    result =
      Enumerable.reduce(stream, {:cont, nil}, fn
        chunk, _previous when is_binary(chunk) and byte_size(chunk) > 0 -> {:suspend, chunk}
        _chunk, previous -> {:cont, previous}
      end)

    case result do
      {:suspended, chunk, continuation} when is_binary(chunk) ->
        {:ok, chunk, {chunk, continuation}}

      {:done, _previous} ->
        :empty

      {:halted, _previous} ->
        :empty
    end
  end

  defp safe_continue(stream_state) do
    continue_stream(stream_state)
  rescue
    exception -> {:error, {:encode, exception, __STACKTRACE__}}
  catch
    kind, reason -> {:error, {:encode, {kind, reason}, []}}
  end

  defp continue_stream({acc, continuation}) do
    continuation.({:cont, acc}) |> reduce_result()
  end

  defp reduce_result({:suspended, chunk, continuation}) when is_binary(chunk),
    do: {:ok, chunk, {chunk, continuation}}

  defp reduce_result({:done, _previous}), do: :done
  defp reduce_result({:halted, _previous}), do: :done

  defp halt_stream({acc, continuation}) do
    continuation.({:halt, acc})
    :ok
  catch
    _kind, _reason -> :ok
  end
end
