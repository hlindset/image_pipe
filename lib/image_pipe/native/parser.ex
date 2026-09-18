defmodule ImagePipe.Native.Parser do
  @moduledoc """
  Segments → validated groups → canonical `%Request{}` for the native URL
  dialect [native §Request semantics].

  `parse/2` consumes Task 4's lexed map (`ImagePipe.Native.Path.extract/1`'s
  success return value) and never touches `Plug.Conn` — `Path` owns all
  raw-path/HTTP concerns.

  Validation runs in five ordered passes, each producing accumulated
  diagnostics (errors are reported together, not just the first):

    1. per-segment — known key, value parse.
    2. groups — split on `then`; empty group (leading/trailing/doubled) is
       an error.
    3. scope/duplicates — group-scoped twice in a group, or request-scoped
       twice anywhere, is an error (every occurrence's span participates).
       Presets then expand into the groups and request-wide options, so
       cross-option validation sees the complete request.
    4. cross-option, over successfully parsed, non-duplicate values only
       (derivative suppression [native §Error diagnostics]) — Tier-3
       exclusive pairs (table-driven via `OptionSpec.conflicts`), Tier-2
       inertness (resize intent, guide consumers, lone/doubled `auto`
       dimensions), and terminal-applicability rejection (table-driven via
       `OptionSpec.terminal_applicability`).
    5. Tier-1 identity canonicalization (`blur=0` → absent) plus semantic-
       default canonicalization (absent `fit`/guide with a consumer present
       canonicalize to their concrete defaults) during final struct
       assembly.

  Diagnostics are `ImagePipe.Native.Diagnostic` structs — `reason`
  atoms are stable, tests match on them.
  """

  alias ImagePipe.Native.Diagnostic
  alias ImagePipe.Native.OptionSpec
  alias ImagePipe.Native.Presets
  alias ImagePipe.Native.Request
  alias ImagePipe.Native.Request.Group
  alias ImagePipe.Native.Request.Output
  alias ImagePipe.Native.Value

  @type span :: Diagnostic.span()
  @type lexed :: %{
          segments: [{String.t(), span()}],
          source: {:src | :src64, String.t(), span()}
        }

  @doc """
  Parses a fully lexed native-dialect path (Task 4's `Path.extract/1`
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
      {:ok,
       assemble_request(
         clean_group_maps,
         clean_request_map,
         decoded_source,
         map_size(clean_group_maps)
       )}
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
    {groups_rev, current_rev, errors_rev, last_then_span, saw_then?} =
      Enum.reduce(segments, {[], [], [], nil, false}, &split_groups_reduce/2)

    groups = Enum.reverse([Enum.reverse(current_rev) | groups_rev])
    errors = Enum.reverse(errors_rev)

    trailing_errors =
      if saw_then? and current_rev == [] do
        [diagnostic(:empty_pipeline_group, last_then_span)]
      else
        []
      end

    {groups, errors ++ trailing_errors}
  end

  defp split_groups_reduce(
         {"then", then_span},
         {groups_rev, current_rev, errors_rev, _last, _saw}
       ) do
    errors_rev =
      if current_rev == [] do
        [diagnostic(:empty_pipeline_group, then_span) | errors_rev]
      else
        errors_rev
      end

    {[Enum.reverse(current_rev) | groups_rev], [], errors_rev, then_span, true}
  end

  defp split_groups_reduce(segment, {groups_rev, current_rev, errors_rev, last_then, saw?}) do
    {groups_rev, [segment | current_rev], errors_rev, last_then, saw?}
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
  # terminal segment (`ImagePipe.Native.Path.extract/1`), so its
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

  # -- pass 4: cross-option validation -------------------------------------

  defp collect_cross_option_errors(clean_group_maps, clean_request_map, occurrences) do
    group_errors =
      Enum.flat_map(clean_group_maps, fn {group_index, group_map} ->
        collect_group_cross_errors(group_map, occurrences, group_index)
      end)

    group_errors ++ collect_terminal_applicability_errors(clean_request_map, occurrences)
  end

  defp collect_group_cross_errors(group_map, occurrences, group_index) do
    tier3_exclusive_errors(group_map, occurrences, group_index) ++
      tier2_group_errors(group_map, occurrences, group_index)
  end

  # Table-driven Tier-3 exclusivity: any two present keys where one's
  # `conflicts` list names the other [native §Scoping and duplicates]. The
  # `key < other` guard reports each symmetric pair once.
  defp tier3_exclusive_errors(group_map, occurrences, group_index) do
    group_map
    |> Map.keys()
    |> Enum.flat_map(fn key ->
      key
      |> OptionSpec.fetch()
      |> Map.fetch!(:conflicts)
      |> Enum.filter(&(Map.has_key?(group_map, &1) and &1 > key))
      |> Enum.map(&exclusive_diagnostic(occurrences, group_index, key, &1))
    end)
  end

  defp exclusive_diagnostic(occurrences, group_index, key_a, key_b) do
    spans = [
      occurrence_span(occurrences, group_index, key_a),
      occurrence_span(occurrences, group_index, key_b)
    ]

    %Diagnostic{
      reason: :mutually_exclusive_options,
      message: "#{key_a} and #{key_b} are mutually exclusive",
      spans: spans
    }
  end

  # Locked probe decisions extending [native §Inertness policy, Tier 2]:
  # resize intent := a concrete (non-auto) w or h; fit/enlarge require it; a
  # lone or doubled auto dimension without a concrete partner is inert; an
  # anchor/focus guide requires a consumer (crop, or a cover-family resize
  # with resize intent).
  defp tier2_group_errors(group_map, occurrences, group_index) do
    resize_intent = resize_intent?(group_map)
    resize_prereq_errored = resize_prereq_errored?(occurrences, group_index)
    guide_consumer = guide_consumer?(group_map, resize_intent)
    guide_prereq_errored = guide_prereq_errored?(occurrences, group_index, resize_prereq_errored)

    resize_dependent_errors(
      group_map,
      occurrences,
      group_index,
      resize_intent,
      resize_prereq_errored
    ) ++
      guide_dependent_errors(
        group_map,
        occurrences,
        group_index,
        guide_consumer,
        guide_prereq_errored
      ) ++
      lone_auto_dimension_errors(group_map, occurrences, group_index, resize_prereq_errored)
  end

  defp resize_dependent_errors(group_map, occurrences, group_index, resize_intent, prereq_errored) do
    resize_requirement = "a concrete (non-auto) w or h"

    inert_if(
      not resize_intent and not prereq_errored and Map.has_key?(group_map, "fit"),
      occurrences,
      group_index,
      "fit",
      resize_requirement
    ) ++
      inert_if(
        not resize_intent and not prereq_errored and Map.has_key?(group_map, "enlarge"),
        occurrences,
        group_index,
        "enlarge",
        resize_requirement
      )
  end

  defp guide_dependent_errors(group_map, occurrences, group_index, guide_consumer, prereq_errored) do
    guide_requirement = "a consumer: crop, or a cover-family resize with a concrete dimension"

    inert_if(
      not guide_consumer and not prereq_errored and Map.has_key?(group_map, "anchor"),
      occurrences,
      group_index,
      "anchor",
      guide_requirement
    ) ++
      inert_if(
        not guide_consumer and not prereq_errored and Map.has_key?(group_map, "focus"),
        occurrences,
        group_index,
        "focus",
        guide_requirement
      )
  end

  # A prerequisite key present in the group but whose value failed to parse
  # (e.g. `w=invalid`) must not also trigger a dependent's inertness
  # diagnostic — the value error already tells the client what's wrong
  # [native §Error diagnostics: derivative suppression]. Presence is judged
  # from the full occurrences list (ok-or-error), not the clean group map,
  # so only a prerequisite key genuinely ABSENT from the group's segments
  # lets the dependent's own inertness check fire.
  defp resize_prereq_errored?(occurrences, group_index) do
    group_key_errored?(occurrences, group_index, "w") or
      group_key_errored?(occurrences, group_index, "h")
  end

  defp guide_prereq_errored?(occurrences, group_index, resize_prereq_errored) do
    resize_prereq_errored or
      group_key_errored?(occurrences, group_index, "crop") or
      group_key_errored?(occurrences, group_index, "fit")
  end

  defp group_key_errored?(occurrences, group_index, key) do
    Enum.any?(
      occurrences,
      &(&1.group_index == group_index and &1.key == key and match?({:error, _}, &1.result))
    )
  end

  defp inert_if(false, _occurrences, _group_index, _key, _requirement), do: []

  defp inert_if(true, occurrences, group_index, key, requirement) do
    span = occurrence_span(occurrences, group_index, key)
    [%Diagnostic{reason: :inert_option, message: "#{key} requires #{requirement}", spans: [span]}]
  end

  defp lone_auto_dimension_errors(group_map, occurrences, group_index, resize_prereq_errored) do
    w = Map.get(group_map, "w")
    h = Map.get(group_map, "h")

    if not resize_prereq_errored and not resize_intent?(group_map) and
         (w == :auto or h == :auto) do
      keys = Enum.reject([w == :auto && "w", h == :auto && "h"], &(&1 in [false, nil]))
      spans = Enum.map(keys, &occurrence_span(occurrences, group_index, &1))

      [
        %Diagnostic{
          reason: :inert_option,
          message: "auto dimension has no concrete partner",
          spans: spans
        }
      ]
    else
      []
    end
  end

  defp collect_terminal_applicability_errors(clean_request_map, occurrences) do
    terminal = Map.get(clean_request_map, "output", :image)

    clean_request_map
    |> Enum.filter(fn {key, _value} ->
      spec = OptionSpec.fetch(key)
      spec.terminal_applicability != :both and spec.terminal_applicability != terminal
    end)
    |> Enum.map(fn {key, _value} ->
      span = request_occurrence_span(occurrences, key)

      %Diagnostic{
        reason: :inert_option,
        message: "#{key} is inert for output=#{terminal}",
        spans: [span]
      }
    end)
  end

  defp resize_intent?(group_map) do
    concrete_dimension?(Map.get(group_map, "w")) or concrete_dimension?(Map.get(group_map, "h"))
  end

  defp concrete_dimension?(n) when is_integer(n), do: true
  defp concrete_dimension?(_not_concrete), do: false

  defp guide_consumer?(group_map, resize_intent?) do
    Map.has_key?(group_map, "crop") or
      (resize_intent? and Map.get(group_map, "fit") in [:cover, :cover_down, :auto])
  end

  # -- pass 5: canonicalization + assembly ---------------------------------

  defp assemble_request(clean_group_maps, clean_request_map, source, group_count) do
    groups =
      for group_index <- 0..(group_count - 1), do: assemble_group(clean_group_maps[group_index])

    %Request{
      groups: groups,
      output: assemble_output(clean_request_map),
      source: source,
      expires: Map.get(clean_request_map, "expires")
    }
  end

  defp assemble_group(group_map) do
    resize = assemble_resize(group_map)

    %Group{
      rotate: assemble_rotation(Map.get(group_map, "rotate", 0)),
      gray: Map.get(group_map, "gray", false),
      bitonal: Map.get(group_map, "bitonal", false),
      trim: assemble_trim(Map.get(group_map, "trim")),
      region: Map.get(group_map, "region"),
      crop: Map.get(group_map, "crop"),
      guide: assemble_guide(group_map, resize != nil),
      resize: resize,
      blur: assemble_blur(Map.get(group_map, "blur")),
      pad: Map.get(group_map, "pad"),
      bg: assemble_bg(Map.get(group_map, "bg"))
    }
  end

  defp assemble_rotation(0), do: nil
  defp assemble_rotation(angle), do: angle

  defp assemble_resize(group_map) do
    if resize_intent?(group_map) do
      %{
        w: Map.get(group_map, "w", :auto),
        h: Map.get(group_map, "h", :auto),
        fit: Map.get(group_map, "fit", :contain),
        enlarge: Map.get(group_map, "enlarge", false)
      }
    end
  end

  # A single anchor/focus deliberately guides both an explicit guided crop
  # and the result crop of a cover-family resize [native §Geometry
  # semantics]; absent guide with a consumer present canonicalizes to the
  # concrete default (`anchor=center`) rather than staying nil.
  defp assemble_guide(group_map, resize_intent?) do
    cond do
      Map.has_key?(group_map, "anchor") ->
        case Map.fetch!(group_map, "anchor") do
          :smart -> {:anchor_smart}
          anchor -> {:anchor, anchor}
        end

      Map.has_key?(group_map, "focus") ->
        {fx, fy} = Map.fetch!(group_map, "focus")
        {:focus, fx, fy}

      guide_consumer?(group_map, resize_intent?) ->
        {:anchor, :center}

      true ->
        nil
    end
  end

  defp assemble_trim(nil), do: nil
  defp assemble_trim(:auto), do: :auto
  # An omitted tolerance defaults to 10 — matching imgproxy's TrimThreshold
  # default (and libvips find_trim), and `trim=auto`'s @default_trim_threshold.
  # Integer 10 (not 10.0) so `trim=fff` canonicalizes identically to the
  # explicit `trim=fff,10` (Value.number yields an integer), preserving
  # cache-key transparency across the two spellings.
  defp assemble_trim({color, nil}), do: {color, 10}
  defp assemble_trim({color, tolerance}), do: {color, tolerance}

  # Tier-1 identity canonicalization: blur=0 (the identity sigma) is
  # equivalent to blur being absent [native §Inertness policy, Tier 1].
  defp assemble_blur(nil), do: nil
  defp assemble_blur(sigma) when sigma == 0.0, do: nil
  defp assemble_blur(sigma), do: sigma

  defp assemble_bg(nil), do: nil
  defp assemble_bg({{r, g, b}, nil}), do: {r, g, b, 1.0}
  defp assemble_bg({{r, g, b}, alpha}), do: {r, g, b, alpha}

  defp assemble_output(clean_request_map) do
    %Output{
      terminal: Map.get(clean_request_map, "output", :image),
      format: Map.get(clean_request_map, "format"),
      quality: Map.get(clean_request_map, "q")
    }
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
  The central wording table for every `reason` a `Diagnostic` this module
  (or `ImagePipe.Native.Path`'s sibling table) produces — public
  so a diagnostic built outside `Parser` (e.g.
  `ImagePipe.Native.Presets`'s `:unknown_preset`, which carries a
  request-supplied name the table itself can't embed) still sources its
  static wording from here rather than duplicating it.
  """
  @spec message_for(atom()) :: String.t()
  def message_for(:empty_pipeline_group), do: "empty pipeline group"
  def message_for(:unknown_option), do: "unknown option"
  def message_for(:missing_value), do: "missing value"
  def message_for(:duplicate_option), do: "duplicate option"
  def message_for(:empty_segment), do: "empty option segment"
  def message_for(:invalid_dimension), do: "invalid value: expected px or `auto`"

  def message_for(:invalid_fit),
    do: "invalid value: expected contain, cover, cover-down, stretch, or auto"

  def message_for(:invalid_arity),
    do: "invalid value: wrong number of comma-separated elements"

  def message_for(:invalid_element), do: "invalid value: one or more elements are invalid"
  def message_for(:invalid_anchor), do: "invalid value: expected a named anchor position"
  def message_for(:invalid_blur), do: "invalid value: expected a non-negative number"
  def message_for(:invalid_rotation), do: "invalid value: expected degrees from 0 to 360"

  def message_for(:invalid_pad_shorthand),
    do: "invalid value: expected 1-4 comma-separated px values"

  def message_for(:invalid_output), do: "invalid value: expected image or blurhash"

  def message_for(:invalid_format),
    do: "invalid value: expected avif, webp, jpeg, png, or jxl"

  def message_for(:invalid_quality), do: "invalid value: expected an integer 1-100"
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
