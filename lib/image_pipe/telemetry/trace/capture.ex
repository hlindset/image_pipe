defmodule ImagePipe.Telemetry.Trace.Capture do
  @moduledoc false
  alias ImagePipe.Telemetry.Trace.{Context, Id, Inbound, Span, Stack}

  @handler_id {__MODULE__, :spans}

  # Span stages emitted under the image_pipe prefix.
  @span_stages [
    [:request],
    [:parse],
    [:send],
    [:encode],
    [:encode, :search],
    # Content classification for the per-class crop offset (#380). Emitted before
    # the search span opens, so it is a sibling of [:encode, :search] under [:encode].
    [:encode, :classify],
    [:encode, :search, :probe],
    # Per-probe cost legs (eager NIF/op calls → honest durations). The encode leg
    # is method-neutral (fires for every objective); the scoring legs carry the
    # per-metric segment (`:ssimulacra2`/`:butteraugli`, from the metric's
    # `leg_name/0`) so each metric gets distinct span names a backend can group by.
    [:encode, :search, :probe, :encode],
    [:encode, :search, :probe, :ssimulacra2, :decode],
    [:encode, :search, :probe, :ssimulacra2, :metric],
    [:encode, :search, :probe, :butteraugli, :decode],
    [:encode, :search, :probe, :butteraugli, :metric],
    [:render],
    [:deliver],
    [:source, :resolve],
    [:source, :fetch],
    [:source, :fetch_decode],
    [:output, :negotiate],
    [:transform, :execute],
    [:transform, :input_color_management],
    [:transform, :operation],
    [:transform, :materialize],
    [:transform, :detect],
    [:transform, :detect, :model],
    [:cache, :lookup],
    [:cache, :write],
    [:cache, :admission],
    [:cache, :warm_start]
  ]

  # One-shot (terminal) events — folded as annotations onto the current span.
  @oneshot_stages [
    # Delivered-probe marker: folds onto the enclosing [:encode, :search] span,
    # naming the winning quality/phase that produced the shipped bytes. All keys
    # (quality, bytes, phase, index, score, scorer, tiles_scored) are in @safe_keys.
    [:encode, :search, :probe, :chosen],
    [:cache, :stage],
    [:cache, :eviction, :stop],
    [:cache, :flush, :stop],
    [:cache, :cleanup, :stop],
    [:output, :clamp],
    [:transform, :detect, :skipped],
    [:transform, :detect, :blend],
    [:http_cache, :prepare],
    [:http_cache, :conditional, :match],
    [:http_cache, :fallback, :no_store],
    [:http_cache, :cache_hit, :headers],
    [:debug, :collect, :error]
  ]

  # Keys safe to copy into span attributes (allowlist; everything else dropped).
  #
  # SENSITIVITY: allowlist only. Never add :source_url, :source_path, request paths,
  # signatures, tokens, or any secret-bearing key. Operation structs (:params) are
  # stored opaque (inspected by exporters) and MUST NOT be pattern-matched against
  # concrete transform operation structs here — that would invert the telemetry
  # boundary (enforced by the capture-no-concrete-modules architecture test).
  @safe_keys [
    :operation,
    :index,
    :operation_count,
    :operations,
    :result,
    :cache,
    :output_mode,
    :source_kind,
    :source_adapter_kind,
    :detector,
    :model,
    :classes,
    :regions,
    :scale,
    :width,
    :height,
    :format,
    :params,
    :renderer,
    :objective,
    :min_quality,
    :max_quality,
    :target,
    :max_bytes,
    :quality,
    :bytes,
    :score,
    # Stop-metadata verdicts (the per-result facts an observer reads off a
    # finished span). All product-neutral; sourced from request inputs or
    # runtime image inspection, never from secret-bearing strings.
    :status,
    :error,
    :reason,
    :output_format,
    :content_type,
    :stream_phase,
    # encode-search outcome
    :chosen_quality,
    :chosen_bytes,
    :final_score,
    :scorer,
    :outcome,
    :iterations,
    :tiles_scored,
    :confirm_passes,
    # content classification for the per-class crop offset (#380): all product-neutral
    # (a class atom, a constant offset, two image statistics)
    :content_class,
    :applied_offset,
    :palette_ent,
    :nat_var,
    # per-probe span attributes: phase, the search-level limiting factor, and the
    # crop→full confirm residual (all product-neutral numbers/atoms)
    :phase,
    :limiting_factor,
    :crop_estimate,
    :full_frame_score,
    :passed?,
    # fetch/decode shape
    :load_option,
    :loaded_dims,
    :original_dims,
    :achieved_shrink,
    :detected_source_format,
    :source_format_resolution,
    # cache admission / warm-start
    :victim_count,
    :own_state_loaded,
    :peer_state_files
  ]

  @spec attach(map()) :: :ok
  def attach(%{prefix: prefix, exporter: _exporter} = config) do
    events =
      for(
        stage <- @span_stages,
        suffix <- [:start, :stop, :exception],
        do: prefix ++ stage ++ [suffix]
      ) ++
        for(stage <- @oneshot_stages, do: prefix ++ stage)

    _ = :telemetry.detach(@handler_id)

    _ =
      :telemetry.attach_many(
        @handler_id,
        events,
        &__MODULE__.handle_event/4,
        Map.put(config, :plen, length(prefix))
      )

    :ok
  end

  @spec detach() :: :ok
  def detach do
    _ = :telemetry.detach(@handler_id)
    :ok
  end

  def handle_event(event, measurements, meta, config) do
    case classify(event, config.plen) do
      {:start, name} -> on_start(name, measurements, meta, config)
      {:stop, _name} -> on_stop(measurements, meta, config)
      {:exception, _name} -> on_exception(measurements, meta, config)
      {:oneshot, name} -> on_oneshot(name, meta)
    end
  rescue
    # A tracer must never crash the request path; drop the event on any internal error.
    _ -> :ok
  end

  # ---- classification --------------------------------------------------------

  defp classify(event, plen) do
    stage = Enum.drop(event, plen)

    # CRITICAL: one-shots whose last atom is :stop (e.g. [:cache, :flush, :stop],
    # [:cache, :eviction, :stop], [:cache, :cleanup, :stop]) are terminal events, NOT
    # span stops. Check membership in @oneshot_stages BEFORE the suffix dispatch, or
    # they would wrongly pop and export an unrelated span.
    if stage in @oneshot_stages do
      {:oneshot, name(stage)}
    else
      case List.last(stage) do
        :start -> {:start, name(stage_without_suffix(stage))}
        :stop -> {:stop, name(stage_without_suffix(stage))}
        :exception -> {:exception, name(stage_without_suffix(stage))}
        _ -> {:oneshot, name(stage)}
      end
    end
  end

  defp stage_without_suffix(stage), do: Enum.drop(stage, -1)

  defp name(stage), do: "image_pipe." <> Enum.map_join(stage, ".", &Atom.to_string/1)

  # ---- handlers --------------------------------------------------------------

  defp on_start(name, measurements, meta, config) do
    {trace_id, parent_id, flags, root?} =
      case Stack.current() do
        nil ->
          {trace_id, parent_id, flags} = root_ids(config)
          {trace_id, parent_id, flags, true}

        %Span{trace_id: t, span_id: s, trace_flags: pf} ->
          {t, s, pf, false}
      end

    Stack.push(%Span{
      trace_id: trace_id,
      span_id: Id.span_id(),
      parent_span_id: parent_id,
      name: name,
      kind: :internal,
      start_time: measurements[:system_time],
      trace_flags: flags,
      attributes: safe_attrs(meta),
      pid: self(),
      node: node(),
      root: root?
    })
  end

  defp on_stop(measurements, meta, %{exporter: exporter}) do
    case Stack.pop() do
      nil ->
        :ok

      # A synthetic remote-parent frame must never be finalized/exported: it belongs to
      # the upstream process. If a stray :stop pops it, re-push and no-op.
      %Span{name: "remote_parent", start_time: nil} = parent ->
        Stack.push(parent)
        :ok

      span ->
        span
        |> merge_attrs(meta)
        |> finalize(measurements, status_from(meta))
        |> export(exporter)
    end
  end

  defp on_exception(measurements, meta, %{exporter: exporter}) do
    case Stack.pop() do
      nil ->
        :ok

      # See on_stop: never finalize/export the synthetic cross-process parent frame.
      %Span{name: "remote_parent", start_time: nil} = parent ->
        Stack.push(parent)
        :ok

      span ->
        span
        |> Map.update!(:events, &[exception_event(meta) | &1])
        |> finalize(measurements, :error)
        |> Map.put(:status_message, exception_message(meta))
        |> export(exporter)
    end
  end

  defp on_oneshot(name, meta) do
    case Stack.current() do
      nil ->
        :ok

      span ->
        event = %{name: name, time: meta[:monotonic_time], attributes: safe_attrs(meta)}
        Stack.pop()
        Stack.push(%{span | events: [event | span.events]})
    end
  end

  # ---- helpers ---------------------------------------------------------------

  # Inbound root context (W3C traceparent) is consumed once at the root span; falls
  # back to minting a fresh trace when no inbound context is present.
  defp root_ids(_config) do
    case Inbound.take() do
      %Context{trace_id: t, span_id: s, trace_flags: f} -> {t, s, f}
      nil -> {Id.trace_id(), nil, 1}
    end
  end

  defp finalize(span, measurements, status) do
    %{
      span
      | duration_native: measurements[:duration],
        end_time: end_time(span.start_time, measurements),
        status: status
    }
  end

  # start_time is native system_time (wall-clock); duration is a native monotonic
  # delta. Both native → the sum is a valid native end_time. Exporters convert to
  # ms/µs as needed; we keep native here (and duration_native) as the source of truth.
  defp end_time(nil, _), do: nil
  defp end_time(start, %{duration: d}) when is_integer(d), do: start + d
  defp end_time(start, _), do: start

  defp status_from(meta) do
    case meta[:result] do
      :ok -> :ok
      :options -> :ok
      nil -> :ok
      _other -> :error
    end
  end

  defp exception_event(meta) do
    %{name: "exception", attributes: %{kind: meta[:kind], reason: inspect(meta[:reason])}}
  end

  defp exception_message(meta), do: inspect(meta[:reason])

  # Span attributes are seeded from start metadata (on_start) and then enriched
  # with the stop metadata's allowlisted keys here — the per-result verdict
  # (chosen quality/score, HTTP status, error tag, decoded shape, …) that the
  # Logger and metrics handlers already see. Stop keys win on collision (the
  # start value was a placeholder for the same fact).
  defp merge_attrs(%Span{attributes: attrs} = span, meta) do
    %{span | attributes: Map.merge(attrs, safe_attrs(meta))}
  end

  defp safe_attrs(meta) do
    Map.take(meta, @safe_keys)
  end

  defp export(span, exporter), do: exporter.export(span)
end
