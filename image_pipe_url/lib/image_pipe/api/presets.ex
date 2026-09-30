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
