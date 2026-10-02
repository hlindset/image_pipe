defmodule ImagePipe.API.Presets do
  @moduledoc false

  alias ImagePipe.API.OptionSpec
  alias ImagePipe.API.Parser
  alias ImagePipe.Plan.Presets

  def validate_config(presets) when is_map(presets) do
    valid? =
      Enum.all?(presets, fn {name, fragment} ->
        is_binary(name) and is_binary(fragment) and
          OptionSpec.parse_preset_names(name) == {:ok, [name]}
      end)

    case valid? do
      true ->
        with {:ok, parsed} <- parse_fragments(presets), do: Presets.compile(parsed)

      false ->
        {:error, "expected a map of preset name to option-fragment string"}
    end
  end

  def validate_config(_presets),
    do: {:error, "expected a map of preset name to option-fragment string"}

  def validate_lookup({module, options}) when is_atom(module) and is_list(options) do
    case module.validate_options(options) do
      {:ok, options} when is_list(options) -> {:ok, {module, options}}
      {:error, reason} -> {:error, "preset_lookup options are invalid: #{inspect(reason)}"}
    end
  end

  def validate_lookup(_lookup),
    do: {:error, "expected a {module, options} tuple implementing ImagePipe.URL.PresetLookup"}

  # Names a request needs from the lookup: its selected names plus `default`,
  # minus everything the static map defines. Empty without a lookup.
  def pending(names, options) do
    case options[:preset_lookup] do
      nil ->
        []

      _lookup ->
        static = Keyword.fetch!(options, :presets)
        ["default" | names] |> Enum.uniq() |> Enum.reject(&Map.has_key?(static, &1))
    end
  end

  # Fetches `names` and their nested references level by level, then compiles
  # them over the static presets. Returns the result with `[:preset, :lookup]`
  # span stop metadata.
  # A requested name the lookup omits stays absent, so expansion reports it as
  # unknown; a broken stored definition is the host's fault, not the client's.
  def resolve(names, options) do
    {module, lookup_options} = Keyword.fetch!(options, :preset_lookup)
    static = Keyword.fetch!(options, :presets)
    max = Keyword.fetch!(options, :max_preset_lookups)
    lookup = %{module: module, options: lookup_options, static: static, max: max}
    state = %{asked: [], parsed: %{}, batches: 0}

    {result, state} =
      case fetch_levels(names, state, lookup) do
        {:ok, state} -> {compile(state.parsed, static), state}
        {:error, reason, state} -> {{:error, reason}, state}
      end

    {result, stop_metadata(result, stats(state))}
  end

  defp stats(state), do: %{fetched: map_size(state.parsed), batches: state.batches}

  defp stop_metadata({:ok, _compiled}, stats), do: Map.put(stats, :result, :ok)

  defp stop_metadata({:error, {:preset, reason}}, stats),
    do: Map.merge(stats, %{result: :error, reason: reason})

  defp fetch_levels([], state, _lookup), do: {:ok, state}

  defp fetch_levels(names, state, lookup) do
    asked = state.asked ++ names
    state = %{state | asked: asked, batches: state.batches + 1}

    with :ok <- within_limit(asked, lookup.max),
         {:ok, fragments} <- fetch(lookup, names),
         {:ok, parsed} <- parse_fragments_strict(fragments) do
      state = %{state | parsed: Map.merge(state.parsed, parsed)}

      parsed
      |> Enum.flat_map(fn {_name, preset} -> Map.get(preset.request, :presets, []) end)
      |> Enum.uniq()
      |> Enum.reject(&(Map.has_key?(lookup.static, &1) or &1 in asked))
      |> fetch_levels(state, lookup)
    else
      {:error, reason} -> {:error, reason, state}
    end
  end

  defp within_limit(asked, max) do
    case length(asked) <= max do
      true -> :ok
      false -> {:error, {:preset, :invalid_definition}}
    end
  end

  defp fetch(lookup, names) do
    case lookup.module.fetch(names, lookup.options) do
      {:ok, found} when is_map(found) -> take_fragments(found, names)
      _invalid -> {:error, {:preset, :lookup_unavailable}}
    end
  rescue
    _exception -> {:error, {:preset, :lookup_unavailable}}
  catch
    :exit, _reason -> {:error, {:preset, :lookup_unavailable}}
  end

  defp take_fragments(found, names) do
    Enum.reduce_while(names, {:ok, %{}}, fn name, {:ok, fragments} ->
      case Map.fetch(found, name) do
        {:ok, fragment} when is_binary(fragment) ->
          {:cont, {:ok, Map.put(fragments, name, fragment)}}

        {:ok, _invalid} ->
          {:halt, {:error, {:preset, :lookup_unavailable}}}

        :error ->
          {:cont, {:ok, fragments}}
      end
    end)
  end

  defp parse_fragments_strict(fragments) do
    case parse_fragments(fragments) do
      {:ok, parsed} -> {:ok, parsed}
      {:error, _message} -> {:error, {:preset, :invalid_definition}}
    end
  end

  defp compile(parsed, static) do
    case Presets.compile(parsed, static) do
      {:ok, compiled} -> {:ok, compiled}
      {:error, _message} -> {:error, {:preset, :invalid_definition}}
    end
  end

  defp parse_fragments(presets) do
    Enum.reduce_while(presets, {:ok, %{}}, fn {name, fragment}, {:ok, parsed} ->
      case Parser.parse_preset(fragment) do
        {:ok, preset} ->
          {:cont, {:ok, Map.put(parsed, name, preset)}}

        {:error, diagnostics} ->
          messages = Enum.map_join(diagnostics, "; ", & &1.message)
          {:halt, {:error, "preset #{inspect(name)} is invalid: #{messages}"}}
      end
    end)
  end
end
