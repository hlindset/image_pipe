defmodule ImagePipe.Dialect.Native.Parser do
  @moduledoc """
  Segments → validated groups → canonical `%Request{}` for the native URL
  dialect [native §Request semantics].

  `parse/2` consumes Task 4's lexed map (`ImagePipe.Dialect.Native.Path.extract/1`'s
  success return value) and never touches `Plug.Conn` — `Path` owns all
  raw-path/HTTP concerns.

  Validation runs in five ordered passes, each producing accumulated
  diagnostics (errors are reported together, not just the first):

    1. per-segment — known key, value parse.
    2. groups — split on `then`; empty group (leading/trailing/doubled) is
       an error.
    3. scope/duplicates — group-scoped twice in a group, or request-scoped
       twice anywhere, is an error (every occurrence's span participates).
       Immediately after this pass, group 0's clean map is expanded with
       any configured presets (`ImagePipe.Dialect.Native.Presets.expand/4`
       [native §Presets, trimmed to probe]) — before pass 4 runs, so
       cross-option validation sees the merged group, not just the URL's
       own explicit segments.
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

  Diagnostics are `ImagePipe.Dialect.Native.Diagnostic` structs — `reason`
  atoms are stable, tests match on them.
  """

  alias ImagePipe.Dialect.Native.Diagnostic
  alias ImagePipe.Dialect.Native.OptionSpec
  alias ImagePipe.Dialect.Native.Presets
  alias ImagePipe.Dialect.Native.Request
  alias ImagePipe.Dialect.Native.Request.Group
  alias ImagePipe.Dialect.Native.Request.Output
  alias ImagePipe.Dialect.Native.Value

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
    {groups_raw, group_structure_errors} = split_groups(segments)
    group_count = length(groups_raw)

    occurrences =
      groups_raw
      |> Enum.with_index()
      |> Enum.flat_map(fn {group_segments, group_index} ->
        Enum.map(group_segments, &classify_segment(&1, group_index))
      end)

    segment_errors = collect_segment_errors(occurrences)
    duplicate_errors = collect_duplicate_errors(occurrences, group_count)
    clean_group_maps = build_clean_group_maps(occurrences, group_count)
    clean_request_map = build_clean_request_map(occurrences)
    whole_path_span = whole_path_span(source_span)

    {clean_group_maps, preset_errors, occurrences_for_cross} =
      expand_presets(clean_group_maps, clean_request_map, occurrences, config, whole_path_span)

    cross_errors =
      collect_cross_option_errors(clean_group_maps, clean_request_map, occurrences_for_cross)

    errors =
      group_structure_errors ++
        segment_errors ++ duplicate_errors ++ preset_errors ++ cross_errors

    if errors == [] do
      {:ok, assemble_request(clean_group_maps, clean_request_map, decoded_source, group_count)}
    else
      {:error, {:invalid_request, errors}}
    end
  end

  @doc """
  Parses ONE source-free, `then`-free, group-scoped-only option group from a
  raw fragment string, over the same segment/value machinery `parse/2`
  uses. A request-scoped key in a fragment is an error, not silently
  accepted — this surface is deliberately narrower than `parse/2` and does
  not run cross-option (pass 4) or canonicalization (pass 5); callers that
  need a full request (Task 7's preset expansion) merge fragment results
  into the same segment stream `parse/2` validates.

  Returns the same "clean map" shape (`%{key_string => parsed_value}`)
  `parse/2` builds internally per group.
  """
  @spec parse_option_fragment(String.t(), keyword()) ::
          {:ok, %{optional(String.t()) => term()}} | {:error, [Diagnostic.t()]}
  def parse_option_fragment(fragment, _config) when is_binary(fragment) do
    occurrences = fragment |> fragment_segments() |> Enum.map(&classify_fragment_segment/1)
    errors = collect_fragment_errors(occurrences)

    if errors == [] do
      {:ok, Map.new(occurrences, fn occ -> {occ.key, elem(occ.result, 1)} end)}
    else
      {:error, errors}
    end
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
  # terminal segment (`ImagePipe.Dialect.Native.Path.extract/1`), so its
  # offset plus its (pre-decode) length equals the whole raw path's byte
  # length.
  defp whole_path_span({source_offset, source_len}), do: {0, source_offset + source_len}

  # -- preset expansion (Task 7) -------------------------------------------
  #
  # Runs after pass 3 (scope/duplicates) and before pass 4 (cross-option),
  # so cross-option validation judges the *merged* group 0, not just the
  # URL's own explicit segments — a preset alone need not satisfy tier-2
  # prerequisites (e.g. `fit=cover` with no dimension), only the group it
  # ends up contributing to. Expansion applies only to group 0: a preset's
  # fragment carries no `then`, so it can only ever hold one group's worth
  # of options (multi-group presets are out of scope for this probe).

  defp expand_presets(clean_group_maps, clean_request_map, occurrences, config, whole_path_span) do
    presets_config = Keyword.get(config, :presets, %{})
    preset_names = Map.get(clean_request_map, "preset", [])
    group0_map = Map.get(clean_group_maps, 0, %{})
    preset_span = request_occurrence_span(occurrences, "preset") || whole_path_span

    case Presets.expand(group0_map, preset_names, presets_config, preset_span) do
      {^group0_map, []} ->
        {clean_group_maps, [], occurrences}

      {merged_map, []} ->
        synthetic = synthetic_preset_occurrences(merged_map, group0_map, preset_span)
        {Map.put(clean_group_maps, 0, merged_map), [], occurrences ++ synthetic}

      {_unchanged_map, diagnostics} ->
        {clean_group_maps, diagnostics, occurrences}
    end
  end

  # A key contributed purely by a preset (not present in the URL's own
  # explicit group map) has no real segment for pass 4's span lookups
  # (`occurrence_span/3`) to find — a synthetic occurrence, anchored at the
  # URL's `preset=` segment (or, when the URL has no `preset=` segment at
  # all — a `default` preset applied with nothing naming it — at the whole
  # raw path, `whole_path_span/1`), lets a cross-option diagnostic about
  # that key (e.g. tier-2 inertness) still carry a real, non-empty span
  # instead of crashing, going spanless, or degrading to a zero-length
  # `{0, 0}` caret. `spec: nil` and the ok-tagged dummy result are inert to
  # every pass-4 helper: they only ever read `group_index`/`key`/`span`, or
  # `result` solely to detect a *failed* segment (never true here).
  defp synthetic_preset_occurrences(merged_map, explicit_map, span) do
    merged_map
    |> Map.keys()
    |> Enum.reject(&Map.has_key?(explicit_map, &1))
    |> Enum.map(&occurrence(0, &1, nil, span, span, span, {:ok, :from_preset}))
  end

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
  defp assemble_trim({color, nil}), do: {color, 0}
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

  # -- parse_option_fragment/2: narrow per-segment machinery ---------------

  defp fragment_segments(fragment) do
    {_offset, segments_rev} =
      fragment
      |> String.split("/")
      |> Enum.reduce({0, []}, fn part, {offset, acc} ->
        {offset + byte_size(part) + 1, [{part, {offset, byte_size(part)}} | acc]}
      end)

    Enum.reverse(segments_rev)
  end

  defp classify_fragment_segment({"", span}) do
    fragment_occurrence(nil, nil, span, span, span, {:error, :empty_segment})
  end

  defp classify_fragment_segment({"then", span}) do
    fragment_occurrence(nil, nil, span, span, span, {:error, :then_not_allowed_in_fragment})
  end

  defp classify_fragment_segment({raw, span}) when raw in ["src", "src64"] do
    fragment_occurrence(nil, nil, span, span, span, {:error, :source_not_allowed_in_fragment})
  end

  defp classify_fragment_segment({raw, span}) do
    {key, value_part} = split_key_value(raw)
    key_span = {elem(span, 0), byte_size(key)}
    val_span = value_span(span, key, value_part)

    case OptionSpec.fetch(key) do
      nil ->
        fragment_occurrence(key, nil, span, key_span, val_span, {:error, :unknown_option})

      %OptionSpec{scope: :request} = spec ->
        fragment_occurrence(
          key,
          spec,
          span,
          key_span,
          val_span,
          {:error, :request_scoped_key_in_fragment}
        )

      spec ->
        fragment_occurrence(key, spec, span, key_span, val_span, dispatch_value(spec, value_part))
    end
  end

  defp fragment_occurrence(key, spec, span, key_span, value_span, result) do
    %{
      key: key,
      spec: spec,
      span: span,
      key_span: key_span,
      value_span: value_span,
      result: result
    }
  end

  defp collect_fragment_errors(occurrences) do
    per_segment_errors =
      occurrences
      |> Enum.filter(&match?(%{result: {:error, _}}, &1))
      |> Enum.map(&fragment_diagnostic/1)

    known_ok = Enum.filter(occurrences, &(&1.spec != nil and match?({:ok, _}, &1.result)))

    per_segment_errors ++ duplicate_diagnostics(known_ok)
  end

  defp fragment_diagnostic(%{
         spec: nil,
         key: nil,
         span: span,
         result: {:error, reason}
       })
       when reason in [
              :empty_segment,
              :then_not_allowed_in_fragment,
              :source_not_allowed_in_fragment
            ] do
    diagnostic(reason, span)
  end

  defp fragment_diagnostic(%{spec: nil, key_span: key_span, result: {:error, :unknown_option}}) do
    diagnostic(:unknown_option, key_span)
  end

  defp fragment_diagnostic(%{
         result: {:error, :request_scoped_key_in_fragment},
         key_span: key_span
       }) do
    diagnostic(:request_scoped_key_in_fragment, key_span)
  end

  defp fragment_diagnostic(%{result: {:error, :missing_value}, key_span: key_span}) do
    diagnostic(:missing_value, key_span)
  end

  defp fragment_diagnostic(%{result: {:error, reason}, value_span: value_span}) do
    diagnostic(reason, value_span)
  end

  # -- diagnostics ----------------------------------------------------------

  defp diagnostic(reason, span) do
    %Diagnostic{reason: reason, message: message_for(reason), spans: [span]}
  end

  @doc """
  The central wording table for every `reason` a `Diagnostic` this module
  (or `ImagePipe.Dialect.Native.Path`'s sibling table) produces — public
  so a diagnostic built outside `Parser` (e.g.
  `ImagePipe.Dialect.Native.Presets`'s `:unknown_preset`, which carries a
  request-supplied name the table itself can't embed) still sources its
  static wording from here rather than duplicating it.
  """
  @spec message_for(atom()) :: String.t()
  def message_for(:empty_pipeline_group), do: "empty pipeline group"
  def message_for(:unknown_option), do: "unknown option"
  def message_for(:missing_value), do: "missing value"
  def message_for(:duplicate_option), do: "duplicate option"
  def message_for(:empty_segment), do: "empty option segment"
  def message_for(:then_not_allowed_in_fragment), do: "then is not allowed in a fragment"

  def message_for(:source_not_allowed_in_fragment),
    do: "src/src64 is not allowed in a fragment"

  def message_for(:request_scoped_key_in_fragment),
    do: "request-scoped option is not allowed in a fragment"

  def message_for(:invalid_dimension), do: "invalid value: expected px or `auto`"

  def message_for(:invalid_fit),
    do: "invalid value: expected contain, cover, cover-down, stretch, or auto"

  def message_for(:invalid_arity),
    do: "invalid value: wrong number of comma-separated elements"

  def message_for(:invalid_element), do: "invalid value: one or more elements are invalid"
  def message_for(:invalid_anchor), do: "invalid value: expected a named anchor position"
  def message_for(:invalid_blur), do: "invalid value: expected a non-negative number"

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

  def message_for(:true_spelled_bare),
    do: "invalid value: write the bare flag instead of key=true"

  def message_for(:invalid_flag),
    do: "invalid value: expected false (or the bare flag for true)"
end
