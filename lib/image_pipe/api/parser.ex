defmodule ImagePipe.API.Parser do
  @moduledoc """
  Parses URL segments into a validated, canonical `%Request{}`.

  `parse/2` consumes the lexed map from `ImagePipe.API.Path.extract/1`.
  `Path` owns raw-path and HTTP handling.

  Validation accumulates diagnostics in five passes:

    1. Parse each option key and value.
    2. Split groups on `-`; reject leading, trailing, or consecutive separators.
    3. Reject duplicate group options within a group and request options anywhere,
       marking every occurrence. Then expand presets.
    4. Check conflicts, inert options, and output applicability using only valid,
       non-duplicate values, to avoid errors caused by earlier failures.
    5. Translate into typed intent for `Plan.Request.build/3`, which removes
       identity values and resolves omitted fit/guide defaults.

  Diagnostics are `ImagePipe.API.Diagnostic` structs with stable `reason` atoms.
  """

  alias ImagePipe.API.Diagnostic
  alias ImagePipe.API.OptionSpec
  alias ImagePipe.API.Presets
  alias ImagePipe.API.Value
  alias ImagePipe.Plan.Request

  @intent_keys Map.new(for spec <- OptionSpec.all(), spec.name != nil, do: {spec.key, spec.name})

  @url_keys Map.new(@intent_keys, fn {key, name} -> {name, key} end)

  @type span :: Diagnostic.span()
  @type lexed :: %{
          segments: [{String.t(), span()}],
          source: {:src | :src64 | :enc, String.t(), span()}
        }

  @doc """
  Parses a fully lexed request path (`ImagePipe.API.Path.extract/1`'s
  success value) into a canonical `%Request{}`.
  """
  @spec parse(lexed(), keyword()) ::
          {:ok, Request.t()} | {:error, {:invalid_request, [Diagnostic.t()]}}
  def parse(%{segments: segments, source: {_marker, decoded_source, source_span}}, config) do
    {parsed, occurrences, parse_errors} = parse_options(segments)
    whole_path_span = whole_path_span(source_span)

    {clean_group_maps, clean_request_map, preset_errors, occurrences_for_cross} =
      expand_presets(parsed.groups, parsed.request, occurrences, config, whole_path_span)

    cross_errors =
      collect_cross_option_errors(clean_group_maps, clean_request_map, occurrences_for_cross)

    errors = parse_errors ++ preset_errors ++ cross_errors

    if errors == [] do
      {:ok, build_request(clean_group_maps, clean_request_map, decoded_source)}
    else
      {:error, {:invalid_request, errors}}
    end
  end

  @doc false
  @spec parse_preset(String.t()) :: {:ok, map()} | {:error, [Diagnostic.t()]}
  def parse_preset(fragment) do
    case fragment |> fragment_segments() |> parse_options() do
      {parsed, _occurrences, []} -> {:ok, parsed}
      {_parsed, _occurrences, errors} -> {:error, errors}
    end
  end

  defp parse_options(segments) do
    {groups, structure_errors} = split_groups(segments)

    occurrences =
      groups
      |> Enum.with_index()
      |> Enum.flat_map(fn {segments, index} ->
        Enum.map(segments, &classify_segment(&1, index))
      end)

    errors =
      structure_errors ++
        collect_segment_errors(occurrences) ++
        collect_duplicate_errors(occurrences, length(groups))

    parsed = %{
      groups: build_clean_group_maps(occurrences, length(groups)),
      request: build_clean_request_map(occurrences)
    }

    {parsed, occurrences, errors}
  end

  # -- pass 2: group splitting -------------------------------------------

  defp split_groups(segments) do
    {groups_rev, current_rev, errors_rev, last_separator_span, saw_separator?} =
      Enum.reduce(segments, {[], [], [], nil, false}, &split_groups_reduce/2)

    groups = Enum.reverse([Enum.reverse(current_rev) | groups_rev])
    errors = Enum.reverse(errors_rev)

    trailing_errors =
      if saw_separator? and current_rev == [] do
        [diagnostic(:empty_pipeline_group, last_separator_span)]
      else
        []
      end

    {groups, errors ++ trailing_errors}
  end

  defp split_groups_reduce(
         {"-", separator_span},
         {groups_rev, current_rev, errors_rev, _last, _saw}
       ) do
    errors_rev =
      if current_rev == [] do
        [diagnostic(:empty_pipeline_group, separator_span) | errors_rev]
      else
        errors_rev
      end

    {[Enum.reverse(current_rev) | groups_rev], [], errors_rev, separator_span, true}
  end

  defp split_groups_reduce(segment, {groups_rev, current_rev, errors_rev, last_separator, saw?}) do
    {groups_rev, [segment | current_rev], errors_rev, last_separator, saw?}
  end

  # -- pass 1: per-segment key lookup + value dispatch --------------------

  defp classify_segment({raw, span}, group_index) do
    {key, value_part} = split_key_value(raw)
    key_span = {elem(span, 0), byte_size(key)}
    val_span = value_span(span, key, value_part)

    case OptionSpec.fetch(key) do
      nil ->
        occurrence(group_index, key, nil, span, key_span, val_span, {:error, :unknown_option})

      spec ->
        occurrence(
          group_index,
          key,
          spec,
          span,
          key_span,
          val_span,
          dispatch_value(spec, value_part)
        )
    end
  end

  defp split_key_value(raw) do
    case String.split(raw, "=", parts: 2) do
      [key] -> {key, nil}
      [key, value] -> {key, value}
    end
  end

  defp value_span({offset, _len}, key, nil), do: {offset, byte_size(key)}
  defp value_span({offset, _len}, key, value), do: {offset + byte_size(key) + 1, byte_size(value)}

  defp dispatch_value(%OptionSpec{value: :flag}, nil), do: {:ok, true}
  defp dispatch_value(%OptionSpec{value: :flag}, value), do: Value.flag(value)
  defp dispatch_value(%OptionSpec{}, nil), do: {:error, :missing_value}
  defp dispatch_value(%OptionSpec{value: fun}, value), do: fun.(value)

  defp occurrence(group_index, key, spec, span, key_span, value_span, result) do
    %{
      group_index: group_index,
      key: key,
      spec: spec,
      span: span,
      key_span: key_span,
      value_span: value_span,
      result: result
    }
  end

  defp collect_segment_errors(occurrences) do
    occurrences
    |> Enum.filter(&match?(%{result: {:error, _}}, &1))
    |> Enum.map(&segment_diagnostic/1)
  end

  defp segment_diagnostic(%{spec: nil, key_span: key_span}) do
    diagnostic(:unknown_option, key_span)
  end

  defp segment_diagnostic(%{result: {:error, :missing_value}, key_span: key_span}) do
    diagnostic(:missing_value, key_span)
  end

  defp segment_diagnostic(%{result: {:error, reason}, value_span: value_span}) do
    diagnostic(reason, value_span)
  end

  # -- pass 3: scope/duplicate validation ----------------------------------

  defp collect_duplicate_errors(occurrences, group_count) do
    known = Enum.filter(occurrences, &(&1.spec != nil))

    # group_count is always >= 1 (split_groups never returns an empty list).
    group_scoped_dupes =
      0..(group_count - 1)
      |> Enum.flat_map(fn group_index ->
        known
        |> Enum.filter(&(&1.group_index == group_index and &1.spec.scope == :group))
        |> duplicate_diagnostics()
      end)

    request_scoped_dupes =
      known
      |> Enum.filter(&(&1.spec.scope == :request))
      |> duplicate_diagnostics()

    group_scoped_dupes ++ request_scoped_dupes
  end

  defp duplicate_diagnostics(occs) do
    occs
    |> Enum.group_by(& &1.key)
    |> Enum.filter(fn {_key, list} -> length(list) > 1 end)
    |> Enum.map(fn {_key, list} ->
      %Diagnostic{
        reason: :duplicate_option,
        message: message_for(:duplicate_option),
        spans: Enum.map(list, & &1.span)
      }
    end)
  end

  # -- clean (successfully-parsed, non-duplicate) value maps --------------

  defp build_clean_group_maps(occurrences, group_count) do
    known_ok =
      Enum.filter(
        occurrences,
        &(&1.spec != nil and match?({:ok, _}, &1.result) and &1.spec.scope == :group)
      )

    duplicated =
      known_ok
      |> Enum.group_by(&{&1.group_index, &1.key})
      |> Enum.filter(fn {_k, v} -> length(v) > 1 end)
      |> Enum.map(fn {k, _v} -> k end)
      |> MapSet.new()

    for group_index <- 0..(group_count - 1), into: %{} do
      group_map =
        known_ok
        |> Enum.filter(
          &(&1.group_index == group_index and
              not MapSet.member?(duplicated, {group_index, &1.key}))
        )
        |> Map.new(&{&1.key, elem(&1.result, 1)})

      {group_index, group_map}
    end
  end

  defp build_clean_request_map(occurrences) do
    known_ok =
      Enum.filter(
        occurrences,
        &(&1.spec != nil and match?({:ok, _}, &1.result) and &1.spec.scope == :request)
      )

    duplicated =
      known_ok
      |> Enum.group_by(& &1.key)
      |> Enum.filter(fn {_k, v} -> length(v) > 1 end)
      |> Enum.map(fn {k, _v} -> k end)
      |> MapSet.new()

    known_ok
    |> Enum.reject(&MapSet.member?(duplicated, &1.key))
    |> Map.new(&{&1.key, elem(&1.result, 1)})
  end

  defp occurrence_span(occurrences, group_index, key) do
    occurrences
    |> Enum.find(&(&1.group_index == group_index and &1.key == key))
    |> case do
      nil -> nil
      occ -> occ.span
    end
  end

  defp request_occurrence_span(occurrences, key) do
    occurrences
    |> Enum.find(&(&1.key == key))
    |> case do
      nil -> nil
      occ -> occ.span
    end
  end

  # The mount-relative raw path's own span, `{0, byte_size(raw_path)}`,
  # derived from the lexed source's span — `src`/`src64` is always the
  # terminal segment (`ImagePipe.API.Path.extract/1`), so its
  # offset plus its (pre-decode) length equals the whole raw path's byte
  # length.
  defp whole_path_span({source_offset, source_len}), do: {0, source_offset + source_len}

  defp expand_presets(clean_group_maps, clean_request_map, occurrences, config, whole_path_span) do
    presets_config = Keyword.get(config, :presets, %{})
    preset_span = request_occurrence_span(occurrences, "preset") || whole_path_span

    {groups, request, diagnostics} =
      Presets.expand(clean_group_maps, clean_request_map, presets_config, preset_span)

    # Explicit occurrences stay first, so diagnostics use the original URL
    # spans where possible. Preset contributions point to the preset name.
    synthetic =
      Enum.flat_map(groups, fn {index, options} ->
        Enum.map(Map.keys(options), &preset_occurrence(index, &1, preset_span))
      end) ++ Enum.map(Map.keys(request), &preset_occurrence(0, &1, preset_span))

    {groups, request, diagnostics, occurrences ++ synthetic}
  end

  defp preset_occurrence(index, key, span),
    do: occurrence(index, key, nil, span, span, span, {:ok, :from_preset})

  # -- semantic validation and URL diagnostics -----------------------------

  defp collect_cross_option_errors(group_maps, request_map, occurrences) do
    invalid =
      for %{group_index: index, key: key, result: {:error, _}} <- occurrences,
          {:ok, name} <- [Map.fetch(@intent_keys, key)],
          into: MapSet.new(),
          do: {:group, index, name}

    group_maps
    |> typed_groups()
    |> Request.errors(typed_options(request_map), invalid)
    |> Enum.map(&semantic_diagnostic(&1, occurrences))
  end

  defp semantic_diagnostic(issue, occurrences) do
    spans = Enum.map(issue.locations, &semantic_span(&1, occurrences))
    %Diagnostic{reason: issue.reason, message: semantic_message(issue), spans: spans}
  end

  defp semantic_span({:group, index, key}, occurrences),
    do: occurrence_span(occurrences, index, Map.fetch!(@url_keys, key))

  defp semantic_span({:request, key}, occurrences),
    do: request_occurrence_span(occurrences, Map.fetch!(@url_keys, key))

  defp semantic_message(%{detail: :exclusive, locations: locations}) do
    [left, right] = Enum.map(locations, &location_key/1)
    "#{left} and #{right} are mutually exclusive"
  end

  defp semantic_message(%{detail: :quality_search}),
    do: "q and enabled autoquality are mutually exclusive"

  defp semantic_message(%{detail: :auto_dimension}),
    do: "auto dimension has no concrete partner"

  defp semantic_message(%{detail: :invalid_offset}), do: message_for(:invalid_offset)

  defp semantic_message(%{detail: {:terminal, terminal}, locations: [location]}) do
    terminal = terminal |> Atom.to_string() |> String.replace("_", "-")
    "#{location_key(location)} is inert for output=#{terminal}"
  end

  defp semantic_message(%{detail: {:requires, requirement}, locations: [location]}),
    do: "#{location_key(location)} requires #{requirement_message(requirement)}"

  defp location_key({:group, _index, key}), do: Map.fetch!(@url_keys, key)
  defp location_key({:request, key}), do: Map.fetch!(@url_keys, key)

  defp requirement_message(:resize), do: "a concrete (non-auto) w or h, min-w, or min-h"

  defp requirement_message(:guide),
    do: "a consumer: crop, or a cover-family resize with a concrete dimension"

  defp requirement_message(:crop), do: "crop"
  defp requirement_message(:crop_ratio), do: "crop-ratio"
  defp requirement_message(:trim), do: "trim"
  defp requirement_message(:box), do: "concrete (non-auto) w and h"
  defp requirement_message(:canvas), do: "extend or extend-ratio"
  defp requirement_message(:named_anchor), do: "an explicit non-smart anchor"
  defp requirement_message(:quality_format), do: "a quality-bearing output format"
  defp requirement_message({:format, format}), do: "format=#{format}"

  defp build_request(group_maps, request_map, source),
    do: Request.build(typed_groups(group_maps), typed_options(request_map), source)

  defp typed_groups(group_maps) do
    group_maps
    |> Enum.sort_by(&elem(&1, 0))
    |> Enum.map(fn {_index, options} -> typed_options(options) end)
  end

  defp typed_options(options) do
    options
    |> Map.delete("preset")
    |> Map.new(fn {key, value} -> {Map.fetch!(@intent_keys, key), value} end)
  end

  defp fragment_segments(fragment) do
    {_offset, segments_rev} =
      fragment
      |> String.split("/")
      |> Enum.reduce({0, []}, fn part, {offset, acc} ->
        {offset + byte_size(part) + 1, [{part, {offset, byte_size(part)}} | acc]}
      end)

    Enum.reverse(segments_rev)
  end

  # -- diagnostics ----------------------------------------------------------

  defp diagnostic(reason, span) do
    %Diagnostic{reason: reason, message: message_for(reason), spans: [span]}
  end

  @doc """
  Returns shared diagnostic wording for `reason`.

  Other producers, such as `ImagePipe.API.Presets`, use this table before
  appending request-specific details such as an unknown preset's name.
  """
  @spec message_for(atom()) :: String.t()
  def message_for(:empty_pipeline_group), do: "empty pipeline group"
  def message_for(:unknown_option), do: "unknown option"
  def message_for(:missing_value), do: "missing value"
  def message_for(:duplicate_option), do: "duplicate option"
  def message_for(:empty_segment), do: "empty option segment"
  def message_for(:invalid_dimension), do: "invalid value: expected px or `auto`"
  def message_for(:invalid_min_dimension), do: "invalid value: expected positive integer px"
  def message_for(:invalid_dpr), do: "invalid value: expected a positive finite decimal"
  def message_for(:invalid_zoom), do: "invalid value: expected a positive scalar or x,y pair"
  def message_for(:invalid_crop_ratio), do: "invalid value: expected a positive a:b or decimal"
  def message_for(:invalid_offset), do: "invalid value: expected a signed x,y px or pct pair"

  def message_for(:invalid_detect),
    do: "invalid value: expected unique class[:positive-weight] items"

  def message_for(:invalid_trim_symmetry),
    do: "invalid value: expected h, v, or hv"

  def message_for(:invalid_fit),
    do: "invalid value: expected contain, cover, cover-down, stretch, or auto"

  def message_for(:invalid_arity),
    do: "invalid value: wrong number of comma-separated elements"

  def message_for(:invalid_element), do: "invalid value: one or more elements are invalid"
  def message_for(:invalid_anchor), do: "invalid value: expected a named anchor position"
  def message_for(:invalid_blur), do: "invalid value: expected a non-negative number"
  def message_for(:invalid_sharpen), do: "invalid value: expected a non-negative finite number"
  def message_for(:invalid_pixelate), do: "invalid value: expected a positive integer"

  def message_for(:invalid_monochrome),
    do: "invalid value: expected intensity[,color]"

  def message_for(:invalid_duotone),
    do: "invalid value: expected intensity or intensity,shadow,highlight"

  def message_for(:invalid_brightness), do: "invalid value: expected an integer from -255 to 255"
  def message_for(:invalid_contrast), do: "invalid value: expected a positive finite factor"
  def message_for(:invalid_saturation), do: "invalid value: expected a positive finite factor"

  def message_for(:invalid_colorize),
    do: "invalid value: expected opacity,color[,keep-alpha]"

  def message_for(:invalid_gradient),
    do: "invalid value: expected opacity,color[,direction,start,stop]"

  def message_for(:invalid_rotation), do: "invalid value: expected degrees from 0 to 360"
  def message_for(:invalid_flip), do: "invalid value: expected h, v, or hv"

  def message_for(:invalid_pad_shorthand),
    do: "invalid value: expected 1-4 comma-separated px values"

  def message_for(:invalid_output),
    do: "invalid value: expected image, blurhash, lqip-css, or info"

  def message_for(:invalid_orientation), do: "invalid value: expected auto or none"
  def message_for(:invalid_filename), do: "invalid value: expected [A-Za-z0-9._-]+"
  def message_for(:invalid_cachebuster), do: "invalid value: expected [A-Za-z0-9._-]+"

  def message_for(:invalid_format),
    do: "invalid value: expected avif, webp, jpeg, or png"

  def message_for(:invalid_quality), do: "invalid value: expected an integer 1-100"
  def message_for(:invalid_metadata), do: "invalid value: expected strip, copyright, or keep"

  def message_for(:invalid_color_profile),
    do: "invalid value: expected strip, preserve, srgb, display-p3, or adobe-rgb"

  def message_for(:invalid_hdr), do: "invalid value: expected tonemap or preserve"
  def message_for(:invalid_format_qualities), do: "invalid per-format quality list"
  def message_for(:invalid_autoquality), do: "invalid autoquality method or named fields"
  def message_for(:invalid_max_bytes), do: "invalid value: expected a positive integer"
  def message_for(:invalid_encoder_options), do: "invalid encoder option list"
  def message_for(:invalid_expires), do: "invalid value: expected a positive unix timestamp"

  def message_for(:invalid_preset_name),
    do: "invalid value: expected names matching [A-Za-z0-9._-]+"

  # `Presets.expand/4` appends the offending name itself (request data this
  # static table can't hold) to build the full message.
  def message_for(:unknown_preset), do: "unknown preset"

  def message_for(:conflicting_preset_pipeline),
    do: "a pipeline preset cannot combine with explicit group options or another pipeline preset"

  def message_for(:true_spelled_bare),
    do: "invalid value: write the bare flag instead of key=true"

  def message_for(:invalid_flag),
    do: "invalid value: expected false (or the bare flag for true)"
end
