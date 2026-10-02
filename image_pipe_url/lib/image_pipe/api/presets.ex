defmodule ImagePipe.API.Presets do
  # Compiles host preset configuration: named presets and request defaults,
  # each given as a URL option fragment or a builder's plan tagged
  # `{:plan, plan}`. A plan is serialized and parsed like a fragment, so both
  # forms follow one grammar.
  # Also parses and compiles fragments returned by a request-time lookup.
  @moduledoc false

  alias ImagePipe.API.OptionSpec
  alias ImagePipe.API.Parser
  alias ImagePipe.API.Serializer
  alias ImagePipe.Plan.Presets

  @type compiled :: %{presets: map(), request_defaults: map() | nil}

  @spec compile(term(), term()) :: {:ok, compiled()} | {:error, String.t()}
  def compile(presets, request_defaults) do
    with {:ok, parsed} <- parse_presets(presets),
         {:ok, compiled} <- Presets.compile(parsed),
         {:ok, defaults} <- parse_defaults(request_defaults) do
      {:ok, %{presets: compiled, request_defaults: defaults}}
    end
  end

  # One looked-up fragment; `:error` when it does not parse.
  @spec parse_fragment(String.t()) :: {:ok, map()} | :error
  def parse_fragment(fragment) do
    case Parser.parse_preset(fragment) do
      {:ok, preset} -> {:ok, preset}
      {:error, _diagnostics} -> :error
    end
  end

  # The names a parsed fragment references, in reading order.
  @spec references(map()) :: [String.t()]
  def references(%{groups: groups}), do: Presets.references(groups)

  # Compiles looked-up presets over the static compiled map they may reference.
  @spec compile_lookup(map(), map()) :: {:ok, map()} | :error
  def compile_lookup(parsed, static) do
    case Presets.compile(parsed, static) do
      {:ok, compiled} -> {:ok, compiled}
      {:error, _message} -> :error
    end
  end

  defp parse_presets(presets) when is_map(presets) do
    Enum.reduce_while(presets, {:ok, %{}}, fn {name, value}, {:ok, parsed} ->
      with true <- is_binary(name) and OptionSpec.parse_preset_names(name) == {:ok, [name]},
           {:ok, preset} <- parse_value("preset #{inspect(name)}", value) do
        {:cont, {:ok, Map.put(parsed, name, preset)}}
      else
        false -> {:halt, {:error, "invalid preset name: #{inspect(name)}"}}
        {:error, _message} = error -> {:halt, error}
      end
    end)
  end

  defp parse_presets(_presets),
    do: {:error, "expected a map of preset name to option fragment or builder"}

  defp parse_defaults(nil), do: {:ok, nil}

  defp parse_defaults(value) do
    with {:ok, defaults} <- parse_value("request_defaults", value) do
      cond do
        map_size(defaults.groups) > 1 ->
          {:error, "request_defaults must be a single group"}

        Map.has_key?(defaults.groups[0], :presets) ->
          {:error, "request_defaults cannot use presets"}

        true ->
          {:ok, defaults}
      end
    end
  end

  defp parse_value(label, value) do
    with {:ok, fragment} <- fragment(label, value) do
      case Parser.parse_preset(fragment) do
        {:ok, preset} ->
          {:ok, preset}

        {:error, diagnostics} ->
          {:error, "#{label} is invalid: #{Enum.map_join(diagnostics, "; ", & &1.message)}"}
      end
    end
  end

  defp fragment(_label, fragment) when is_binary(fragment), do: {:ok, fragment}

  defp fragment(_label, {:plan, plan}),
    do: {:ok, plan |> Serializer.segments() |> Enum.join("/")}

  defp fragment(label, _value),
    do: {:error, "#{label} must be an option fragment string or an ImagePipe.URL builder"}
end
