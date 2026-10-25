defmodule ImagePipe.Delivery.Coordinator do
  @moduledoc false

  # Monitor-based session coordinator for a streaming delivery. It drives the
  # `build_fun` from `ImagePipe.Processing.build_fun/5`, which decodes,
  # transforms and encodes, without depending on those steps.
  #
  # Monitor DIRECTION (the flagged invariant): a `spawn_monitor` from an owner
  # only watches the CHILD — owner-death detection requires the CHILD to
  # monitor the owner back. This coordinator does `Process.monitor(owner)` in
  # `init/1`, so an owner (conn process) dying mid-stream is observed here via
  # a `:DOWN` message, not the other way around.
  #
  # Pooled producers halt cooperatively and keep their slot through bracket
  # cleanup. Unpooled producers retain the force-kill backstop.
  #
  # After the first chunk, the coordinator pulls chunks at encode speed, not
  # at the client's: each goes to the cache sink and into a buffer the client
  # drains with `next/2`. So the producer returns, ending its pool turn, and
  # the entry is committed, releasing the requests waiting for it, when the
  # encode ends rather than when a slow client has read the last byte. Up to
  # `@window` unsent bytes stay in memory. Past that, chunks are appended to a
  # spool file at the session's `:spool_path`, deleted as soon as it's open,
  # so the VM closes it and frees its space however this process stops.
  # Without a spool path, or once a spool write fails, the coordinator stops
  # pulling at `@window` and resumes as the client drains the buffer. It does
  # the same when the VM holds as much for slow clients as `Budget` allows.
  # The session counts what it holds in `Budget` and gives it back in
  # `terminate/2`, which every stop runs.

  use GenServer

  alias ImagePipe.Cache
  alias ImagePipe.Debug.Info
  alias ImagePipe.Delivery.Budget
  alias ImagePipe.Delivery.Producer
  alias ImagePipe.ProcessingPool
  alias ImagePipe.Telemetry.RequestContext

  @call_timeout 60_000
  @cancel_timeout 2_000
  @window 4 * 1024 * 1024
  @spool_read 256 * 1024

  defstruct [
    :build_fun,
    :owner,
    :owner_monitor,
    :cache_key,
    # This request's output lease (see Delivery.stream/4).
    :output_lease,
    :request_context,
    :config,
    :producer,
    :producer_monitor,
    :producer_request_ref,
    :pending,
    :cancel_reason,
    :cache_sink,
    :fetch_started_at,
    :failure,
    # A path to open the spool at, `{fd, size}` once open, `{:read_only, fd,
    # size}` after a write to it fails, or `:failed` when it can't be opened.
    :spool,
    phase: :new,
    # Unsent chunks in order: `{:memory, binary}` or `{:spool, offset, size}`.
    buffer: :queue.new(),
    buffered: 0,
    encoded?: false
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
          keyword(),
          RequestContext.t(),
          keyword()
        ) ::
          GenServer.on_start()
  def start(build_fun, owner, cache_key, session, request_context, config)
      when is_function(build_fun, 1) and is_pid(owner) do
    GenServer.start(__MODULE__, {build_fun, owner, cache_key, session, request_context, config})
  end

  @doc "Longest wait for the next chunk before the session gives up."
  @spec progress_timeout() :: timeout()
  def progress_timeout, do: @call_timeout

  @spec prepare(server(), timeout()) :: {:ok, map()} | {:error, term()}
  def prepare(server, timeout \\ @call_timeout), do: call_session(server, :prepare, timeout)

  @spec next(server(), timeout()) :: {:chunk, binary()} | :done | {:error, term()}
  def next(server, timeout \\ @call_timeout), do: call_session(server, :next, timeout)

  @spec cancel(server(), timeout()) :: :ok | {:error, term()}
  def cancel(server, timeout \\ @cancel_timeout), do: call_session(server, :cancel, timeout)

  @impl GenServer
  def init({build_fun, owner, cache_key, session, request_context, config}) when is_pid(owner) do
    Process.flag(:trap_exit, true)
    Process.put(:"$callers", [owner | Process.get(:"$callers", [])])
    # Hop A: adopt the request's context so spans emitted from THIS process
    # (e.g. [:cache, :write] at commit) nest under the request root and keep
    # the host's Logger metadata.
    RequestContext.adopt(request_context)
    output_lease = Keyword.get(session, :output_lease)
    Cache.OutputWork.transfer(output_lease)

    {:ok,
     %__MODULE__{
       build_fun: build_fun,
       owner: owner,
       # THE flagged monitor direction: the coordinator watches the owner, not
       # the other way around.
       owner_monitor: Process.monitor(owner),
       cache_key: cache_key,
       output_lease: output_lease,
       request_context: request_context,
       config: config,
       spool: Keyword.get(session, :spool_path)
     }}
  end

  @impl GenServer
  def handle_call(:prepare, from, %{phase: :new} = state) do
    fetch_started_at = System.monotonic_time(:microsecond)
    coordinator = self()
    pool = Keyword.get(state.config, :processing_pool)

    build = fn pump ->
      ProcessingPool.within(pool, coordinator, state.config, fn -> state.build_fun.(pump) end)
    end

    {:ok, producer} = Producer.start_link(build, state.request_context)
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

  def handle_call(:next, from, %{phase: phase, pending: nil} = state)
      when phase in [:prepared, :streaming] do
    state = %{state | phase: :streaming}

    case take(state) do
      {:ok, chunk, state} -> {:reply, {:chunk, chunk}, pull(state)}
      {:error, reason} -> spool_failed(state, reason)
      :empty when state.encoded? -> {:stop, :normal, :done, %{state | phase: :done}}
      :empty -> {:noreply, pull(%{state | pending: {:next, from}})}
    end
  end

  def handle_call(:next, _from, %{phase: :failed, failure: failure} = state) do
    {:stop, :normal, {:error, failure}, state}
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
    pending = state.pending
    failure = producer_down_reason(reason)

    state =
      state
      |> reply_pending({:error, failure})
      |> abort_cache_sink(:stream_error)
      |> clear_producer()

    state = mark_failed(%{state | pending: nil, failure: failure})
    Cache.OutputWork.complete(state.output_lease, :bypass)

    case pending do
      nil -> {:noreply, state}
      _pending_call -> {:stop, :normal, state}
    end
  end

  def handle_info({ref, result}, %{producer_request_ref: ref} = state) when is_reference(ref) do
    handle_producer_result(result, %{state | producer_request_ref: nil})
  end

  def handle_info({:processing_timeout, producer}, %{producer: producer} = state) do
    pending = state.pending
    Producer.request_halt(producer, self())

    state =
      state
      |> reply_pending({:error, {:processing, :timeout}})
      |> abort_cache_sink(:stream_error)
      |> clear_producer()

    Cache.OutputWork.complete(state.output_lease, :bypass)
    state = mark_failed(%{state | failure: {:processing, :timeout}})

    case pending do
      nil -> {:noreply, state}
      _pending -> {:stop, :normal, state}
    end
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
  def terminate(reason, state) do
    give_back(state)
    stop(reason, state)
  end

  defp stop(:normal, _state), do: :ok

  defp stop(reason, state) when reason in [:shutdown] do
    cleanup_shutdown(state, :cancelled)
    :ok
  end

  defp stop({:shutdown, {:owner_down, _reason}}, state) do
    cleanup_shutdown(state, :owner_down)
    :ok
  end

  defp stop({:shutdown, _reason}, state) do
    cleanup_shutdown(state, :cancelled)
    :ok
  end

  defp stop(_reason, state) do
    cleanup_shutdown(state, :stream_error)
    :ok
  end

  # The configuration holds origin credentials, such as S3 keys and
  # authorization headers, which a crash report would print.
  @impl GenServer
  def format_status(%{state: state} = status), do: %{status | state: %{state | config: :redacted}}

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
      # Time-to-first-chunk completes the producer's stage timings as
      # `:total`.
      now = System.monotonic_time(:microsecond)
      debug = put_total_timing(debug, now - state.fetch_started_at)

      cache_sink =
        Cache.open_sink(
          cache_key,
          resolved_output,
          [
            cost_us: cost(debug, resolved_output),
            debug: debug
          ],
          config
        )

      cache_sink = Cache.write_chunk(cache_sink, first_chunk, config)
      release_unstored(cache_sink, state)

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
       pull(%{
         state
         | pending: nil,
           phase: :prepared,
           cache_sink: cache_sink
       })}
    end)
  end

  defp handle_producer_result({:ok, {:chunk, chunk}}, state) do
    with_owner_check(state, fn state ->
      cache_sink = Cache.write_chunk(state.cache_sink, chunk, state.config)
      if state.cache_sink, do: release_unstored(cache_sink, state)
      state = %{state | cache_sink: cache_sink}

      case state.pending do
        {:next, from} ->
          GenServer.reply(from, {:chunk, chunk})
          {:noreply, pull(%{state | pending: nil})}

        nil ->
          {:noreply, state |> put(chunk) |> pull()}
      end
    end)
  end

  defp handle_producer_result({:ok, :done}, state) do
    with_owner_check(state, fn state ->
      Cache.commit_sink(state.cache_sink, state.config, state.output_lease)
      state = %{clear_producer(state) | cache_sink: nil, encoded?: true}

      case state.pending do
        {:next, from} ->
          GenServer.reply(from, :done)
          {:stop, :normal, %{state | phase: :done, pending: nil}}

        nil ->
          {:noreply, state}
      end
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
    Cache.OutputWork.complete(state.output_lease, :bypass)
    {:stop, :normal, mark_failed(%{state | pending: nil})}
  end

  # An encode failure with no client call waiting reaches the client's next
  # call, in place of the chunks still buffered.
  defp handle_producer_result({:error, reason}, %{pending: nil} = state) do
    state = state |> abort_cache_sink(:stream_error) |> clear_producer()
    Cache.OutputWork.complete(state.output_lease, :bypass)
    {:noreply, mark_failed(%{state | failure: reason})}
  end

  # Asks the producer for the next chunk unless it's already asked, the encode
  # has ended, or the buffer is full.
  defp pull(%{producer: producer, producer_request_ref: nil, phase: phase} = state)
       when is_pid(producer) and phase in [:prepared, :streaming] do
    if match?({:next, _from}, state.pending) or room?(state) do
      %{state | producer_request_ref: Producer.request_next(producer, self())}
    else
      state
    end
  end

  defp pull(state), do: state

  defp room?(state), do: memory_room?(state) or spool_room?(state)

  defp memory_room?(state), do: state.buffered < @window and Budget.room?(:memory)
  defp spool_room?(state), do: spool?(state) and Budget.room?(:spool)

  defp spool?(%{spool: path}) when is_binary(path), do: true
  defp spool?(%{spool: {_fd, size}}) when is_integer(size), do: true
  defp spool?(_state), do: false

  defp put(state, chunk) do
    cond do
      state.buffered + byte_size(chunk) <= @window and Budget.room?(:memory) ->
        put_memory(state, chunk)

      spool_room?(state) ->
        put_spool(state, chunk)

      true ->
        put_memory(state, chunk)
    end
  end

  defp put_memory(state, chunk) do
    Budget.add(:memory, byte_size(chunk))

    %{
      state
      | buffer: :queue.in({:memory, chunk}, state.buffer),
        buffered: state.buffered + byte_size(chunk)
    }
  end

  defp put_spool(%{spool: path} = state, chunk) when is_binary(path) do
    case :file.open(path, [:raw, :binary, :read, :write, :exclusive]) do
      {:ok, fd} ->
        _deleted = :file.delete(path, [:raw])
        put_spool(%{state | spool: {fd, 0}}, chunk)

      {:error, _reason} ->
        put_memory(%{state | spool: :failed}, chunk)
    end
  end

  defp put_spool(%{spool: {fd, size}} = state, chunk) do
    case :file.pwrite(fd, size, chunk) do
      :ok ->
        Budget.add(:spool, byte_size(chunk))
        item = {:spool, size, byte_size(chunk)}
        %{state | buffer: :queue.in(item, state.buffer), spool: {fd, size + byte_size(chunk)}}

      {:error, _reason} ->
        put_memory(%{state | spool: {:read_only, fd, size}}, chunk)
    end
  end

  defp take(state) do
    case :queue.out(state.buffer) do
      {{:value, {:memory, chunk}}, buffer} ->
        Budget.add(:memory, -byte_size(chunk))
        {:ok, chunk, %{state | buffer: buffer, buffered: state.buffered - byte_size(chunk)}}

      {{:value, {:spool, offset, size}}, buffer} ->
        read_spool(state, buffer, offset, size)

      {:empty, _buffer} ->
        :empty
    end
  end

  defp read_spool(state, buffer, offset, size) do
    length = min(size, @spool_read)
    fd = spool_fd(state.spool)

    case :file.pread(fd, offset, length) do
      {:ok, chunk} when byte_size(chunk) == length ->
        buffer =
          if length < size,
            do: :queue.in_r({:spool, offset + length, size - length}, buffer),
            else: buffer

        {:ok, chunk, %{state | buffer: buffer}}

      {:ok, _short} ->
        {:error, :truncated}

      {:error, reason} ->
        {:error, reason}

      :eof ->
        {:error, :truncated}
    end
  end

  # A spool that can't be read back ends the response. An encode still
  # running stops, and its partial entry is dropped.
  defp spool_failed(state, reason) do
    state = cleanup_shutdown(state, :stream_error)
    Cache.OutputWork.complete(state.output_lease, :bypass)
    {:stop, :normal, {:error, {:session, {:spool, reason}}}, mark_failed(state)}
  end

  defp spool_fd({:read_only, fd, _size}), do: fd
  defp spool_fd({fd, _size}), do: fd

  # Gives back what the session holds: its buffered chunks, and its spool
  # file, whose space returns only when the file closes as this process ends.
  defp give_back(state) do
    Budget.add(:memory, -state.buffered)
    Budget.add(:spool, -spooled(state.spool))
  end

  defp spooled({:read_only, _fd, size}), do: size
  defp spooled({_fd, size}) when is_integer(size), do: size
  defp spooled(_path_or_failed), do: 0

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
    ref = Producer.request_halt(producer, self())

    case Keyword.get(state.config, :processing_pool) do
      nil ->
        timeout = max(100, div(@cancel_timeout, 2))
        Process.send_after(self(), {:producer_halt_timeout, ref}, timeout)

        {:ok,
         %{state | pending: {:cancel, from}, producer_request_ref: ref, cancel_reason: reason}}

      pool ->
        ProcessingPool.cancel(pool, producer)
        Cache.OutputWork.complete(state.output_lease, :bypass)
        {:stop, state |> abort_cache_sink(reason) |> clear_producer()}
    end
  end

  defp stop_producer(%{producer: nil} = state, _reason), do: clear_producer(state)

  defp stop_producer(%{producer: producer} = state, reason) when is_pid(producer) do
    case Keyword.get(state.config, :processing_pool) do
      nil ->
        Process.exit(producer, reason)

      pool ->
        Producer.request_halt(producer, self())
        ProcessingPool.cancel(pool, producer)
    end

    clear_producer(state)
  end

  defp clear_producer(%{producer_monitor: ref} = state) when is_reference(ref) do
    Process.demonitor(ref, [:flush])
    %{state | producer: nil, producer_monitor: nil, producer_request_ref: nil}
  end

  defp clear_producer(state) do
    %{state | producer: nil, producer_monitor: nil, producer_request_ref: nil}
  end

  # Requests waiting for this output would find nothing in the cache, so they
  # start their own generation now instead of after this stream ends.
  defp release_unstored(nil, state), do: Cache.OutputWork.complete(state.output_lease, :bypass)
  defp release_unstored(_cache_sink, _state), do: :ok

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

  defp producer_down_reason({:shutdown, {:processing, _} = reason}), do: reason
  defp producer_down_reason(reason), do: {:session, {:producer_down, reason}}

  defp mark_failed(state) do
    Budget.add(:memory, -state.buffered)
    %{state | phase: :failed, buffer: :queue.new(), buffered: 0}
  end

  # A source delivered unchanged has no debug info and isn't stored.
  defp cost(nil, _skipped), do: 0
  defp cost(%Info{} = debug, resolved_output), do: Cache.Cost.render(debug, resolved_output)

  defp put_total_timing(nil, _total_us), do: nil

  defp put_total_timing(%Info{} = info, total_us),
    do: %{info | timings: Map.put(info.timings, :total, total_us)}
end
