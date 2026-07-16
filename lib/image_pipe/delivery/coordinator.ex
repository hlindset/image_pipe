defmodule ImagePipe.Delivery.Coordinator do
  @moduledoc false

  # Monitor-based session coordinator for a streaming delivery, driving an
  # opaque `build_fun` (it knows nothing about decode/transform/encode).
  #
  # Monitor DIRECTION (the flagged invariant): a `spawn_monitor` from an owner
  # only watches the CHILD — owner-death detection requires the CHILD to
  # monitor the owner back. This coordinator does `Process.monitor(owner)` in
  # `init/1`, so an owner (conn process) dying mid-stream is observed here via
  # a `:DOWN` message, not the other way around.
  #
  # Bracket-cleanup note: this coordinator ALWAYS requests a graceful halt
  # first (`Producer.request_halt/2`), backstopped by a timeout that
  # force-kills a wedged producer. A forceful kill (`Process.exit/2` — the
  # producer never traps exits, so a non-:normal exit reason terminates it
  # immediately) would skip any `try/after` still on the producer's stack.
  # That matters because a calling dialect may run its whole encode/pump loop
  # INSIDE a bracket callback (e.g. `ImagePipe.Decode.with_image/4`) wrapped
  # in a `try/after`: killing forcefully would break the
  # cleanup-runs-exactly-once invariant on owner disconnect, not just on
  # explicit cancel.

  use GenServer

  alias ImagePipe.Cache
  alias ImagePipe.Debug.Info
  alias ImagePipe.Delivery.Producer
  alias ImagePipe.Telemetry.Trace

  @call_timeout 60_000
  @cancel_timeout 2_000

  defstruct [
    :build_fun,
    :owner,
    :owner_monitor,
    :cache_key,
    :trace_context,
    :config,
    :producer,
    :producer_monitor,
    :producer_request_ref,
    :pending,
    :cancel_reason,
    :cache_sink,
    :resolved_output,
    :content_type,
    :fetch_started_at,
    phase: :new
  ]

  @type server() :: GenServer.server()

  # No OTP supervisor and no link to the caller — the coordinator is reached
  # only via `Process.monitor/1` in both directions (this module monitors the
  # owner; a caller that wants teardown visibility monitors this process).
  # `GenServer.start/2` (not `start_link/2`) is deliberate: a link would tie
  # this process's fate to whichever process happened to call `start/4` (the
  # conn owner in production), which is not what "monitor-based" means here —
  # an owner dying should be *observed and handled* (graceful producer halt +
  # cache-sink abort), not have its death propagate as an exit signal.
  @spec start(
          Producer.build_fun(),
          pid(),
          Cache.Key.t() | nil,
          Trace.Context.t() | nil,
          keyword()
        ) ::
          GenServer.on_start()
  def start(build_fun, owner, cache_key, trace_context, config)
      when is_function(build_fun, 1) and is_pid(owner) do
    GenServer.start(__MODULE__, {build_fun, owner, cache_key, trace_context, config})
  end

  @spec prepare(server(), timeout()) :: {:ok, map()} | {:error, term()}
  def prepare(server, timeout \\ @call_timeout), do: call_session(server, :prepare, timeout)

  @spec next(server(), timeout()) :: {:chunk, binary()} | :done | {:error, term()}
  def next(server, timeout \\ @call_timeout), do: call_session(server, :next, timeout)

  @spec cancel(server(), timeout()) :: :ok | {:error, term()}
  def cancel(server, timeout \\ @cancel_timeout), do: call_session(server, :cancel, timeout)

  @impl GenServer
  def init({build_fun, owner, cache_key, trace_context, config}) when is_pid(owner) do
    Process.flag(:trap_exit, true)
    Process.put(:"$callers", [owner | Process.get(:"$callers", [])])
    # Hop A: adopt the request's trace context so spans emitted from THIS
    # process (e.g. [:cache, :write] at commit) nest under the request root.
    Trace.Stack.adopt(trace_context)

    {:ok,
     %__MODULE__{
       build_fun: build_fun,
       owner: owner,
       # THE flagged monitor direction: the coordinator watches the owner, not
       # the other way around.
       owner_monitor: Process.monitor(owner),
       cache_key: cache_key,
       trace_context: trace_context,
       config: config
     }}
  end

  @impl GenServer
  def handle_call(:prepare, from, %{phase: :new} = state) do
    fetch_started_at = System.monotonic_time(:microsecond)
    {:ok, producer} = Producer.start_link(state.build_fun, state.trace_context)
    ref = Process.monitor(producer)
    producer_ref = Producer.request_next(producer, self())

    {:noreply,
     %{
       state
       | producer: producer,
         producer_monitor: ref,
         phase: :preparing,
         pending: {:prepare, from},
         producer_request_ref: producer_ref,
         fetch_started_at: fetch_started_at
     }}
  end

  def handle_call(:next, from, %{phase: phase, producer: producer, pending: nil} = state)
      when phase in [:prepared, :streaming] and is_pid(producer) do
    ref = Producer.request_next(producer, self())
    {:noreply, %{state | phase: :streaming, pending: {:next, from}, producer_request_ref: ref}}
  end

  def handle_call(:cancel, from, %{pending: nil} = state) do
    case request_producer_halt(state, from, :cancelled) do
      {:ok, state} -> {:noreply, %{state | phase: :cancelled}}
      {:stop, state} -> {:stop, :normal, :ok, %{state | phase: :cancelled}}
    end
  end

  def handle_call(:cancel, from, %{pending: {_kind, pending_from}} = state) do
    state = reply_pending_from(pending_from, {:error, {:session, :cancelled}}, state)

    case request_producer_halt(%{state | pending: nil}, from, :cancelled) do
      {:ok, state} -> {:noreply, %{state | phase: :cancelled}}
      {:stop, state} -> {:stop, :normal, :ok, %{state | phase: :cancelled}}
    end
  end

  @impl GenServer
  def handle_info(
        {:DOWN, ref, :process, owner, reason},
        %{owner: owner, owner_monitor: ref, pending: pending} = state
      ) do
    state =
      case pending do
        {_kind, from} ->
          reply_pending_from(from, {:error, {:session, {:owner_down, reason}}}, state)

        nil ->
          state
      end

    halt_for_owner_down(state, reason)
  end

  def handle_info(
        {:DOWN, ref, :process, producer, reason},
        %{producer: producer, producer_monitor: ref, pending: {:cancel, from}} = state
      )
      when reason in [:normal, :shutdown] do
    state = state |> clear_producer() |> abort_cache_sink(state.cancel_reason || :cancelled)
    if from, do: GenServer.reply(from, :ok)
    {:stop, :normal, %{state | phase: :cancelled, pending: nil}}
  end

  def handle_info(
        {:DOWN, ref, :process, producer, reason},
        %{producer: producer, producer_monitor: ref} = state
      ) do
    state =
      state
      |> reply_pending({:error, producer_down_reason(reason)})
      |> abort_cache_sink(:stream_error)
      |> clear_producer()

    {:stop, :normal, mark_failed(%{state | pending: nil})}
  end

  def handle_info({ref, result}, %{producer_request_ref: ref} = state) when is_reference(ref) do
    handle_producer_result(result, %{state | producer_request_ref: nil})
  end

  def handle_info({:producer_halt_timeout, ref}, %{producer_request_ref: ref} = state) do
    from =
      case state.pending do
        {:cancel, f} -> f
        _ -> nil
      end

    state =
      state |> stop_producer(:shutdown) |> abort_cache_sink(state.cancel_reason || :cancelled)

    if from, do: GenServer.reply(from, :ok)
    {:stop, :normal, %{state | phase: :cancelled, pending: nil}}
  end

  # Linked producer exits are intentionally ignored. The monitor :DOWN is the
  # authoritative producer-death signal; delayed exits after stop_producer/2
  # are harmless once producer fields have been cleared.
  def handle_info({:EXIT, _pid, _reason}, state) do
    {:noreply, state}
  end

  def handle_info(_message, state) do
    {:noreply, state}
  end

  @impl GenServer
  def terminate(:normal, _state), do: :ok

  def terminate(reason, state) when reason in [:shutdown] do
    cleanup_shutdown(state, :cancelled)
    :ok
  end

  def terminate({:shutdown, {:owner_down, _reason}}, state) do
    cleanup_shutdown(state, :owner_down)
    :ok
  end

  def terminate({:shutdown, _reason}, state) do
    cleanup_shutdown(state, :cancelled)
    :ok
  end

  def terminate(_reason, state) do
    cleanup_shutdown(state, :stream_error)
    :ok
  end

  defp call_session(server, message, timeout) do
    GenServer.call(server, message, timeout)
  catch
    :exit, {:timeout, _call} -> {:error, {:session, :timeout}}
    :exit, {:noproc, _call} -> {:error, {:session, :noproc}}
    :exit, {{:shutdown, reason}, _call} -> {:error, {:session, {:shutdown, reason}}}
    :exit, {:shutdown, _call} -> {:error, {:session, {:shutdown, :shutdown}}}
    :exit, :shutdown -> {:error, {:session, {:shutdown, :shutdown}}}
    :exit, {reason, _call} -> {:error, {:session, {:exit, reason}}}
    :exit, reason -> {:error, {:session, {:exit, reason}}}
  end

  defp handle_producer_result(
         {:ok, {:first_chunk, first_chunk, content_type, resolved_output, debug}},
         %{pending: {:prepare, from}, cache_key: cache_key, config: config} = state
       ) do
    with_owner_check(state, fn state ->
      # Time-to-first-chunk is this session's generation cost: the cache's
      # admission/eviction policy scores an entry by it, and it completes the
      # producer's own stage timings as `:total`.
      cost_us = System.monotonic_time(:microsecond) - state.fetch_started_at
      debug = put_total_timing(debug, cost_us)

      cache_sink =
        Cache.open_sink(
          cache_key,
          resolved_output,
          config
          |> Keyword.put(:cost_us, cost_us)
          |> Keyword.put(:debug_info, debug)
        )

      cache_sink = Cache.write_chunk(cache_sink, first_chunk, config)

      GenServer.reply(
        from,
        {:ok,
         %{
           first_chunk: first_chunk,
           content_type: content_type,
           resolved_output: resolved_output,
           debug: debug
         }}
      )

      {:noreply,
       %{
         state
         | pending: nil,
           phase: :prepared,
           cache_sink: cache_sink,
           resolved_output: resolved_output,
           content_type: content_type
       }}
    end)
  end

  defp handle_producer_result({:ok, {:chunk, chunk}}, %{pending: {:next, from}} = state) do
    with_owner_check(state, fn state ->
      cache_sink = Cache.write_chunk(state.cache_sink, chunk, state.config)
      GenServer.reply(from, {:chunk, chunk})
      {:noreply, %{state | pending: nil, cache_sink: cache_sink}}
    end)
  end

  defp handle_producer_result({:ok, :done}, %{pending: {:next, from}} = state) do
    with_owner_check(state, fn state ->
      Cache.commit_sink(state.cache_sink, state.config)
      GenServer.reply(from, :done)

      state =
        state
        |> clear_producer()
        |> Map.merge(%{phase: :done, pending: nil, cache_sink: nil})

      {:stop, :normal, state}
    end)
  end

  defp handle_producer_result(:ok, %{pending: {:cancel, from}} = state) do
    state = state |> clear_producer() |> abort_cache_sink(state.cancel_reason || :cancelled)
    if from, do: GenServer.reply(from, :ok)
    {:stop, :normal, %{state | phase: :cancelled, pending: nil}}
  end

  defp handle_producer_result({:error, _reason}, %{pending: {:cancel, from}} = state) do
    state =
      state |> stop_producer(:shutdown) |> abort_cache_sink(state.cancel_reason || :cancelled)

    if from, do: GenServer.reply(from, :ok)
    {:stop, :normal, %{state | phase: :cancelled, pending: nil}}
  end

  defp handle_producer_result({:error, reason}, %{pending: {_kind, from}} = state) do
    state =
      state
      |> abort_cache_sink(:stream_error)
      |> clear_producer()

    GenServer.reply(from, {:error, reason})
    {:stop, :normal, mark_failed(%{state | pending: nil})}
  end

  defp with_owner_check(state, fun) when is_function(fun, 1) do
    case receive_owner_down_message(state) do
      {:owner_down, reason} ->
        state
        |> reply_pending({:error, {:session, {:owner_down, reason}}})
        |> halt_for_owner_down(reason)

      :none ->
        fun.(state)
    end
  end

  # Owner-down teardown, reached either from the monitor's :DOWN message or
  # from the pre-reply owner check: halt the producer gracefully, and only once
  # it is gone (or if it was already gone) abort the staged cache bytes.
  defp halt_for_owner_down(state, reason) do
    case request_producer_halt(%{state | pending: nil}, nil, :owner_down) do
      {:ok, state} ->
        {:noreply, %{state | phase: :cancelled}}

      {:stop, state} ->
        state = abort_cache_sink(state, :owner_down)
        {:stop, {:shutdown, {:owner_down, reason}}, %{state | phase: :cancelled}}
    end
  end

  defp receive_owner_down_message(%{owner: owner, owner_monitor: ref}) do
    receive do
      {:DOWN, ^ref, :process, ^owner, reason} -> {:owner_down, reason}
    after
      0 -> :none
    end
  end

  defp reply_pending(%{pending: nil} = state, _reply), do: state

  defp reply_pending(%{pending: {_kind, from}} = state, reply),
    do: reply_pending_from(from, reply, state)

  defp reply_pending_from(nil, _reply, state), do: %{state | pending: nil}

  defp reply_pending_from(from, reply, state) do
    GenServer.reply(from, reply)
    %{state | pending: nil}
  end

  defp request_producer_halt(%{producer: nil} = state, _from, _reason), do: {:stop, state}

  defp request_producer_halt(%{producer: producer} = state, from, reason) when is_pid(producer) do
    timeout = max(100, div(@cancel_timeout, 2))
    ref = Producer.request_halt(producer, self())
    Process.send_after(self(), {:producer_halt_timeout, ref}, timeout)
    {:ok, %{state | pending: {:cancel, from}, producer_request_ref: ref, cancel_reason: reason}}
  end

  defp stop_producer(%{producer: nil} = state, _reason), do: clear_producer(state)

  defp stop_producer(%{producer: producer} = state, reason) when is_pid(producer) do
    Process.exit(producer, reason)
    clear_producer(state)
  end

  defp clear_producer(%{producer_monitor: ref} = state) when is_reference(ref) do
    Process.demonitor(ref, [:flush])
    %{state | producer: nil, producer_monitor: nil, producer_request_ref: nil}
  end

  defp clear_producer(state) do
    %{state | producer: nil, producer_monitor: nil, producer_request_ref: nil}
  end

  defp abort_cache_sink(%{cache_sink: nil} = state, _reason), do: state

  defp abort_cache_sink(%{cache_sink: cache_sink, config: config} = state, reason) do
    Cache.abort_sink(cache_sink, reason, config)
    %{state | cache_sink: nil}
  end

  defp cleanup_shutdown(state, cache_reason) do
    state
    |> stop_producer(:shutdown)
    |> abort_cache_sink(cache_reason)
  end

  defp producer_down_reason(reason), do: {:session, {:producer_down, reason}}

  defp mark_failed(state), do: %{state | phase: :failed}

  defp put_total_timing(nil, _cost_us), do: nil

  defp put_total_timing(%Info{} = info, cost_us),
    do: %{info | timings: Map.put(info.timings, :total, cost_us)}
end
