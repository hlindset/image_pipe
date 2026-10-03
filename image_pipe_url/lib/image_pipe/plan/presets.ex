defmodule ImagePipe.Plan.Presets do
  # Compiles host-configured presets at initialization and expands a request's
  # references.
  #
  # A reference applies to the group it is written in. Within a group, request
  # defaults (first group only) apply first, then named presets in listed
  # order, then explicit options. Presets' request options apply to the whole
  # request; across groups the later preset in reading order wins, and explicit
  # request options win over every preset. A group left without group options
  # after expansion is dropped before request defaults apply. Nested references
  # anchor the same way inside a fragment. Preset names disappear before
  # request canonicalization and representation identity.
  #
  # A pipeline preset (one with several groups) must supply every group option
  # in the request; request options may come from anywhere.
  #
  # An `:unset` value clears its option from every lower layer, together with
  # its override family and the inherited options whose requirement the merged
  # group no longer meets. It survives compilation, so a preset's unset also
  # clears request defaults, and is removed when a request is expanded.
  @moduledoc false

  alias ImagePipe.Plan.Spec.Issue
  alias ImagePipe.Plan.Spec.Validation

  @guide_family [:anchor, :anchor_offset, :focus, :detect]
  @canvas_family [:extend, :extend_ratio, :extend_at, :extend_offset]
  @group_override_families [
    @guide_family,
    [:crop, :region],
    @canvas_family,
    [:watermark, :watermark_source, :watermark_token]
  ]
  @crop_modifiers [:crop_ratio, :crop_ratio_enlarge]
  @request_override_families [[:quality, :autoquality]]

  @type compiled :: %{groups: %{non_neg_integer() => map()}, request: map()}

  # `compiled` seeds already-compiled presets that `parsed` fragments may
  # reference, such as the static map under request-time lookup.
  @doc false
  def compile(parsed, compiled \\ %{}) do
    Enum.reduce_while(Map.keys(parsed), {:ok, compiled}, fn name, {:ok, compiled} ->
      case resolve(name, parsed, compiled, []) do
        {:ok, _preset, compiled} -> {:cont, {:ok, compiled}}
        {:error, _message} = error -> {:halt, error}
      end
    end)
  end

  defp resolve(name, parsed, compiled, stack) do
    cond do
      name in stack ->
        {:error, "preset cycle: #{Enum.join(Enum.reverse([name | stack]), " -> ")}"}

      Map.has_key?(compiled, name) ->
        {:ok, Map.fetch!(compiled, name), compiled}

      Map.has_key?(parsed, name) ->
        resolve_fragment(name, parsed, compiled, stack)

      true ->
        {:error, "unknown preset: #{name}"}
    end
  end

  defp resolve_fragment(name, parsed, compiled, stack) do
    %{groups: groups, request: request} = Map.fetch!(parsed, name)

    dependencies =
      Enum.reduce_while(references(groups), {:ok, compiled}, fn dependency, {:ok, compiled} ->
        case resolve(dependency, parsed, compiled, [name | stack]) do
          {:ok, _preset, compiled} -> {:cont, {:ok, compiled}}
          {:error, _message} = error -> {:halt, error}
        end
      end)

    with {:ok, compiled} <- dependencies,
         {:ok, preset} <- compose(groups, request, compiled, nil) do
      preset = %{groups: preset.groups, request: preset.request}
      {:ok, preset, Map.put(compiled, name, preset)}
    else
      {:error, [%Issue{} = issue | _issues]} ->
        {:error, "preset #{inspect(name)} is invalid: #{message(issue)}"}

      {:error, _message} = error ->
        error
    end
  end

  # `groups` is indexed from 0 and may carry `:presets` per group. `defaults`
  # is the compiled single-group request defaults, or nil. On success,
  # `origins` maps each result group to the request group it came from.
  @doc false
  def expand(groups, request, presets, defaults) do
    unknown =
      for {index, options} <- Enum.sort(groups),
          name <- Map.get(options, :presets, []),
          not Map.has_key?(presets, name),
          do: issue(:unknown_preset, index, name)

    with [] <- unknown,
         {:ok, expanded} <- compose(groups, request, presets, defaults) do
      {:ok,
       %{
         expanded
         | groups: Map.new(expanded.groups, fn {i, options} -> {i, drop_unset(options)} end),
           request: drop_unset(expanded.request)
       }}
    else
      [_ | _] = issues -> {:error, issues}
      {:error, _issues} = error -> error
    end
  end

  # Names in reading order: by group, then by position in the group's list.
  @doc false
  def references(groups) do
    groups
    |> Enum.sort()
    |> Enum.flat_map(fn {_index, options} -> Map.get(options, :presets, []) end)
    |> Enum.uniq()
  end

  @doc false
  def message(%Issue{reason: :unknown_preset, detail: %{preset: name}}),
    do: "unknown preset: #{name}"

  def message(%Issue{reason: :pipeline_preset_with_group_options, detail: %{preset: name}}),
    do: "pipeline preset #{inspect(name)} cannot be combined with group options"

  def message(%Issue{
        reason: :pipeline_preset_with_preset,
        detail: %{preset: name, other: other}
      }),
      do:
        "pipeline preset #{inspect(name)} cannot be combined with preset #{inspect(other)}, " <>
          "which sets group options"

  def message(%Issue{reason: :multiple_pipeline_presets, detail: %{preset: name, other: other}}),
    do: "pipeline presets #{inspect(name)} and #{inspect(other)} cannot be combined"

  defp compose(groups, request, presets, defaults) do
    # Each selected preset with the request group it is anchored in, in
    # reading order.
    selected =
      for {index, options} <- Enum.sort(groups),
          name <- Map.get(options, :presets, []),
          do: {index, name, Map.fetch!(presets, name)}

    explicit = Map.new(groups, fn {index, options} -> {index, Map.delete(options, :presets)} end)

    case Enum.filter(selected, fn {_index, _name, preset} -> pipeline?(preset) end) do
      [] ->
        {:ok, compose_groups(explicit, request, selected, defaults)}

      [pipeline] ->
        compose_pipeline(pipeline, explicit, request, selected, defaults)

      [{index, name, _}, {_index, other, _} | _rest] ->
        {:error, [issue(:multiple_pipeline_presets, index, name, other)]}
    end
  end

  defp compose_groups(explicit, request, selected, defaults) do
    merged =
      Map.new(explicit, fn {index, options} ->
        layers = for {^index, _name, preset} <- selected, do: Map.fetch!(preset.groups, 0)
        {index, merge_layers(layers ++ [options])}
      end)

    kept =
      case Enum.reject(Enum.sort(merged), fn {_index, options} -> drop_unset(options) == %{} end) do
        [] -> [Enum.min_by(merged, &elem(&1, 0))]
        kept -> kept
      end

    groups =
      case {kept, defaults} do
        {[{first, _options} | rest], %{groups: %{0 => default}}} ->
          layers = for {^first, _name, preset} <- selected, do: Map.fetch!(preset.groups, 0)
          [{first, merge_layers([default | layers] ++ [Map.fetch!(explicit, first)])} | rest]

        {kept, nil} ->
          kept
      end

    %{
      groups:
        groups |> Enum.with_index() |> Map.new(fn {{_origin, options}, i} -> {i, options} end),
      request: compose_request(request, selected, defaults),
      origins:
        groups |> Enum.with_index() |> Map.new(fn {{origin, _options}, i} -> {i, origin} end)
    }
  end

  defp compose_pipeline({index, name, pipeline}, explicit, request, selected, defaults) do
    explicit_options? = Enum.any?(explicit, fn {_index, options} -> options != %{} end)

    other =
      Enum.find(selected, fn {_index, other, preset} ->
        other != name and Enum.any?(preset.groups, fn {_i, options} -> options != %{} end)
      end)

    cond do
      explicit_options? ->
        {:error, [issue(:pipeline_preset_with_group_options, index, name)]}

      other != nil ->
        {_index, other_name, _preset} = other
        {:error, [issue(:pipeline_preset_with_preset, index, name, other_name)]}

      true ->
        groups =
          case defaults do
            nil ->
              pipeline.groups

            %{groups: %{0 => default}} ->
              Map.update!(pipeline.groups, 0, &merge_layers([default, &1]))
          end

        {:ok,
         %{
           groups: groups,
           request: compose_request(request, selected, defaults),
           origins: Map.new(groups, fn {i, _options} -> {i, index} end)
         }}
    end
  end

  defp compose_request(request, selected, defaults) do
    layers = for {_index, _name, preset} <- selected, do: preset.request
    layers = if defaults, do: [defaults.request | layers], else: layers
    Enum.reduce(layers ++ [request], %{}, &merge_request/2)
  end

  defp merge_layers(layers) do
    Enum.reduce(layers, %{}, fn next, previous -> merge_group(next, previous) end)
  end

  defp pipeline?(preset), do: map_size(preset.groups) > 1

  defp merge_group(next, previous) do
    previous
    |> prune_override_families(next)
    |> prune_region_dependents(next)
    |> Map.merge(next)
    |> prune_unset_dependents(previous, next)
  end

  defp merge_request(next, previous) do
    previous
    |> prune_families(next, @request_override_families)
    |> Map.merge(next)
  end

  # Inherited options made inert by this layer's unsets are cleared with them.
  # Options that were already inert, or that this layer sets, stay so that
  # validation reports them.
  defp prune_unset_dependents(merged, previous, next) do
    case Enum.any?(next, &match?({_key, :unset}, &1)) do
      true ->
        stale = Validation.inert_keys(drop_unset(previous))

        merged
        |> drop_unset()
        |> Validation.inert_keys()
        |> Enum.reject(&(Map.has_key?(next, &1) or MapSet.member?(stale, &1)))
        |> case do
          [] -> merged
          inert -> prune_unset_dependents(Map.drop(merged, inert), previous, next)
        end

      false ->
        merged
    end
  end

  defp drop_unset(options), do: Map.reject(options, &match?({_key, :unset}, &1))

  defp prune_override_families(previous, next) do
    prune_families(previous, next, @group_override_families)
  end

  defp prune_families(previous, next, families) do
    Enum.reduce(families, previous, fn family, acc ->
      case Enum.any?(family, &Map.has_key?(next, &1)) do
        true -> Map.drop(acc, family)
        false -> acc
      end
    end)
  end

  defp prune_region_dependents(previous, %{:region => _region} = next) do
    previous = Map.drop(previous, @crop_modifiers)

    if cover_resize_consumer?(Map.merge(previous, next)),
      do: previous,
      else: Map.drop(previous, @guide_family)
  end

  defp prune_region_dependents(previous, _next), do: previous

  defp cover_resize_consumer?(options) do
    resize_intent? =
      Enum.any?([:width, :height, :min_width, :min_height], fn key ->
        is_integer(Map.get(options, key))
      end)

    resize_intent? and cover_fit?(options)
  end

  # fit=auto resizes as contain unless both w and h are numbers.
  defp cover_fit?(%{fit: :auto} = options),
    do: is_integer(Map.get(options, :width)) and is_integer(Map.get(options, :height))

  defp cover_fit?(options), do: Map.get(options, :fit) in [:cover, :cover_down]

  defp issue(reason, index, name, other \\ nil) do
    detail = if other, do: %{preset: name, other: other}, else: %{preset: name}
    %Issue{reason: reason, locations: [{:group, index, :presets}], detail: detail}
  end
end
