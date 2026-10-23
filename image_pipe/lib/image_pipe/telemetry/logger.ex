defmodule ImagePipe.Telemetry.Logger do
  @moduledoc false
  # Default :telemetry -> Logger handler for ImagePipe. Attached opt-in via
  # ImagePipe.Telemetry.attach_default_logger/1. Reads event maps and calls
  # Logger only; no other dependencies.

  require Logger

  alias ImagePipe.Telemetry.Catalog

  @handler_id "image-pipe-default-logger"

  # A reason can hold source-derived terms of any size, and a host may turn
  # off Logger's truncation, so its inspected form is bounded.
  @inspect_opts [limit: 25, printable_limit: 256]

  # The summary fields after the line's head, in the order they're written.
  @summary_keys [
    :source_url,
    :watermark_source_urls,
    :error,
    :reason,
    :sig_key,
    :cache,
    :staging,
    :staging_reason,
    :source,
    :source_fetch,
    :fetch_ms,
    :input,
    :input_size,
    :decode_ms,
    :ops,
    :output,
    :output_size,
    :clamped,
    :quality,
    :quality_search,
    :encode_ms,
    :admission,
    :queue_ms,
    :detect,
    :degraded,
    :ignored,
    :skipped,
    :client_closed
  ]

  def all_groups, do: Catalog.groups()

  def attach(opts) do
    groups = Keyword.get(opts, :events, :all) |> expand_groups()
    prefix = Keyword.get(opts, :prefix, ImagePipe.Telemetry.default_prefix())
    level = Keyword.get(opts, :level, :info)
    debug? = Keyword.get(opts, :debug, false)
    stages? = Keyword.get(opts, :stages, false)

    events =
      case stages? do
        true -> Catalog.logged_events(groups, prefix)
        false -> Catalog.summary_events(groups, prefix)
      end

    failures_only = if stages?, do: [], else: Catalog.failure_stages()

    config = %{
      prefix: prefix,
      level: level,
      debug?: debug?,
      plen: length(prefix),
      failures_only: failures_only
    }

    _ = :telemetry.detach(@handler_id)
    :telemetry.attach_many(@handler_id, events, &__MODULE__.handle_event/4, config)
  end

  def detach, do: :telemetry.detach(@handler_id)

  defp expand_groups(:all), do: Catalog.groups()
  defp expand_groups(groups) when is_list(groups), do: groups

  @doc false
  def handle_event(event, measurements, metadata, config) do
    suffix = Enum.drop(event, config.plen)
    level = level_for(suffix, metadata, config.level)

    if logged?(suffix, level, config),
      do: log(level, event, suffix, measurements, metadata, config)

    :ok
  end

  defp logged?(suffix, level, config) do
    level in [:warning, :error] or
      Enum.reject(suffix, &(&1 in [:stop, :exception])) not in config.failures_only
  end

  defp log(level, event, suffix, measurements, metadata, config) do
    # A host that attaches this handler often runs Logger above its level, so
    # nothing is built for an event Logger would drop.
    if :logger.allow(level, __MODULE__) do
      Logger.log(
        level,
        fn -> render(suffix, measurements, metadata) end,
        log_metadata(suffix, event, measurements, metadata)
      )
    end

    if config.debug? do
      Logger.debug(fn ->
        "image_pipe #{label(suffix)} raw: measurements=#{inspect(measurements)} metadata=#{inspect(metadata)}"
      end)
    end
  end

  defp render(suffix, measurements, metadata) do
    message =
      if List.last(suffix) == :exception do
        exception_message(suffix, metadata)
      else
        message(suffix, measurements, metadata)
      end

    case metadata[:pool] do
      nil -> message
      pool -> message <> " (#{pool} pool)"
    end
  end

  # --- level ---
  # The request summary follows the status: 5xx is an error, 4xx a warning. A
  # 200 whose stream failed after its headers went out is an error.
  # Without a status (`ImagePipe.run/4`), a failure is a warning. So is a
  # degraded result, detection that fell back to attention, a quality search
  # that missed its target, or a result scaled down to the limits. A full pool
  # turning away a low-priority request is expected, so it logs at the base
  # level.
  defp level_for([:request, :summary], %{priority: :low, admission: admission}, base)
       when admission in [:overloaded, :queue_timeout],
       do: base

  defp level_for([:request, :summary], metadata, base) do
    status = metadata[:status] || 0

    cond do
      status >= 500 or (status == 200 and metadata[:result] == :processing_error) -> :error
      status >= 400 or summary_warning?(metadata) -> :warning
      true -> base
    end
  end

  defp level_for([:output, :clamp | _], _metadata, _base), do: :warning

  # A best-effort encode-quality search (the objective/budget could not be met
  # within the bracket) degrades the result, as does a search the pixel limit
  # cut short; surface them, and any search exception, as a warning. A :hit
  # logs at the base level.
  defp level_for([:encode, :search | _] = suffix, metadata, base) do
    cond do
      List.last(suffix) == :exception -> :warning
      metadata[:outcome] == :best_effort -> :warning
      metadata[:pixel_limited] == true -> :warning
      true -> base
    end
  end

  defp level_for([:debug, :collect, :error | _], _metadata, _base), do: :warning

  # Background sweeps repeat, so a pass that changed nothing logs at :debug.
  defp level_for([:cache, :sweep, :stop], metadata, base) do
    if quiet_pass?(metadata), do: :debug, else: base
  end

  # Steady drops mean the cache's storage can't keep up with its writes.
  defp level_for([:cache, :stage], %{cache: :stage_dropped}, _base), do: :warning

  # Requests for an original that may not be stored each fetch it, as they
  # would without coordination.
  defp level_for([:cache, :coordination], %{result: :bypass, reason: :not_stored}, base),
    do: base

  defp level_for([:cache, :coordination], %{result: result}, _base)
       when result in [:busy, :bypass, :timeout], do: :warning

  # A low-priority request waits for spare capacity, so a full pool turning it
  # away is expected.
  defp level_for([:processing, :admission | _], %{priority: :low, result: result}, base)
       when result in [:overloaded, :queue_timeout],
       do: base

  defp level_for([:processing | _], %{result: result}, _base)
       when result in [
              :overloaded,
              :queue_timeout,
              :timeout,
              :unavailable,
              :worker_down,
              :processing_error
            ],
       do: :warning

  defp level_for(suffix, metadata, base) do
    if stage_warning?(suffix, metadata), do: :warning, else: base
  end

  defp summary_warning?(metadata) do
    (is_nil(metadata[:status]) and metadata[:result] not in [nil, :ok, :not_modified, :options]) or
      metadata[:degraded] == true or
      metadata[:cache] == :read_error or
      metadata[:detect] in [:unavailable, :error, :no_detector, :not_ready] or
      metadata[:quality_search] == :best_effort or
      Map.has_key?(metadata, :clamped)
  end

  defp quiet_pass?(metadata) do
    Enum.all?(
      [:temps, :bodies, :unreadable, :staged],
      &(Map.get(metadata, &1, 0) == 0)
    )
  end

  defp stage_warning?(suffix, metadata) do
    List.last(suffix) == :exception or
      metadata[:result] in [
        :cache_error,
        :materialize_error,
        :source_error,
        :plan_error,
        :parser_error
      ] or
      encode_failure?(suffix, metadata) or
      color_management_failure?(suffix, metadata) or
      detect_fallback_warning?(suffix, metadata) or
      negotiate_failure?(suffix, metadata) or
      terminal_failure?(suffix, metadata) or
      preset_lookup_failure?(suffix, metadata)
  end

  # A genuine server-side encode-compute failure (forced evaluation raised/errored
  # before the first chunk → 500), analogous to a materialize failure. Scoped to
  # the `[:encode]` span only: `[:deliver]`, `[:send]`, and `[:request]` also carry
  # `:processing_error` for streaming/connection outcomes (including the normal
  # `:client_closed`), which stay at the base level.
  defp encode_failure?([:encode | _], meta), do: meta[:result] == :processing_error
  defp encode_failure?(_suffix, _meta), do: false

  # A corrupt or unsupported embedded ICC profile that prevents color conditioning —
  # a decode-class failure (maps to 415). Escalate to :warning.
  defp color_management_failure?([:transform, :input_color_management | _], meta),
    do: meta[:result] == :processing_error

  defp color_management_failure?(_suffix, _meta), do: false

  # A face-aware crop that could not be fulfilled and degraded to attention
  # saliency: a configured detector that produced no usable detection
  # (`:unavailable`, `:error`), or a `[:transform, :detect, :skipped]` one-shot
  # for a request with no detector configured (`:no_detector`) or a required
  # detector whose model isn't loaded yet (`:not_ready`). `:no_regions` (no
  # face in frame) is a normal result, not a warning.
  defp detect_fallback_warning?([:transform, :detect | _], meta),
    do: meta[:result] in [:unavailable, :error, :no_detector, :not_ready]

  defp detect_fallback_warning?(_suffix, _meta), do: false

  # Output negotiation that could not resolve a deliverable format → escalate to
  # :warning. The `:ok` outcome stays at base level.
  defp negotiate_failure?([:output, :negotiate | _], meta), do: meta[:result] not in [:ok, nil]
  defp negotiate_failure?(_suffix, _meta), do: false

  defp terminal_failure?([:output, :terminal | _], meta), do: meta[:result] not in [:ok, nil]
  defp terminal_failure?(_suffix, _meta), do: false

  defp preset_lookup_failure?([:preset, :lookup | _], meta), do: meta[:result] == :error
  defp preset_lookup_failure?(_suffix, _meta), do: false

  # --- message ---
  # `GET /w=200/src/beach.jpg 200 71ms 4.6kB`, then the other fields as
  # `key=value`. `ImagePipe.run/4` has no method, path, or status, so its line
  # starts with the result.
  defp message([:request, :summary], _m, meta) do
    head =
      [meta[:method], meta[:path], meta[:status] || meta[:result], "#{meta[:duration_ms]}ms"] ++
        List.wrap(if bytes = meta[:bytes], do: size(bytes))

    rest =
      for key <- @summary_keys,
          value = Map.get(meta, key),
          value != nil,
          field <- summary_fields(key, value),
          do: field

    Enum.join(Enum.reject(head, &is_nil/1) ++ rest, " ")
  end

  defp message([:transform, :operation | _], _m, meta) do
    "image_pipe transform: #{meta[:operation]} #{outcome(meta)}"
  end

  defp message([:transform, :execute | _], _m, meta) do
    "image_pipe transform execute: #{outcome(meta)} (#{meta[:operation_count] || 0} ops)"
  end

  defp message([:transform, :input_color_management | _], _m, meta) do
    imported = if meta[:imported?], do: " imported", else: ""

    "image_pipe transform input_color_management: #{outcome(meta)}#{imported} (#{meta[:working_space]})"
  end

  defp message([:transform, :detect, :skipped | _], _m, meta),
    do: "image_pipe transform detect: skipped (#{skip_reason(meta[:result])})"

  defp message([:transform, :detect, :blend | _], _m, meta) do
    "image_pipe transform detect blend: attention #{point(meta[:attention])} -> " <>
      "#{point(meta[:blended])} (face #{point(meta[:face])}, weight #{meta[:weight]})"
  end

  defp message([:cache, :lookup | _], _m, meta),
    do: "image_pipe cache lookup: #{meta[:cache]}#{bytes(meta[:bytes])}"

  defp message([:cache, :write | _], _m, meta) do
    detail =
      case meta[:cache] do
        :write -> "stored"
        :admission_rejected -> "rejected by admission"
        :write_error -> "error#{error_note(meta)}"
        other -> inspect(other)
      end

    "image_pipe cache write: #{detail}#{bytes(meta[:bytes])}"
  end

  defp message([:cache, :coordination], _m, %{reason: reason} = meta),
    do: "image_pipe cache coordination: #{outcome(meta)} (#{reason})"

  defp message([:cache, :stage], _m, %{cache: :stage_dropped} = meta),
    do: "image_pipe cache stage: stage_dropped (#{meta[:reason]})"

  defp message([:cache, :admission | _], _m, meta) do
    "image_pipe cache admission: #{meta[:result]}"
  end

  defp message([:cache, :eviction | _], measurements, meta) do
    "image_pipe cache eviction: #{measurements[:count]} entries (#{meta[:trigger]})"
  end

  defp message([:output, :clamp | _], _m, meta) do
    {sw, sh} = meta[:source_dimensions]
    {w, h} = meta[:dimensions]
    %{max_width: mw, max_height: mh, max_pixels: mp} = meta[:limits]

    "image_pipe output clamp: #{sw}x#{sh} -> #{w}x#{h} for #{meta[:format]} " <>
      "(caps w:#{cap(mw)} h:#{cap(mh)} px:#{cap(mp)})"
  end

  # The delivered-probe marker. BEFORE the probe-span clause below: its event name
  # nests under [:encode, :search, :probe], so the span clause would otherwise
  # match and render it as a probe stop (missing the phase/winner framing).
  defp message([:encode, :search, :probe, :chosen | _], _m, meta) do
    score = if meta[:score], do: " score #{round2(meta[:score])}", else: ""

    "image_pipe encode search chosen: q#{meta[:quality]} #{meta[:bytes]}b " <>
      "(#{meta[:phase]}#{score})"
  end

  # Specific clause BEFORE the search clause below: a probe stop would otherwise
  # match [:encode, :search | _] and render with the search verdict's keys (nil).
  defp message([:encode, :search, :probe | _], _m, meta) do
    score = if meta[:score], do: " score #{round2(meta[:score])}", else: ""

    "image_pipe encode search probe: #{outcome(meta)} " <>
      "(#{meta[:phase]} q#{meta[:quality]} #{meta[:bytes]}b#{score})"
  end

  defp message([:encode, :search | _], _m, meta) do
    score = if meta[:final_score], do: " score #{round2(meta[:final_score])}", else: ""
    scorer = if meta[:scorer], do: "#{meta[:scorer]} ", else: ""

    limited = if meta[:pixel_limited], do: " pixel-limited", else: ""

    "image_pipe encode search: #{outcome(meta)} (#{scorer}#{meta[:outcome]} " <>
      "q#{meta[:chosen_quality]} #{meta[:chosen_bytes]}b#{score}#{limited})"
  end

  defp message([:encode | _], _m, meta) do
    format = if meta[:output_format], do: " (#{meta[:output_format]})", else: ""
    "image_pipe encode: #{outcome(meta)}#{format}"
  end

  defp message([:output, :negotiate | _], _m, meta) do
    format = if meta[:output_format], do: " (#{meta[:output_format]})", else: ""
    "image_pipe output negotiate: #{outcome(meta)}#{format}"
  end

  defp message([:output, :terminal | _], _m, meta) do
    placeholders =
      case meta[:placeholders] do
        [_ | _] = placeholders -> " with " <> Enum.join(placeholders, ", ")
        _none -> ""
      end

    "image_pipe output terminal: #{outcome(meta)} (#{meta[:terminal]}#{placeholders})"
  end

  defp message([:transform, :detect, :model | _], _m, meta) do
    "image_pipe transform detect model: #{outcome(meta)} " <>
      "(#{meta[:regions]} regions, #{inspect(meta[:detector])})"
  end

  defp message([:http_cache, :prepare | _], _m, meta) do
    "image_pipe http_cache prepare: #{meta[:effective_mode]} " <>
      "(byte_identity #{meta[:byte_identity]}, etag #{meta[:etag]})"
  end

  defp message([:http_cache, :conditional, :match | _], _m, meta) do
    "image_pipe http_cache conditional match: #{meta[:method]}"
  end

  defp message([:http_cache, :fallback, :no_store | _], _m, meta) do
    "image_pipe http_cache fallback no_store: #{meta[:reason]}#{source_note(meta)}"
  end

  defp message([:http_cache, :cache_hit, :headers | _], _m, meta) do
    "image_pipe http_cache cache_hit headers: etag #{meta[:etag]} " <>
      "(generated #{meta[:generated_cache_headers]}, representation #{meta[:representation_headers]})"
  end

  defp message([:source, stage | _], _m, %{source_name: name} = meta)
       when stage in [:resolve, :fetch] and not is_nil(name),
       do: "image_pipe source #{stage}: #{result(meta)} (#{error_prefix(meta)}source #{name})"

  defp message([:source, :watermark | _], _m, meta),
    do: "image_pipe source watermark #{meta[:phase]}: #{outcome(meta)}"

  defp message([:source, :svg_render | _], _m, %{rendered_dims: {width, height}} = meta) do
    {intrinsic_width, intrinsic_height} = meta[:intrinsic_dims]

    "image_pipe source svg_render: #{result(meta)} (#{meta[:asset]} " <>
      "#{intrinsic_width}x#{intrinsic_height} rendered at #{width}x#{height}, " <>
      "#{meta[:images]} images)"
  end

  defp message([:source, :svg_render | _], _m, meta) do
    notes = Enum.reject([meta[:asset], error_category(meta), limit_note(meta)], &is_nil/1)
    "image_pipe source svg_render: #{result(meta)} (#{Enum.join(notes, ", ")})"
  end

  defp message([:source, :svg_parse | _], _m, %{intrinsic_dims: {width, height}} = meta),
    do: "image_pipe source svg_parse: #{result(meta)} (#{meta[:asset]} #{width}x#{height})"

  defp message([:source, :svg_parse | _], _m, meta) do
    notes = Enum.reject([meta[:asset], error_category(meta), limit_note(meta)], &is_nil/1)
    "image_pipe source svg_parse: #{result(meta)} (#{Enum.join(notes, ", ")})"
  end

  defp message([:source, :fetch_decode | _], _m, meta) do
    notes =
      Enum.reject(
        [
          error_category(meta),
          detected_note(meta),
          skipped_note(meta),
          loader_note(meta),
          page_note(meta),
          frames_note(meta),
          limit_note(meta)
        ],
        &is_nil/1
      )

    case notes do
      [] -> "image_pipe source fetch_decode: #{result(meta)}"
      notes -> "image_pipe source fetch_decode: #{result(meta)} (#{Enum.join(notes, ", ")})"
    end
  end

  defp message([:request, :ignored_options | _], _m, meta),
    do:
      "image_pipe request ignored options: #{outcome(meta)} (#{Enum.join(meta[:options], ", ")})"

  defp message([:parse | _], _m, %{sig_key_index: index} = meta),
    do: "image_pipe parse: #{outcome(meta)} (signing key #{index})"

  defp message([:preset, :lookup | _], _m, %{result: :error} = meta),
    do: "image_pipe preset lookup: error (#{meta[:reason]})"

  defp message([:preset, :lookup | _], _m, meta),
    do:
      "image_pipe preset lookup: #{outcome(meta)} (#{meta[:fetched]} fetched, #{meta[:batches]} batches)"

  defp message([:debug, :collect, :error | _], _m, meta),
    do: "image_pipe debug collect: error (#{inspect(meta[:error])})"

  defp message(suffix, _m, meta) do
    "image_pipe #{label(suffix)}: #{outcome(meta)}"
  end

  defp cap(:infinity), do: "inf"
  defp cap(value), do: value

  defp exception_message(suffix, meta) do
    "image_pipe #{label(suffix)}: exception (#{meta[:kind]} #{inspect(meta[:reason], @inspect_opts)})"
  end

  defp outcome(meta) do
    result = result(meta)

    case error_category(meta) do
      error when error in [nil, result] -> "#{result}"
      error -> "#{result} (#{error})"
    end
  end

  defp result(meta), do: meta[:cache] || meta[:result] || :ok

  # Only category atoms are rendered: some stages carry a raw reason term.
  defp error_category(%{error: error}) when is_atom(error) and not is_nil(error), do: error
  defp error_category(_meta), do: nil

  defp error_note(meta) do
    case error_category(meta) do
      nil -> ""
      error -> " (#{error})"
    end
  end

  defp error_prefix(meta) do
    case error_category(meta) do
      nil -> ""
      error -> "#{error}, "
    end
  end

  defp source_note(%{source_name: name}) when not is_nil(name), do: " (source #{name})"
  defp source_note(_meta), do: ""

  defp detected_note(%{detected_source_format: detected} = meta) when not is_nil(detected),
    do: "detected #{detected}#{resolution_note(meta)}"

  defp detected_note(_meta), do: nil

  defp skipped_note(%{skipped: true}), do: "skipped processing"
  defp skipped_note(_meta), do: nil

  defp loader_note(%{source_loader: loader}) when not is_nil(loader), do: "loader #{loader}"
  defp loader_note(_meta), do: nil

  defp page_note(%{page: page}) when is_integer(page), do: "page #{page}"
  defp page_note(_meta), do: nil

  defp frames_note(%{source_frames: frames}) when is_integer(frames) and frames > 1,
    do: "#{frames} frames"

  defp frames_note(_meta), do: nil

  defp limit_note(%{limit: limit}) when not is_nil(limit), do: "#{limit} limit"
  defp limit_note(_meta), do: nil

  defp resolution_note(meta) do
    case meta[:source_format_resolution] do
      nil -> ""
      resolution -> " via #{resolution}"
    end
  end

  defp label(suffix) do
    suffix
    |> Enum.reject(&(&1 in [:stop, :exception]))
    |> Enum.map_join(" ", &Atom.to_string/1)
  end

  defp size(bytes) when bytes < 1_000, do: "#{bytes}B"
  defp size(bytes) when bytes < 1_000_000, do: "#{Float.round(bytes / 1_000, 1)}kB"
  defp size(bytes), do: "#{Float.round(bytes / 1_000_000, 1)}MB"

  # Values with spaces or quotes are quoted, as in logfmt.
  # A source URL can hold a comma, so each watermark source gets its own
  # field rather than a joined list.
  defp summary_fields(:watermark_source_urls, sources),
    do: Enum.map(sources, &"watermark_source_url=#{summary_value(&1)}")

  defp summary_fields(key, value), do: ["#{key}=#{summary_value(value)}"]

  defp summary_value(value) when is_binary(value) do
    if String.contains?(value, [" ", "\"", "="]), do: inspect(value), else: value
  end

  defp summary_value(values) when is_list(values),
    do: Enum.map_join(values, ",", &summary_value/1)

  defp summary_value({width, height}), do: "#{width}x#{height}"

  defp summary_value(value) when is_atom(value) or is_number(value), do: to_string(value)
  defp summary_value(value), do: inspect(value, @inspect_opts)

  defp skip_reason(:no_detector), do: "no detector configured"
  defp skip_reason(:not_ready), do: "face model not loaded yet"
  defp skip_reason(:unavailable), do: "face detection unavailable"

  defp point({x, y}), do: "(#{round2(x)},#{round2(y)})"
  defp point(_other), do: "(?,?)"

  defp bytes(nil), do: ""
  defp bytes(bytes), do: " #{bytes}b"

  defp round2(n) when is_number(n), do: Float.round(n * 1.0, 2)
  defp round2(_other), do: nil

  # --- logger metadata ---
  # The summary's fields go under one key, so they can't collide with fields a
  # JSON formatter or log collector reserves, such as Datadog's `status`.
  defp log_metadata([:request, :summary], event, _measurements, metadata),
    do: [event: event, image_pipe: metadata]

  defp log_metadata(_suffix, event, measurements, metadata) do
    base = [event: event]

    base =
      case measurements[:duration] do
        nil -> base
        native -> [{:duration_us, System.convert_time_unit(native, :native, :microsecond)} | base]
      end

    Keyword.merge(base, Map.to_list(metadata))
  end
end
