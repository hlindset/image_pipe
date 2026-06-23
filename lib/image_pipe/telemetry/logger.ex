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
      [:send],
      [:encode],
      [:encode, :search],
      [:encode, :search, :probe],
      [:encode, :classify],
      [:deliver],
      [:render]
    ],
    parse: [[:parse]],
    source: [[:source, :resolve], [:source, :fetch], [:source, :fetch_decode]],
    transform: [
      [:transform, :execute],
      [:transform, :input_color_management],
      [:transform, :operation],
      [:transform, :materialize],
      [:transform, :detect],
      [:transform, :detect, :model]
    ],
    cache: [[:cache, :lookup], [:cache, :write], [:cache, :admission], [:cache, :warm_start]],
    output: [[:output, :negotiate]],
    http_cache: []
  }

  # request one-shot events (already terminal; not spans)
  @request_oneshot [
    [:encode, :search, :probe, :chosen]
  ]

  # cache one-shot events (already terminal; not spans)
  @cache_oneshot [
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

    Enum.map(
      spans ++
        request_oneshots ++
        cache_oneshots ++
        transform_oneshots ++ output_oneshots ++ http_cache_oneshots,
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
  # exception, as a warning. Other outcomes (:hit, :skipped) log at the base level.
  defp level_for([:encode, :search | _] = suffix, metadata, base) do
    cond do
      List.last(suffix) == :exception -> :warning
      metadata[:outcome] == :best_effort -> :warning
      true -> base
    end
  end

  defp level_for(suffix, metadata, base) do
    if stage_warning?(suffix, metadata), do: :warning, else: base
  end

  defp stage_warning?(suffix, metadata) do
    List.last(suffix) == :exception or
      metadata[:result] in [:cache_error, :materialize_error] or
      encode_failure?(suffix, metadata) or
      color_management_failure?(suffix, metadata) or
      detect_fallback_warning?(suffix, metadata) or
      render_failure?(suffix, metadata) or
      negotiate_failure?(suffix, metadata)
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

  # A render that failed (decode/source/render error) → escalate to :warning,
  # analogous to encode_failure?.
  defp render_failure?([:render | _], meta), do: meta[:result] == :render_error
  defp render_failure?(_suffix, _meta), do: false

  # Output negotiation that could not resolve a deliverable format → escalate to
  # :warning, analogous to render_failure?. The `:ok` outcome stays at base level.
  defp negotiate_failure?([:output, :negotiate | _], meta), do: meta[:result] not in [:ok, nil]
  defp negotiate_failure?(_suffix, _meta), do: false

  # --- message ---
  defp message([:transform, :operation | _], _m, meta) do
    "image_pipe transform: #{meta[:operation]} (##{(meta[:index] || 0) + 1})"
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

  defp message([:render | _], _m, meta) do
    ct = if meta[:content_type], do: " (#{meta[:content_type]})", else: ""
    "image_pipe render: #{outcome(meta)}#{ct}"
  end

  defp message([:output, :negotiate | _], _m, meta) do
    format = if meta[:output_format], do: " (#{meta[:output_format]})", else: ""
    "image_pipe output negotiate: #{outcome(meta)}#{format}"
  end

  defp message([:transform, :detect, :model | _], _m, meta) do
    "image_pipe transform detect model: #{meta[:regions]} regions (#{inspect(meta[:detector])})"
  end

  defp message([:http_cache, :prepare | _], _m, meta) do
    "image_pipe http_cache prepare: #{meta[:effective_mode]} " <>
      "(byte_identity #{meta[:byte_identity]}, etag #{meta[:etag]})"
  end

  defp message([:http_cache, :conditional, :match | _], _m, meta) do
    "image_pipe http_cache conditional match: #{meta[:method]}"
  end

  defp message([:http_cache, :fallback, :no_store | _], _m, meta) do
    "image_pipe http_cache fallback no_store: #{meta[:reason]} (#{meta[:source_kind]})"
  end

  defp message([:http_cache, :cache_hit, :headers | _], _m, meta) do
    "image_pipe http_cache cache_hit headers: etag #{meta[:etag]} " <>
      "(generated #{meta[:generated_cache_headers]}, representation #{meta[:representation_headers]})"
  end

  defp message([:source, :fetch_decode | _], _m, meta) do
    case meta[:detected_source_format] do
      nil ->
        "image_pipe source fetch_decode: #{outcome(meta)}"

      detected ->
        "image_pipe source fetch_decode: #{outcome(meta)} (detected #{detected}#{resolution_note(meta)})"
    end
  end

  defp message(suffix, _m, meta) do
    "image_pipe #{label(suffix)}: #{outcome(meta)}"
  end

  defp cap(:infinity), do: "inf"
  defp cap(value), do: value

  defp exception_message(suffix, meta) do
    "image_pipe #{label(suffix)}: exception (#{meta[:kind]} #{inspect(meta[:reason])})"
  end

  defp outcome(meta), do: meta[:cache] || meta[:result] || :ok

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
