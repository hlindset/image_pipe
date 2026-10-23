defmodule ImagePipe.Plan.Presets do
  # Compiles host-configured presets at initialization and expands a request's
  # references.
  #
  # A reference applies to the group it is written in. Within a group, request
  # defaults (first group only) apply first, then named presets in listed
  # order, then explicit options. Presets' request options apply to the whole
  # request; across groups the later preset in reading order wins, and explicit
  # request options win over every preset. A group left without group options
  # after expansion is dropped once request defaults apply, so a compiled
  # preset keeps a group of only unsets. Nested references anchor the same way
  # inside a fragment. Preset names disappear before request canonicalization
  # and representation identity.
  #
  # A pipeline preset (one with several groups) must supply every group option
  # in the request; request options may come from anywhere.
  #
  # A compiled preset keeps its layers: per group and for the request options,
  # the ordered option maps of the presets it references, inlined, then its
  # own. A request's layers are resolved together, so a nested preset gives
  # the same result as listing its parts, and a write that a higher layer
  # unsets or replaces counts as never written:
  #
  #   1. An `:unset` value clears its option from every lower layer, together
  #      with its override family (a family modifier's `unset` clears only
  #      itself) and the inherited options whose requirement the merged group
  #      no longer meets.
  #   2. From the top layer down, each option that no higher layer replaced
  #      clears what it overrides in lower layers: its own key, its family, a
  #      `q`'s per-format qualities, a `region`'s crop modifiers and guide.
  @moduledoc false

  alias ImagePipe.Plan.Spec.Issue
  alias ImagePipe.Plan.Spec.Validation

  @guide_family [:anchor, :anchor_offset, :focus, :detect]
  @canvas_family [:extend, :extend_ratio, :extend_at, :extend_offset]
  # A layer that writes a family's principal, a value or `unset`, replaces
  # the whole family. A modifier, such as `anchor_offset`, merges like any
  # other option and its `unset` removes only itself.
  @family_modifiers [:anchor_offset, :extend_at, :extend_offset]
  @group_families [
    @guide_family,
    [:crop, :region],
    @canvas_family,
    [:watermark, :watermark_source, :watermark_token]
  ]
  # Each family with its principals, the options whose presence replaces it.
  @group_override_families Enum.map(@group_families, &{&1, &1 -- @family_modifiers})
  @crop_modifiers [:crop_ratio, :crop_ratio_enlarge]
  @request_override_families [{[:quality, :autoquality], [:quality, :autoquality]}]
  @field_merged_options [
    :format_qualities,
    :jpeg_options,
    :png_options,
    :webp_options,
    :avif_options
  ]

  @type compiled :: %{groups: %{non_neg_integer() => [map()]}, request: [map()]}
  @type watermarks :: Validation.watermarks()

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
      preset = drop_groups(preset, &(&1 == []))
      preset = %{groups: preset.groups, request: preset.request}
      {:ok, preset, Map.put(compiled, name, preset)}
    else
      {:error, [%Issue{} = issue | _issues]} ->
        {:error, "preset #{inspect(name)} is invalid: #{message(issue)}"}

      {:error, _message} = error ->
        error
    end
  end

  @doc false
  # Numbers issues by the request's own groups, through the `origins` of
  # `expand/4`. A pipeline preset's groups all come from one request group,
  # so their issues can become the same issue.
  def renumber(issues, origins) do
    issues
    |> Enum.map(fn issue ->
      locations =
        Enum.map(issue.locations, fn
          {:group, index, key} -> {:group, Map.fetch!(origins, index), key}
          location -> location
        end)

      %{issue | locations: locations}
    end)
    |> Enum.uniq()
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
         {:ok, layered} <- compose(groups, request, presets, defaults) do
      resolved = %{
        layered
        | groups: Map.new(layered.groups, fn {i, layers} -> {i, resolve_group(layers)} end),
          request: resolve_request(layered.request)
      }

      {:ok, drop_groups(resolved, &(&1 == %{}))}
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

  # The errors among a compiled preset's own options, which no request can
  # use: a request option replaces both sides of a conflict. Options that do
  # nothing on their own aren't errors, since a request may supply what they
  # need.
  @doc false
  @spec conflicts(compiled(), watermarks()) :: [Issue.t()]
  def conflicts(%{groups: groups, request: request}, watermarks) do
    groups
    |> Enum.sort()
    |> Enum.map(&resolve_group(elem(&1, 1)))
    |> Validation.errors(resolve_request(request), MapSet.new(), watermarks)
    |> Enum.filter(&(&1.severity == :error))
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

  # Drops the groups `empty?` selects and renumbers the rest, keeping the
  # first group when every group is empty.
  defp drop_groups(%{groups: groups, origins: origins} = composed, empty?) do
    kept =
      case Enum.reject(Enum.sort(groups), fn {_i, options} -> empty?.(options) end) do
        [] -> [Enum.min(groups)]
        kept -> kept
      end

    %{
      composed
      | groups: kept |> Enum.with_index() |> Map.new(fn {{_i, options}, j} -> {j, options} end),
        origins:
          kept
          |> Enum.with_index()
          |> Map.new(fn {{i, _options}, j} -> {j, Map.fetch!(origins, i)} end)
    }
  end

  # The request defaults belong to the URL's first group that writes any
  # option, so they apply before a group holding only unsets is dropped. A
  # group with no options at all is skipped, as the parser skips a group of
  # only request options.
  defp compose_groups(explicit, request, selected, defaults) do
    layered =
      explicit
      |> Enum.sort()
      |> Enum.map(fn {index, options} ->
        preset_layers =
          for {^index, _name, preset} <- selected,
              layer <- Map.fetch!(preset.groups, 0),
              do: layer

        {index, layers(preset_layers ++ [options])}
      end)
      |> put_defaults(defaults)

    %{
      groups:
        layered |> Enum.with_index() |> Map.new(fn {{_origin, layers}, i} -> {i, layers} end),
      request: compose_request(request, selected, defaults),
      origins:
        layered |> Enum.with_index() |> Map.new(fn {{origin, _layers}, i} -> {i, origin} end)
    }
  end

  defp put_defaults(layered, nil), do: layered

  defp put_defaults(layered, %{groups: %{0 => default}}) do
    first =
      case Enum.find(layered, fn {_index, layers} -> layers != [] end) do
        {index, _layers} -> index
        nil -> layered |> hd() |> elem(0)
      end

    List.keyreplace(
      layered,
      first,
      0,
      {first, layers([default | elem(List.keyfind(layered, first, 0), 1)])}
    )
  end

  defp compose_pipeline({index, name, pipeline}, explicit, request, selected, defaults) do
    explicit_options? = Enum.any?(explicit, fn {_index, options} -> options != %{} end)

    other =
      Enum.find(selected, fn {_index, other, preset} ->
        other != name and Enum.any?(preset.groups, fn {_i, layers} -> layers != [] end)
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
              Map.update!(pipeline.groups, 0, &layers([default | &1]))
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
    preset_layers = for {_index, _name, preset} <- selected, layer <- preset.request, do: layer
    default_layers = if defaults, do: [defaults.request], else: []
    layers(default_layers ++ preset_layers ++ [request])
  end

  defp layers(maps), do: Enum.reject(maps, &(&1 == %{}))

  defp pipeline?(preset), do: map_size(preset.groups) > 1

  # A group's options from its layers, lowest first.
  defp resolve_group(layers) do
    layers |> Enum.reduce([], &clear_group_unsets/2) |> override_group()
  end

  defp clear_group_unsets(next, lower) do
    case for({key, :unset} <- next, do: key) do
      [] ->
        lower ++ [next]

      unsets ->
        cleared = Enum.map(lower, &Map.drop(&1, group_cleared_keys(unsets)))
        written = Map.reject(next, fn {_key, value} -> value == :unset end)
        stale = lower |> override_group() |> Validation.inert_keys()
        drop_unset_dependents(cleared, written, Map.keys(next), stale) ++ [written]
    end
  end

  defp group_cleared_keys(unsets),
    do: Enum.flat_map(unsets, &family_of(&1, @group_override_families))

  # The keys an unset of `key` clears: its family for a principal, else itself.
  defp family_of(key, families) do
    case Enum.find(families, fn {_family, principals} -> key in principals end) do
      {family, _principals} -> family
      nil -> [key]
    end
  end

  # Inherited options made inert by this layer's unsets are cleared with them.
  # Options that were already inert, or that this layer sets, stay so that
  # validation reports them.
  defp drop_unset_dependents(lower, written, next_keys, stale) do
    (lower ++ [written])
    |> override_group()
    |> Validation.inert_keys()
    |> Enum.reject(&(&1 in next_keys or MapSet.member?(stale, &1)))
    |> case do
      [] ->
        lower

      inert ->
        drop_unset_dependents(Enum.map(lower, &Map.drop(&1, inert)), written, next_keys, stale)
    end
  end

  # Unset-free layers, top down: an option no higher layer replaced clears
  # what it overrides below it.
  defp override_group(layers) do
    cover? = layers |> Enum.reduce(%{}, &Map.merge(&2, &1)) |> cover_resize_consumer?()

    layers
    |> Enum.reverse()
    |> Enum.map_reduce(MapSet.new(), fn layer, replaced ->
      effective = Map.drop(layer, MapSet.to_list(replaced))
      overridden = Map.keys(effective) ++ group_overrides(effective, cover?)
      {effective, MapSet.union(replaced, MapSet.new(overridden))}
    end)
    |> elem(0)
    |> Enum.reduce(%{}, &Map.merge/2)
  end

  defp group_overrides(options, cover?) do
    families =
      for {family, principals} <- @group_override_families,
          Enum.any?(principals, &Map.has_key?(options, &1)),
          key <- family,
          do: key

    region =
      cond do
        not Map.has_key?(options, :region) -> []
        cover? -> @crop_modifiers
        true -> @crop_modifiers ++ @guide_family
      end

    families ++ region
  end

  # The request options from their layers, lowest first.
  defp resolve_request(layers) do
    layers |> Enum.reduce([], &clear_request_unsets/2) |> override_request()
  end

  defp clear_request_unsets(next, lower) do
    cleared =
      Enum.reduce(next, lower, fn
        {key, :unset}, lower ->
          Enum.map(lower, &Map.drop(&1, family_of(key, @request_override_families)))

        {key, {:unset, _value}}, lower ->
          Enum.map(lower, &Map.delete(&1, key))

        _option, lower ->
          lower
      end)

    cleared ++ [drop_unset(next)]
  end

  # `q` sets every format, so a layer's `q` replaces lower layers' per-format
  # qualities. Within one layer, `format-q` wins for the formats it lists.
  # Options holding several values merge field by field, so a layer changes
  # only the fields it names.
  defp override_request(layers) do
    layers
    |> Enum.reverse()
    |> Enum.map_reduce(MapSet.new(), fn layer, replaced ->
      effective = Map.drop(layer, MapSet.to_list(replaced))
      {effective, MapSet.union(replaced, MapSet.new(request_overrides(effective)))}
    end)
    |> elem(0)
    |> Enum.reverse()
    |> Enum.reduce(%{}, fn layer, merged ->
      Map.merge(merged, layer, fn _key, previous, next -> merge_fields(previous, next) end)
    end)
  end

  defp request_overrides(options) do
    families =
      for {family, principals} <- @request_override_families,
          Enum.any?(principals, &Map.has_key?(options, &1)),
          key <- family,
          do: key

    quality = if Map.has_key?(options, :quality), do: [:format_qualities], else: []
    (Map.keys(options) -- @field_merged_options) ++ families ++ quality
  end

  defp merge_fields(%module{} = previous, next), do: module.merge(previous, next)
  defp merge_fields(previous, next), do: Map.merge(previous, next)

  # Removes `:unset` values and the reset marker of `{:unset, value}`, leaving
  # the options a request carries once its layers are merged.
  @doc false
  def drop_unset(options) do
    for {key, value} <- options, value != :unset, into: %{} do
      case {key in @field_merged_options, value} do
        {true, {:unset, value}} -> {key, value}
        {_field_merged?, value} -> {key, value}
      end
    end
  end

  defp cover_resize_consumer?(options) do
    resize_intent? =
      Enum.any?([:width, :height, :min_width, :min_height], fn key ->
        is_integer(Map.get(options, key))
      end)

    resize_intent? and Validation.cover_fit?(options)
  end

  defp issue(reason, index, name, other \\ nil) do
    detail = if other, do: %{preset: name, other: other}, else: %{preset: name}
    %Issue{reason: reason, locations: [{:group, index, :presets}], detail: detail}
  end
end
