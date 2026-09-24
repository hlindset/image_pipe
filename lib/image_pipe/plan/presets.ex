defmodule ImagePipe.Plan.Presets do
  @moduledoc """
  Compiles host-configured presets at initialization.

  Defaults apply first, followed by named presets in request order and
  explicit options. Nested references use the same precedence without
  implicitly applying the default. Preset names disappear before request
  canonicalization and representation identity.

  Single-group presets contribute to the first group. A pipeline preset
  supplies the complete group sequence; explicit group options and another
  pipeline preset cannot be combined with it. Output options can override it.
  """

  alias ImagePipe.Plan.Request.Issue

  @guide_family [:anchor, :anchor_offset, :focus, :detect]
  @canvas_family [:extend, :extend_ratio, :extend_at, :extend_offset]
  @group_override_families [
    @guide_family,
    [:crop, :region],
    @canvas_family
  ]
  @crop_modifiers [:crop_ratio, :crop_ratio_enlarge]
  @request_override_families [[:quality, :autoquality]]

  @type compiled :: %{groups: %{non_neg_integer() => map()}, request: map()}

  @doc false
  def compile(parsed) do
    Enum.reduce_while(Map.keys(parsed), {:ok, %{}}, fn name, {:ok, compiled} ->
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
    names = Map.get(request, :presets, [])

    dependencies =
      Enum.reduce_while(names, {:ok, [], compiled}, fn dependency, {:ok, presets, compiled} ->
        case resolve(dependency, parsed, compiled, [name | stack]) do
          {:ok, preset, compiled} -> {:cont, {:ok, [preset | presets], compiled}}
          {:error, _message} = error -> {:halt, error}
        end
      end)

    with {:ok, presets, compiled} <- dependencies,
         {:ok, preset} <- compose(groups, request, Enum.reverse(presets)) do
      {:ok, preset, Map.put(compiled, name, preset)}
    else
      {:error, :conflicting_preset_pipeline} ->
        {:error,
         "preset #{inspect(name)} conflicts with another pipeline or explicit group options"}

      {:error, _message} = error ->
        error
    end
  end

  @doc false
  def expand(groups, request, presets) do
    names = Map.get(request, :presets, [])
    unknown = Enum.reject(names, &Map.has_key?(presets, &1))

    case unknown do
      [] ->
        defaults =
          if Map.has_key?(presets, "default") and "default" not in names,
            do: ["default"],
            else: []

        selected = Enum.map(defaults ++ names, &Map.fetch!(presets, &1))

        case compose(groups, request, selected) do
          {:ok, expanded} -> {:ok, expanded}
          {:error, reason} -> {:error, [issue(reason, :pipeline)]}
        end

      names ->
        {:error, Enum.map(names, &issue(:unknown_preset, &1))}
    end
  end

  defp compose(groups, request, presets) do
    pipeline_count = Enum.count(presets, &(map_size(&1.groups) > 1))
    explicit_groups? = map_size(groups) > 1 or map_size(Map.fetch!(groups, 0)) > 0

    if pipeline_count > 1 or (pipeline_count == 1 and explicit_groups?) do
      {:error, :conflicting_preset_pipeline}
    else
      base = %{groups: %{0 => %{}}, request: %{}}
      merged = Enum.reduce(presets, base, &merge/2)
      explicit = %{groups: groups, request: Map.delete(request, :presets)}
      {:ok, merge(explicit, merged)}
    end
  end

  defp merge(next, previous) do
    groups =
      Map.merge(previous.groups, next.groups, fn _index, previous_options, next_options ->
        previous_options
        |> prune_override_families(next_options)
        |> prune_region_dependents(next_options)
        |> Map.merge(next_options)
      end)

    request =
      previous.request
      |> prune_families(next.request, @request_override_families)
      |> Map.merge(next.request)

    %{groups: groups, request: request}
  end

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

    resize_intent? and Map.get(options, :fit) in [:cover, :cover_down, :auto]
  end

  defp issue(reason, detail),
    do: %Issue{reason: reason, locations: [{:request, :presets}], detail: detail}
end
