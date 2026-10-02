defmodule ImagePipe.Presets do
  # Resolves the presets one request may use: the static compiled map, plus
  # the names the host's `ImagePipe.PresetLookup` defines, fetched level by
  # level and compiled over the static presets they may reference.
  #
  # A requested name the lookup omits stays absent, so expansion reports it as
  # unknown (400). An unavailable backend is `:lookup_unavailable` (503); a
  # broken stored definition is `:invalid_definition` (500), the host's fault.
  @moduledoc false

  use Boundary, top_level?: true, deps: [ImagePipe.API, ImagePipe.Telemetry], exports: []

  alias ImagePipe.API.Presets
  alias ImagePipe.Telemetry

  @type error :: {:preset, :lookup_unavailable | :invalid_definition}

  @spec for_request([String.t()], keyword()) :: {:ok, map()} | {:error, error()}
  def for_request(names, config) do
    static = Keyword.fetch!(config, :presets)
    pending = names |> Enum.uniq() |> Enum.reject(&Map.has_key?(static, &1))

    case {config[:preset_lookup], pending} do
      {nil, _pending} ->
        {:ok, static}

      {_lookup, []} ->
        {:ok, static}

      {{module, options}, pending} ->
        lookup = %{
          module: module,
          options: options,
          static: static,
          max: Keyword.fetch!(config, :max_preset_lookups)
        }

        Telemetry.span(
          Telemetry.telemetry_opts(config),
          [:preset, :lookup],
          %{names: pending},
          fn ->
            resolve(pending, lookup)
          end
        )
    end
  end

  defp resolve(names, lookup) do
    {result, state} =
      case fetch_levels(names, %{asked: [], parsed: %{}, batches: 0}, lookup) do
        {:ok, state} -> {compile(state.parsed, lookup.static), state}
        {:error, reason, state} -> {{:error, reason}, state}
      end

    stats = %{fetched: map_size(state.parsed), batches: state.batches}
    {result, stop_metadata(result, stats)}
  end

  defp stop_metadata({:ok, _compiled}, stats), do: Map.put(stats, :result, :ok)

  defp stop_metadata({:error, {:preset, reason}}, stats),
    do: Map.merge(stats, %{result: :error, reason: reason})

  defp fetch_levels([], state, _lookup), do: {:ok, state}

  defp fetch_levels(names, state, lookup) do
    asked = state.asked ++ names
    state = %{state | asked: asked, batches: state.batches + 1}

    with :ok <- within_limit(asked, lookup.max),
         {:ok, fragments} <- fetch(lookup, names),
         {:ok, parsed} <- parse(fragments) do
      state = %{state | parsed: Map.merge(state.parsed, parsed)}

      parsed
      |> Enum.flat_map(fn {_name, preset} -> Presets.references(preset) end)
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

  defp parse(fragments) do
    Enum.reduce_while(fragments, {:ok, %{}}, fn {name, fragment}, {:ok, parsed} ->
      case Presets.parse_fragment(fragment) do
        {:ok, preset} -> {:cont, {:ok, Map.put(parsed, name, preset)}}
        :error -> {:halt, {:error, {:preset, :invalid_definition}}}
      end
    end)
  end

  defp compile(parsed, static) do
    case Presets.compile_lookup(parsed, static) do
      {:ok, compiled} -> {:ok, compiled}
      :error -> {:error, {:preset, :invalid_definition}}
    end
  end
end
