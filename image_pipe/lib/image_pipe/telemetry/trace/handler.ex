defmodule ImagePipe.Telemetry.Trace.Handler do
  @moduledoc false
  # Turns ImagePipe's telemetry events into OpenTelemetry spans as they
  # happen. A `:start` opens a span under the process's current context and
  # makes it current; the matching `:stop` or `:exception` ends it and makes
  # its parent current again. One-shot events become events on the current
  # span.
  #
  # Open spans are kept in the process dictionary, keyed by the event's
  # `telemetry_span_context`, so a stop finds its own span even when other
  # spans opened or closed in this process in between. A span must stop in
  # the process that started it.

  @compile {:no_warn_undefined,
            [OpenTelemetry.Span, :opentelemetry, :otel_ctx, :otel_span, :otel_tracer]}

  alias ImagePipe.Telemetry.Catalog

  @handler_id {__MODULE__, :spans}

  @oneshot_stages Catalog.oneshot_stages()

  # Keys safe to copy into span attributes (allowlist; everything else dropped).
  #
  # Never allow source URLs/paths, request paths, signatures, tokens, or other
  # secret-bearing data. Keep :params opaque: matching concrete transform structs
  # here would invert the telemetry dependency boundary.
  @safe_keys [
    :pool,
    # hash of the cache key a lookup or write used
    :cache_key,
    # what a cache lookup reads: :response or :source_record
    :entry,
    # files a sweep removed, per kind
    :pins,
    :temps,
    :bodies,
    :staged,
    # entries a re-scan started or stopped counting, or resized
    :adopted,
    :dropped,
    :resynced,
    :active,
    :queued,
    :operation,
    :index,
    :operation_count,
    :operations,
    :terminal,
    # info's included placeholder names (:blurhash, :lqip_css)
    :placeholders,
    :result,
    # matched signing-key index on the parser's [:parse] stop
    # metadata (nil when the request is legitimately unsigned) — a small
    # integer, never a secret
    :sig_key_index,
    # preset lookup: host-chosen preset names and counts
    :names,
    # URL keys of the inert options a request wrote, never their values
    :options,
    :fetched,
    :batches,
    :cache,
    :output_mode,
    :source_name,
    :detector,
    :model,
    :classes,
    :regions,
    # requested weight per detection class (a map of class name to number)
    :weights,
    :width,
    :height,
    :format,
    :params,
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
    # per-probe span attributes: phase and the search-level limiting factor (both
    # product-neutral atoms)
    :phase,
    :limiting_factor,
    # fetch/decode shape
    :load_option,
    :loaded_dims,
    :original_dims,
    :achieved_shrink,
    :detected_source_format,
    :source_format_resolution,
    # the source was delivered unchanged under skip_processing_formats
    :skipped,
    # declared frame/page count, and which input limit rejected the source
    :source_frames,
    :limit,
    # the libvips loader name a family check rejected (e.g. "dcrawload")
    :source_loader,
    # the requested page or frame of a multi-frame source (a small integer)
    :page,
    # a libvips open's access mode (:sequential or :random)
    :access,
    # realized post-op/post-materialize dimensions ({width, height}); a tuple,
    # coerced the same as :params (coerce/1)
    :dims,
    # output-clamp one-shot shape: the pre/post dimension tuples and the resolved
    # limits map (all product-neutral geometry; the negotiated :format is above)
    :source_dimensions,
    :dimensions,
    :limits,
    # input color-management stop shape: the imported working-space atom and the
    # ICC-import boolean (product-neutral; sourced from runtime image inspection)
    :working_space,
    :imported?,
    # cache admission / eviction
    :victim_count,
    :trigger,
    # HTTP cache one-shots: the cache-header mode and booleans about the response
    # headers, never the ETag value itself
    :effective_mode,
    :byte_identity,
    :etag,
    :method,
    :generated_cache_headers,
    :representation_headers,
    # face/attention blend: normalized {x, y} points and the face weight
    :attention,
    :face,
    :blended,
    :weight
  ]

  # Results that are normal outcomes rather than failures: a detector that found
  # nothing, a cache declining an entry, or a client that went away. Every other
  # result is a failure.
  @ok_results [
    nil,
    :ok,
    :admitted,
    :options,
    :not_modified,
    :detected,
    :no_regions,
    :rejected,
    :client_closed,
    :cancelled
  ]

  @spec attach([atom()]) :: :ok
  def attach(prefix) do
    _ = :telemetry.detach(@handler_id)

    _ =
      :telemetry.attach_many(
        @handler_id,
        Catalog.traced_events(prefix),
        &__MODULE__.handle_event/4,
        length(prefix)
      )

    :ok
  end

  @spec detach() :: :ok
  def detach do
    _ = :telemetry.detach(@handler_id)
    :ok
  end

  def handle_event(event, measurements, meta, prefix_length) do
    stage = Enum.drop(event, prefix_length)

    # One-shots first: events such as [:cache, :eviction, :stop] must not end a span.
    if stage in @oneshot_stages do
      on_oneshot(name(stage), measurements, meta)
    else
      {stage, [phase]} = Enum.split(stage, -1)
      on_phase(phase, stage, measurements, meta)
    end
  rescue
    # A tracer must never crash the request path; drop the event on any internal error.
    _ -> :ok
  end

  defp on_phase(:start, stage, measurements, meta) do
    parent = :otel_ctx.get_current()

    span_ctx =
      :otel_tracer.start_span(parent, tracer(), name(stage), %{
        start_time: measurements.monotonic_time,
        kind: :internal,
        attributes: start_attributes(stage, meta)
      })

    Process.put({__MODULE__, meta.telemetry_span_context}, {span_ctx, parent})
    :otel_ctx.attach(:otel_tracer.set_current_span(parent, span_ctx))
  end

  defp on_phase(:stop, _stage, measurements, meta) do
    finish(meta, measurements, fn span_ctx ->
      :otel_span.set_attributes(span_ctx, attributes(meta))

      unless meta[:result] in @ok_results do
        :otel_span.set_status(span_ctx, :error, "")
      end
    end)
  end

  defp on_phase(:exception, _stage, measurements, meta) do
    finish(meta, measurements, fn span_ctx ->
      :otel_span.record_exception(span_ctx, meta.kind, meta.reason, meta.stacktrace, %{})
      :otel_span.set_status(span_ctx, :error, inspect(meta.reason))
    end)
  end

  defp finish(meta, measurements, annotate) do
    case Process.delete({__MODULE__, meta.telemetry_span_context}) do
      nil ->
        :ok

      {span_ctx, parent} ->
        annotate.(span_ctx)
        :otel_span.end_span(span_ctx, measurements.monotonic_time)

        if :otel_tracer.current_span_ctx() == span_ctx do
          :otel_ctx.attach(parent)
        end
    end
  end

  defp on_oneshot(name, measurements, meta) do
    case :otel_tracer.current_span_ctx() do
      :undefined ->
        :ok

      span_ctx ->
        time = Map.get_lazy(measurements, :monotonic_time, &:opentelemetry.timestamp/0)
        :otel_span.add_events(span_ctx, [:opentelemetry.event(time, name, attributes(meta))])
    end
  end

  @doc false
  # The tracer every ImagePipe span is created with.
  def tracer, do: :opentelemetry.get_application_tracer(__MODULE__)

  defp name(stage), do: "image_pipe." <> Enum.map_join(stage, ".", &Atom.to_string/1)

  # The request span also carries the host's request ID, such as the one
  # `Plug.RequestId` puts in Logger metadata, linking the trace to log lines.
  defp start_attributes([:request], meta) do
    case Logger.metadata()[:request_id] do
      nil -> attributes(meta)
      request_id -> meta |> attributes() |> Map.put(:request_id, coerce(request_id))
    end
  end

  defp start_attributes(_stage, meta), do: attributes(meta)

  # Allowlisted metadata, as OpenTelemetry attribute values. The API drops
  # values that aren't primitives, so others are coerced instead.
  defp attributes(meta) do
    for {key, value} <- Map.take(meta, @safe_keys), value != nil, into: %{} do
      {key, coerce(value)}
    end
  end

  defp coerce(value) when is_boolean(value) or is_number(value) or is_binary(value), do: value
  defp coerce(value) when is_atom(value), do: Atom.to_string(value)

  defp coerce(value) when is_list(value) do
    if Enum.all?(value, &(is_binary(&1) or is_atom(&1) or is_number(&1))) do
      Enum.map(value, &to_string/1)
    else
      inspect(value)
    end
  end

  defp coerce(value), do: inspect(value)
end
