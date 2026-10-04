defmodule ImagePipe.Telemetry.Logger do
  @moduledoc false
  # Default :telemetry -> Logger handler for ImagePipe. Attached opt-in via
  # ImagePipe.Telemetry.attach_default_logger/1. Reads event maps and calls
  # Logger only; no other dependencies.

  require Logger

  @handler_id "image-pipe-default-logger"

  # group => span event suffixes (each gets :stop + :exception)
  @group_span_events %{
    request: [
      [:request],
      [:processing, :admission],
      [:processing, :execute],
      [:send],
      [:encode],
      [:encode, :search],
      [:encode, :search, :probe],
      [:encode, :classify],
      [:deliver]
    ],
    parse: [[:parse], [:preset, :lookup]],
    source: [
      [:source, :resolve],
      [:source, :fetch],
      [:source, :fetch_decode],
      [:source, :stage],
      [:source, :watermark]
    ],
    transform: [
      [:transform, :execute],
      [:transform, :input_color_management],
      [:transform, :operation],
      [:transform, :materialize],
      [:transform, :detect],
      [:transform, :detect, :model]
    ],
    cache: [
      [:cache, :lookup],
      [:cache, :write],
      [:cache, :admission],
      [:cache, :warm_start],
      [:cache, :input],
      [:cache, :refresh]
    ],
    output: [[:output, :negotiate], [:output, :terminal]],
    http_cache: [],
    debug: []
  }

  # request one-shot events (already terminal; not spans)
  @request_oneshot [
    [:encode, :search, :probe, :chosen]
  ]

  # cache one-shot events (already terminal; not spans)
  @cache_oneshot [
    [:cache, :coordination],
    [:cache, :eviction, :stop],
    [:cache, :flush, :stop],
    [:cache, :cleanup, :stop],
    [:cache, :stage]
  ]

  # transform one-shot events (already terminal; not spans)
  @transform_oneshot [
    [:transform, :detect, :skipped],
    [:transform, :detect, :blend]
  ]

  # output one-shot events (already terminal; not spans)
  @output_oneshot [
    [:output, :clamp]
  ]

  # generated CDN HTTP-cache one-shot events (already terminal; not spans)
  @http_cache_oneshot [
    [:http_cache, :prepare],
    [:http_cache, :conditional, :match],
    [:http_cache, :fallback, :no_store],
    [:http_cache, :cache_hit, :headers]
  ]

  # debug one-shot events (best-effort debug-fact collection)
  @debug_oneshot [
    [:debug, :collect, :error]
  ]

  @all_groups Map.keys(@group_span_events)

  def all_groups, do: @all_groups

  def attach(opts) do
    groups = Keyword.get(opts, :events, :all) |> expand_groups()
    prefix = Keyword.get(opts, :prefix, ImagePipe.Telemetry.default_prefix())
    level = Keyword.get(opts, :level, :info)
    debug? = Keyword.get(opts, :debug, false)

    config = %{prefix: prefix, level: level, debug?: debug?, plen: length(prefix)}

    _ = :telemetry.detach(@handler_id)

    :telemetry.attach_many(
      @handler_id,
      event_names(groups, prefix),
      &__MODULE__.handle_event/4,
      config
    )
  end

  def detach, do: :telemetry.detach(@handler_id)

  defp expand_groups(:all), do: @all_groups
  defp expand_groups(groups) when is_list(groups), do: groups

  defp event_names(groups, prefix) do
    spans =
      groups
      |> Enum.flat_map(&Map.get(@group_span_events, &1, []))
      |> Enum.flat_map(fn e -> [e ++ [:stop], e ++ [:exception]] end)

    request_oneshots = if :request in groups, do: @request_oneshot, else: []
    cache_oneshots = if :cache in groups, do: @cache_oneshot, else: []
    transform_oneshots = if :transform in groups, do: @transform_oneshot, else: []
    output_oneshots = if :output in groups, do: @output_oneshot, else: []
    http_cache_oneshots = if :http_cache in groups, do: @http_cache_oneshot, else: []
    debug_oneshots = if :debug in groups, do: @debug_oneshot, else: []

    Enum.map(
      spans ++
        request_oneshots ++
        cache_oneshots ++
        transform_oneshots ++ output_oneshots ++ http_cache_oneshots ++ debug_oneshots,
      fn e -> prefix ++ e end
    )
  end

  @doc false
  def handle_event(event, measurements, metadata, config) do
    suffix = Enum.drop(event, config.plen)
    level = level_for(suffix, metadata, config.level)

    message =
      if List.last(suffix) == :exception do
        exception_message(suffix, metadata)
      else
        message(suffix, measurements, metadata)
      end

    message =
      case metadata[:pool] do
        nil -> message
        pool -> message <> " (#{pool} pool)"
      end

    Logger.log(level, fn -> message end, log_metadata(event, measurements, metadata))

    if config.debug? do
      Logger.debug(fn ->
        "image_pipe #{label(suffix)} raw: measurements=#{inspect(measurements)} metadata=#{inspect(metadata)}"
      end)
    end

    :ok
  end

  # --- level ---
  defp level_for([:output, :clamp | _], _metadata, _base), do: :warning

  # A best-effort encode-quality search (the objective/budget could not be met
  # within the bracket) degrades the result; surface it, and any search
  # exception, as a warning. A :hit logs at the base level.
  defp level_for([:encode, :search | _] = suffix, metadata, base) do
    cond do
      List.last(suffix) == :exception -> :warning
      metadata[:outcome] == :best_effort -> :warning
      true -> base
    end
  end

  defp level_for([:debug, :collect, :error | _], _metadata, _base), do: :warning

  defp level_for([:cache, :coordination], %{result: result}, _base)
       when result in [:busy, :bypass, :timeout], do: :warning

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
  # (`:unavailable`, `:error`) or a request with no detector configured at all
  # (`:no_detector`, the `[:transform, :detect, :skipped]` one-shot). `:no_regions`
  # (no face in frame) is a normal result, not a warning.
  defp detect_fallback_warning?([:transform, :detect | _], meta),
    do: meta[:result] in [:unavailable, :error, :no_detector]

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

  defp message([:transform, :detect, :skipped | _], _m, _meta),
    do: "image_pipe transform detect: skipped (no detector configured)"

  defp message([:transform, :detect, :blend | _], _m, meta) do
    "image_pipe transform detect blend: attention #{point(meta[:attention])} -> " <>
      "#{point(meta[:blended])} (face #{point(meta[:face])}, weight #{meta[:weight]})"
  end

  defp message([:cache, :lookup | _], _m, meta), do: "image_pipe cache lookup: #{meta[:cache]}"

  defp message([:cache, :write | _], _m, meta) do
    detail =
      case meta[:cache] do
        :write -> "stored"
        :admission_rejected -> "rejected by admission"
        :write_error -> "error"
        other -> inspect(other)
      end

    "image_pipe cache write: #{detail}"
  end

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

    "image_pipe encode search: #{outcome(meta)} (#{scorer}#{meta[:outcome]} " <>
      "q#{meta[:chosen_quality]} #{meta[:chosen_bytes]}b#{score})"
  end

  defp message([:encode, :classify | _], _m, meta) do
    "image_pipe encode classify: #{outcome(meta)} " <>
      "(#{meta[:content_class]} offset #{meta[:applied_offset]})"
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

  defp message([:parse | _], _m, %{sig_key_index: index} = meta),
    do: "image_pipe parse: #{outcome(meta)} (signing key #{index})"

  defp message([:preset, :lookup | _], _m, %{result: :error} = meta),
    do: "image_pipe preset lookup: error (#{meta[:reason]})"

  defp message([:preset, :lookup | _], _m, meta),
    do:
      "image_pipe preset lookup: #{outcome(meta)} (#{meta[:fetched]} fetched, #{meta[:batches]} batches)"

  defp message([:debug, :collect, :error | _], _m, meta),
    do: "image_pipe debug collect: error (#{meta[:error]})"

  defp message(suffix, _m, meta) do
    "image_pipe #{label(suffix)}: #{outcome(meta)}"
  end

  defp cap(:infinity), do: "inf"
  defp cap(value), do: value

  defp exception_message(suffix, meta) do
    "image_pipe #{label(suffix)}: exception (#{meta[:kind]} #{inspect(meta[:reason])})"
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

  defp point({x, y}), do: "(#{round2(x)},#{round2(y)})"
  defp point(_other), do: "(?,?)"

  defp round2(n) when is_number(n), do: Float.round(n * 1.0, 2)
  defp round2(_other), do: nil

  # --- logger metadata ---
  defp log_metadata(event, measurements, metadata) do
    base = [event: event]

    base =
      case measurements[:duration] do
        nil -> base
        native -> [{:duration_us, System.convert_time_unit(native, :native, :microsecond)} | base]
      end

    Keyword.merge(base, Map.to_list(metadata))
  end
end
