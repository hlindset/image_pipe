defmodule ImagePipe.Request.SourceSession do
  @moduledoc false

  use GenServer

  alias ImagePipe.Cache
  alias ImagePipe.Request.SourceSession.Prepared
  alias ImagePipe.Request.SourceSession.Producer
  alias ImagePipe.Request.SourceSession.Request
  alias ImagePipe.Source.StreamError
  alias ImagePipe.Telemetry.Trace

  # Backstop for a wedged producer, not an input-safety bound (real liveness is
  # bounded by origin_receive_timeout and the decoded-pixel limit). `prepare`/`next`
  # block on the producer, which for non-streamable codecs (AVIF, WebP) means a full
  # synchronous encode. Under oversubscribed CI cores, libvips/NIF encode work on
  # dirty schedulers can take many seconds wall-clock, so keep this comfortably above
  # a realistic worst-case encode to avoid spurious :timeout failures.
  @call_timeout 30_000
  @cancel_timeout 2_000
  @shutdown_timeout 2_000

  defstruct [
    :request,
    :owner,
    :owner_monitor,
    :parent,
    :trace_context,
    :producer,
    :producer_monitor,
    :producer_request_ref,
    :pending,
    :resolved_output,
    :cache_sink,
    :fetch_started_at,
    phase: :new
  ]

  @type server() :: GenServer.server()

  @spec start_link(Request.t(), keyword()) :: GenServer.on_start()
  def start_link(%Request{} = request, opts \\ []) do
    owner = Keyword.get(opts, :owner, self())
    trace_context = Keyword.get(opts, :trace_context)

    GenServer.start_link(__MODULE__, {request, owner, self(), trace_context})
  end

  @spec child_spec({Request.t(), keyword()}) :: Supervisor.child_spec()
  def child_spec({%Request{} = request, opts}) do
    %{
      id: __MODULE__,
      start: {__MODULE__, :start_link, [request, opts]},
      restart: :temporary,
      shutdown: @shutdown_timeout,
      type: :worker,
      modules: [__MODULE__]
    }
  end

  @spec prepare(server(), timeout()) :: {:ok, Prepared.t()} | {:error, term()}
  def prepare(server, timeout \\ @call_timeout), do: call_session(server, :prepare, timeout)

  @spec next(server(), timeout()) :: {:chunk, binary()} | :done | {:error, term()}
  def next(server, timeout \\ @call_timeout), do: call_session(server, :next, timeout)

  @spec cancel(server(), timeout()) :: :ok | {:error, term()}
  def cancel(server, timeout \\ @cancel_timeout), do: call_session(server, :cancel, timeout)

  @impl GenServer
  def init({%Request{} = request, owner, parent, trace_context}) when is_pid(owner) do
    Process.flag(:trap_exit, true)
    # Preserve request ownership for Tasks spawned by downstream image/source code.
    Process.put(:"$callers", [owner | Process.get(:"$callers", [])])
    # Hop A: adopt the request's trace context so spans emitted from THIS process
    # (e.g. [:cache, :write] during commit) nest under the request root.
    Trace.Stack.adopt(trace_context)

    {:ok,
     %__MODULE__{
       request: request,
       owner: owner,
       owner_monitor: Process.monitor(owner),
       parent: parent,
       trace_context: trace_context
     }}
  end

  @impl GenServer
  def handle_call(:prepare, from, %{phase: :new} = state) do
    state = start_producer(state)
    ref = Producer.request_next(state.producer, self())

    {:noreply, %{state | phase: :preparing, pending: {:prepare, from}, producer_request_ref: ref}}
  end

  def handle_call(:prepare, _from, state) do
    {:reply, {:error, {:protocol, {:invalid_phase, state.phase}}}, state}
  end

  def handle_call(:next, from, %{phase: phase, producer: producer, pending: nil} = state)
      when phase in [:prepared, :streaming] and is_pid(producer) do
    ref = Producer.request_next(producer, self())
    {:noreply, %{state | phase: :streaming, pending: {:next, from}, producer_request_ref: ref}}
  end

  def handle_call(:next, _from, state) do
    {:reply, {:error, {:protocol, :not_prepared}}, state}
  end

  def handle_call(:cancel, from, %{pending: nil} = state) do
    case request_producer_halt(state, from) do
      {:ok, state} ->
        {:noreply, %{state | phase: :cancelled}}

      {:stop, state} ->
        state = abort_cache_sink(state, :cancelled)
        {:stop, :normal, :ok, %{state | phase: :cancelled}}
    end
  end

  def handle_call(:cancel, _from, %{pending: {_kind, _pending_from}} = state) do
    state =
      state
      |> reply_pending({:error, {:session, :cancelled}})
      |> stop_producer(:shutdown)
      |> abort_cache_sink(:cancelled)

    {:stop, :normal, :ok, %{state | phase: :cancelled, pending: nil}}
  end

  @impl GenServer
  def handle_info(
        {:DOWN, ref, :process, owner, reason},
        %{owner: owner, owner_monitor: ref} = state
      ) do
    state =
      state
      |> reply_pending({:error, {:session, {:shutdown, {:owner_down, reason}}}})
      |> stop_producer(:shutdown)
      |> abort_cache_sink(:owner_down)

    {:stop, {:shutdown, {:owner_down, reason}}, %{state | phase: :cancelled, pending: nil}}
  end

  def handle_info(
        {:DOWN, ref, :process, producer, reason},
        %{producer: producer, producer_monitor: ref, pending: {:cancel, from}} = state
      )
      when reason in [:normal, :shutdown] do
    state =
      state
      |> clear_producer()
      |> abort_cache_sink(:cancelled)

    GenServer.reply(from, :ok)
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

  def handle_info({:EXIT, parent, reason}, %{parent: parent} = state) do
    state =
      state
      |> reply_pending({:error, {:session, {:shutdown, reason}}})
      |> stop_producer(:shutdown)
      |> abort_cache_sink(:cancelled)

    {:stop, reason, %{state | phase: :cancelled, pending: nil}}
  end

  def handle_info({ref, result}, %{producer_request_ref: ref} = state) when is_reference(ref) do
    handle_producer_result(result, %{state | producer_request_ref: nil})
  end

  def handle_info({:producer_halt_timeout, ref}, %{producer_request_ref: ref} = state) do
    state =
      state
      |> stop_producer(:shutdown)
      |> abort_cache_sink(:cancelled)
      |> reply_pending(:ok)

    {:stop, :normal, %{state | phase: :cancelled, pending: nil}}
  end

  # Linked producer exits are intentionally ignored. The monitor :DOWN is the
  # authoritative producer-death signal; delayed exits after stop_producer/2 are
  # harmless once producer fields have been cleared.
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

  def terminate({:shutdown, reason}, state) do
    cleanup_shutdown(state, cache_shutdown_reason(reason))
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

  defp start_producer(%{request: %Request{} = request} = state) do
    caller_chain = Process.get(:"$callers", [])
    fetch_started_at = System.monotonic_time(:microsecond)

    {:ok, producer} =
      Producer.start_link(request,
        caller_chain: caller_chain,
        trace_context: state.trace_context
      )

    ref = Process.monitor(producer)
    %{state | producer: producer, producer_monitor: ref, fetch_started_at: fetch_started_at}
  end

  defp handle_producer_result(
         {:ok, {:first_chunk, first_chunk, content_type, headers, resolved_output, debug}},
         %{pending: {:prepare, from}, request: request} = state
       ) do
    with_owner_check(state, fn state ->
      cost_us = System.monotonic_time(:microsecond) - state.fetch_started_at

      cache_sink =
        Cache.open_sink(
          request.cache_key,
          resolved_output,
          Keyword.put(request.opts, :cost_us, cost_us)
        )

      cache_sink = Cache.write_chunk(cache_sink, first_chunk, request.opts)

      prepared = %Prepared{
        first_chunk: first_chunk,
        content_type: content_type,
        headers: headers,
        resolved_output: resolved_output,
        debug: put_total_timing(debug, cost_us)
      }

      GenServer.reply(from, {:ok, prepared})

      {:noreply,
       %{
         state
         | pending: nil,
           phase: :prepared,
           cache_sink: cache_sink,
           resolved_output: resolved_output
       }}
    end)
  end

  defp handle_producer_result({:ok, {:chunk, chunk}}, %{pending: {:next, from}} = state) do
    with_owner_check(state, fn state ->
      cache_sink = Cache.write_chunk(state.cache_sink, chunk, state.request.opts)
      GenServer.reply(from, {:chunk, chunk})
      {:noreply, %{state | pending: nil, cache_sink: cache_sink}}
    end)
  end

  defp handle_producer_result({:ok, :done}, %{pending: {:next, from}} = state) do
    with_owner_check(state, fn state ->
      Cache.commit_sink(state.cache_sink, state.request.opts)
      GenServer.reply(from, :done)

      state =
        state
        |> clear_producer()
        |> Map.merge(%{phase: :done, pending: nil, cache_sink: nil})

      {:stop, :normal, state}
    end)
  end

  defp handle_producer_result(:ok, %{pending: {:cancel, from}} = state) do
    state =
      state
      |> clear_producer()
      |> abort_cache_sink(:cancelled)

    GenServer.reply(from, :ok)
    {:stop, :normal, %{state | phase: :cancelled, pending: nil}}
  end

  defp handle_producer_result({:error, _reason}, %{pending: {:cancel, from}} = state) do
    state =
      state
      |> stop_producer(:shutdown)
      |> abort_cache_sink(:cancelled)

    GenServer.reply(from, :ok)
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
        state =
          state
          |> reply_pending({:error, {:session, {:shutdown, {:owner_down, reason}}}})
          |> stop_producer(:shutdown)
          |> abort_cache_sink(:owner_down)

        {:stop, {:shutdown, {:owner_down, reason}}, %{state | phase: :cancelled, pending: nil}}

      :none ->
        fun.(state)
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

  defp reply_pending(%{pending: {_kind, from}} = state, reply) do
    GenServer.reply(from, reply)
    %{state | pending: nil}
  end

  defp request_producer_halt(%{producer: nil} = state, _from), do: {:stop, state}

  defp request_producer_halt(%{producer: producer} = state, from) when is_pid(producer) do
    timeout = max(100, div(@cancel_timeout, 2))
    ref = Producer.request_halt(producer, self())
    Process.send_after(self(), {:producer_halt_timeout, ref}, timeout)
    {:ok, %{state | pending: {:cancel, from}, producer_request_ref: ref}}
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

  defp abort_cache_sink(%{cache_sink: cache_sink, request: request} = state, reason) do
    Cache.abort_sink(cache_sink, reason, request.opts)
    %{state | cache_sink: nil}
  end

  defp cleanup_shutdown(state, cache_reason) do
    state
    |> stop_producer(:shutdown)
    |> abort_cache_sink(cache_reason)
  end

  defp producer_down_reason({%StreamError{reason: reason}, _stacktrace}), do: {:source, reason}
  defp producer_down_reason(%StreamError{reason: reason}), do: {:source, reason}

  defp producer_down_reason(:normal), do: {:session, {:producer_down, :normal}}
  defp producer_down_reason(reason), do: {:session, {:producer_down, reason}}

  defp cache_shutdown_reason({:owner_down, _reason}), do: :owner_down
  defp cache_shutdown_reason(:owner_down), do: :owner_down
  defp cache_shutdown_reason(_reason), do: :cancelled

  defp mark_failed(state), do: %{state | phase: :failed}

  defp put_total_timing(nil, _cost_us), do: nil

  defp put_total_timing(%ImagePipe.Debug.Info{} = info, cost_us) do
    %{info | timings: Map.put(info.timings, :total, cost_us)}
  end
end
