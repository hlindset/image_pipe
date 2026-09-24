defmodule ImagePipe.Telemetry.Trace.OtelReplay do
  @moduledoc false

  # Buffers finished `%ImagePipe.Telemetry.Trace.Span{}`s per trace and replays
  # each trace into a host-running OpenTelemetry SDK top-down once its root span
  # arrives, so every child is parented onto its parent's OTel-minted span
  # context.
  #
  # `OpenTelemetryExporter` is the only producer; it casts finished spans here.
  # Fail-open: if this server is down, the cast silently drops — best-effort
  # telemetry. Replay runs inside this server: serialized buffer access makes
  # cross-process span arrival race-free (replay is order-independent, so the
  # per-sender-FIFO-only guarantee of casts suffices), and the OTel calls are
  # in-memory handoffs to the SDK's processor (the SDK batches the real I/O).
  #
  # ImagePipe's trace_id is forced onto the trace via a synthetic W3C
  # traceparent remote parent on the root span only; children inherit it
  # through their parent contexts. Upstream consequence (new_span_ctx/2 copies
  # the parent ctx wholesale): every replayed span carries is_remote=true
  # inherited from the root's remote-extracted parent — benign (parent linkage
  # and sampling stay correct), just visible in exported records.
  #
  # Degradations (all best-effort by design):
  #   * a trace whose root never arrives is flushed flat by the periodic sweep
  #     after :ttl_ms — parentage resolves within the swept set, dangles above
  #     it; nothing is silently dropped;
  #   * a late span arriving after its trace flushed parents correctly while
  #     the trace's ctx map is retained (:ttl_ms window); a late child arriving
  #     BEFORE its late parent falls back to a dangling synthetic parent;
  #   * flat-swept traces keep no ctx map — later spans re-buffer and are
  #     eventually flat-swept too;
  #   * above :max_traces live traces, spans for NEW traces are shed (bounded
  #     memory beats complete telemetry);
  #   * a crash restarts the server empty: buffered traces are lost, replayed
  #     spans are already safe in the SDK. No flush runs at shutdown either.

  use GenServer

  alias ImagePipe.Telemetry.Trace.Span

  # All OTel references are runtime-only and only reachable via the guarded
  # exporter; suppress undefined-module warnings when the optional API is absent.
  @compile {:no_warn_undefined,
            [
              OpenTelemetry,
              OpenTelemetry.Span,
              :opentelemetry,
              :otel_tracer,
              :otel_ctx,
              :otel_propagator_text_map,
              :otel_propagator_trace_context
            ]}

  @options_schema NimbleOptions.new!(
                    name: [
                      type:
                        {:or,
                         [
                           :atom,
                           {:tuple, [{:in, [:global]}, :any]},
                           {:tuple, [{:in, [:via]}, :atom, :any]}
                         ]},
                      default: __MODULE__
                    ],
                    ttl_ms: [type: :non_neg_integer, default: 10_000],
                    sweep_interval_ms: [type: :pos_integer, default: 5_000],
                    max_traces: [type: :non_neg_integer, default: 10_000]
                  )

  # ---- client ----------------------------------------------------------------

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    case NimbleOptions.validate(opts, @options_schema) do
      {:ok, opts} ->
        {name, opts} = Keyword.pop!(opts, :name)
        GenServer.start_link(__MODULE__, Map.new(opts), name: name)

      {:error, error} ->
        raise ArgumentError, Exception.message(error)
    end
  end

  @doc "Hand a finished span to the replay buffer. Fire-and-forget."
  @spec add(GenServer.server(), Span.t()) :: :ok
  def add(server \\ __MODULE__, %Span{} = span), do: GenServer.cast(server, {:add, span})

  @doc "Synchronously run one TTL sweep (test support)."
  @spec sweep(GenServer.server()) :: :ok
  def sweep(server \\ __MODULE__), do: GenServer.call(server, :sweep)

  @doc "Drop all buffered state (test support)."
  @spec reset(GenServer.server()) :: :ok
  def reset(server \\ __MODULE__), do: GenServer.call(server, :reset)

  # ---- server ----------------------------------------------------------------

  @impl true
  def init(config) do
    state = Map.put(config, :traces, %{})
    schedule_sweep(state)
    {:ok, state}
  end

  @impl true
  def handle_cast({:add, span}, state), do: {:noreply, add_span(span, state)}

  @impl true
  def handle_call(:sweep, _from, state), do: {:reply, :ok, do_sweep(state)}
  def handle_call(:reset, _from, state), do: {:reply, :ok, %{state | traces: %{}}}

  @impl true
  def handle_info(:sweep, state) do
    # Reschedule before sweeping — drift-free cadence regardless of sweep cost.
    schedule_sweep(state)
    {:noreply, do_sweep(state)}
  end

  defp schedule_sweep(state), do: Process.send_after(self(), :sweep, state.sweep_interval_ms)

  # ---- buffering state machine -------------------------------------------------
  #
  # Per-trace entry:
  #   {:buffering, [span], deadline} — children awaiting their root
  #   {:flushed, ctx_map, deadline}  — root replayed; internal span_id (hex) →
  #                                    OTel span_ctx, for late arrivals

  defp add_span(%Span{} = span, state) do
    entry = Map.get(state.traces, span.trace_id)

    cond do
      span.root ->
        flush_root(span, entry, state)

      match?({:flushed, _, _}, entry) ->
        {:flushed, ctx_map, _deadline} = entry
        {_ctx, ctx_map} = replay_one(span, ctx_map)
        put_entry(state, span.trace_id, {:flushed, ctx_map, deadline(state)})

      match?({:buffering, _, _}, entry) ->
        {:buffering, list, _deadline} = entry
        put_entry(state, span.trace_id, {:buffering, [span | list], deadline(state)})

      map_size(state.traces) < state.max_traces ->
        put_entry(state, span.trace_id, {:buffering, [span], deadline(state)})

      true ->
        # Load shedding: bounded memory beats complete telemetry.
        state
    end
  rescue
    # A tracer must never crash (same contract as Capture/FinchCapture); the
    # OTel SDK is a third-party boundary. Drop the trace's entry so a partially
    # replayed tree is never re-swept into duplicate exports.
    _ -> %{state | traces: Map.delete(state.traces, span.trace_id)}
  end

  defp flush_root(span, entry, state) do
    {buffered, existing?} =
      case entry do
        {:buffering, spans, _deadline} -> {spans, true}
        {:flushed, _ctx_map, _deadline} -> {[], true}
        nil -> {[], false}
      end

    ctx_map = replay_tree(span, buffered)

    if existing? or map_size(state.traces) < state.max_traces do
      put_entry(state, span.trace_id, {:flushed, ctx_map, deadline(state)})
    else
      # At capacity: the root replayed, but no ctx map is retained — late
      # arrivals for this trace degrade to dangling parents.
      state
    end
  end

  defp put_entry(state, trace_id, entry),
    do: %{state | traces: Map.put(state.traces, trace_id, entry)}

  defp deadline(state), do: System.monotonic_time(:millisecond) + state.ttl_ms

  defp do_sweep(state) do
    now = System.monotonic_time(:millisecond)

    {expired, live} =
      Enum.split_with(state.traces, fn {_trace_id, entry} -> deadline_of(entry) <= now end)

    Enum.each(expired, fn
      {_trace_id, {:buffering, spans, _deadline}} -> flat_flush(spans)
      {_trace_id, {:flushed, _ctx_map, _deadline}} -> :ok
    end)

    %{state | traces: Map.new(live)}
  end

  defp deadline_of({:buffering, _spans, deadline}), do: deadline
  defp deadline_of({:flushed, _ctx_map, deadline}), do: deadline

  # Root never arrived: degraded flat replay. Runs outside add_span's rescue,
  # so it carries its own — a sweep replay failure drops the expired spans
  # rather than killing the buffer server.
  defp flat_flush(spans) do
    _ = replay_forest(spans, %{})
    :ok
  rescue
    _ -> :ok
  end

  # ---- replay ------------------------------------------------------------------

  defp replay_tree(root, buffered) do
    {_root_ctx, ctx_map} = replay_one(root, %{})

    by_parent = Enum.group_by(buffered, & &1.parent_span_id)
    ctx_map = replay_children(root.span_id, by_parent, ctx_map)

    # Spans not reachable from the root (broken parent chain): replay them as a
    # forest so intra-set parent links still resolve — never silently lost.
    buffered
    |> Enum.reject(&Map.has_key?(ctx_map, &1.span_id))
    |> replay_forest(ctx_map)
  end

  # Replays an arbitrary set of spans, resolving parentage within the set:
  # spans whose parent is not in the set start a subtree (their parent comes
  # from ctx_map or the synthetic-traceparent fallback).
  defp replay_forest(spans, ctx_map) do
    ids = MapSet.new(spans, & &1.span_id)
    by_parent = Enum.group_by(spans, & &1.parent_span_id)

    spans
    |> Enum.reject(&MapSet.member?(ids, &1.parent_span_id))
    |> Enum.sort_by(& &1.start_time)
    |> Enum.reduce(ctx_map, fn span, acc ->
      {_ctx, acc} = replay_one(span, acc)
      replay_children(span.span_id, by_parent, acc)
    end)
  end

  defp replay_children(parent_id, by_parent, ctx_map) do
    by_parent
    |> Map.get(parent_id, [])
    |> Enum.sort_by(& &1.start_time)
    |> Enum.reduce(ctx_map, fn child, acc ->
      {_ctx, acc} = replay_one(child, acc)
      replay_children(child.span_id, by_parent, acc)
    end)
  end

  # Replays one span; returns its OTel span_ctx and the ctx_map including it.
  # A failure skips THIS span only (its children fall back to dangling parents)
  # and never aborts the surrounding tree replay — same never-crash contract as
  # add_span, localized so one bad span can't take out its siblings.
  defp replay_one(%Span{} = span, ctx_map) do
    parent_otel_ctx =
      case Map.get(ctx_map, span.parent_span_id) do
        nil -> traceparent_ctx(span)
        parent_span_ctx -> :otel_tracer.set_current_span(:otel_ctx.new(), parent_span_ctx)
      end

    span_ctx = replay_span(span, parent_otel_ctx)
    {span_ctx, Map.put(ctx_map, span.span_id, span_ctx)}
  rescue
    _ -> {nil, ctx_map}
  end

  defp replay_span(%Span{} = span, parent_otel_ctx) do
    offset = :erlang.time_offset()
    native_start = (span.start_time || 0) - offset
    native_end = native_start + (span.duration_native || 0)

    tracer = :opentelemetry.get_application_tracer(__MODULE__)

    # Erlang API: the Elixir `OpenTelemetry.Tracer.start_span` is a macro, which
    # would need `require OpenTelemetry.Tracer` — impossible to do conditionally
    # for an optional dep. Call its expansion (`:otel_tracer.start_span/4`) directly.
    span_ctx =
      :otel_tracer.start_span(parent_otel_ctx, tracer, span.name, %{
        start_time: native_start,
        kind: kind(span.kind),
        attributes: attributes(span),
        links: []
      })

    maybe_set_status(span_ctx, span)

    case events(span, native_end) do
      [] -> :ok
      evs -> OpenTelemetry.Span.add_events(span_ctx, evs)
    end

    OpenTelemetry.Span.end_span(span_ctx, native_end)
    span_ctx
  end

  # Force OUR trace_id via a synthetic remote parent: the root (and any span
  # whose parent ctx is unavailable) carries its recorded parent id, or its own
  # span_id as a dangling self-parent. -01 sampled flag is mandatory.
  defp traceparent_ctx(%Span{trace_id: trace, parent_span_id: parent, span_id: own}) do
    parent_hex = parent || own
    traceparent = "00-#{trace}-#{parent_hex}-01"

    # Erlang API: the W3C propagator and context modules have no Elixir wrapper.
    :otel_propagator_text_map.extract_to(
      :otel_ctx.new(),
      :otel_propagator_trace_context,
      [{"traceparent", traceparent}]
    )
  end

  defp kind(k) when k in [:internal, :server, :client], do: k
  defp kind(_), do: :internal

  # Only an error span gets a status set; success/unset spans keep OTel's
  # default UNSET — the idiomatic OTel representation of "completed, no error",
  # which is what the capture layer's :ok means (it sets :ok for result :ok OR
  # nil). Setting OTel OK would over-claim an explicit success override.
  defp maybe_set_status(span_ctx, %Span{status: :error} = span) do
    OpenTelemetry.Span.set_status(
      span_ctx,
      OpenTelemetry.status(:error, span.status_message || "")
    )
  end

  defp maybe_set_status(_span_ctx, _span), do: :ok

  defp attributes(%Span{} = span) do
    span.attributes
    |> coerce_map()
    |> put_present("image_pipe.pid", span.pid, &inspect/1)
    |> put_present("image_pipe.node", span.node, &Atom.to_string/1)
  end

  # Oneshot event :time is raw monotonic — pass through UNCONVERTED. Exception
  # event (no :time) uses native_end (same frame as the span). event/3 is
  # timestamp-FIRST.
  defp events(%Span{events: events}, native_end) do
    Enum.map(events, fn ev ->
      ts = Map.get(ev, :time) || native_end
      OpenTelemetry.event(ts, ev[:name], event_attrs(ev))
    end)
  end

  # The capture layer folds exceptions as %{name: "exception", attributes:
  # %{kind:, reason:}}; map them onto OTel exception semantic-convention keys.
  defp event_attrs(%{name: "exception", attributes: a}) do
    %{"exception.type" => to_str(a[:kind]), "exception.message" => to_str(a[:reason])}
  end

  defp event_attrs(ev), do: coerce_map(Map.get(ev, :attributes, %{}))

  defp put_present(map, _key, nil, _fun), do: map
  defp put_present(map, key, value, fun), do: Map.put(map, key, fun.(value))

  # OTel attribute values must be primitives; the public set path silently DROPS
  # others, so coerce to keep them. Sensitivity handled upstream by Capture.safe_attrs/1.
  defp coerce_map(map) do
    map
    |> Enum.flat_map(fn {k, v} ->
      case coerce(v) do
        :__drop__ -> []
        cv -> [{k, cv}]
      end
    end)
    |> Map.new()
  end

  defp coerce(nil), do: :__drop__
  defp coerce(v) when is_boolean(v), do: v
  defp coerce(v) when is_number(v) or is_binary(v), do: v
  defp coerce(v) when is_atom(v), do: Atom.to_string(v)

  defp coerce(v) when is_list(v) do
    if Enum.all?(v, &scalar_primitive?/1) do
      Enum.map(v, &list_elem/1)
    else
      inspect(v)
    end
  end

  defp coerce(v), do: inspect(v)

  defp scalar_primitive?(v), do: is_binary(v) or is_atom(v) or is_number(v)

  defp list_elem(v) when is_binary(v), do: v
  defp list_elem(v) when is_atom(v), do: Atom.to_string(v)
  defp list_elem(v) when is_number(v), do: to_string(v)

  defp to_str(nil), do: ""
  defp to_str(v) when is_binary(v), do: v
  defp to_str(v) when is_atom(v), do: Atom.to_string(v)
  defp to_str(v), do: inspect(v)
end
