defmodule ImagePipe.API.Serializer do
  @moduledoc false

  alias ImagePipe.API.OptionSpec
  alias ImagePipe.API.OutputOptions
  alias ImagePipe.API.SerializedValue, as: Value
  alias ImagePipe.Plan

  @options OptionSpec.all()

  def empty_overrides?(%Plan{options: options}) do
    Enum.any?(options, fn
      {:format_qualities, qualities} ->
        map_size(qualities) == 0

      {key, value} when key in [:jpeg_options, :png_options, :webp_options, :avif_options] ->
        Enum.all?(Map.from_struct(value), fn {_field, value} -> is_nil(value) end)

      _option ->
        false
    end)
  end

  @spec segments(Plan.t()) :: [String.t()]
  def segments(%Plan{groups: groups, options: options}) do
    presets(Map.get(options, :presets, [])) ++
      groups(groups) ++ entries(Map.delete(options, :presets))
  end

  defp presets([]), do: []
  defp presets(names), do: ["preset=" <> Enum.join(names, ",")]

  defp groups(groups) do
    groups
    |> Enum.map(&entries/1)
    |> Enum.intersperse(["-"])
    |> List.flatten()
  end

  defp entries(options) do
    for spec <- @options,
        {:ok, value} <- [Map.fetch(options, spec.name)],
        encoded = entry(spec.key, value),
        encoded != nil,
        do: encoded
  end

  defp entry(key, true), do: key
  defp entry("format-q", qualities) when map_size(qualities) == 0, do: nil

  defp entry(key, value)
       when key in ["jpeg-options", "png-options", "webp-options", "avif-options"] do
    format =
      case key do
        "jpeg-options" -> :jpeg
        "png-options" -> :png
        "webp-options" -> :webp
        "avif-options" -> :avif
      end

    case OutputOptions.serialize_encoder(value, format) do
      "" -> nil
      encoded -> key <> "=" <> encoded
    end
  end

  defp entry(key, value), do: key <> "=" <> value(key, value)

  defp value("trim", {color, nil}), do: Value.color(color)
  defp value("trim", {color, tolerance}), do: Value.csv([Value.color(color), tolerance])
  defp value("crop-ratio", {:ratio, numerator, denominator}), do: "#{numerator}:#{denominator}"

  defp value("bg", {color, nil}), do: Value.color(color)
  defp value("bg", {color, alpha}), do: Value.csv([Value.color(color), alpha])

  defp value("monochrome", effect),
    do: Value.csv([effect.intensity, Value.color(effect.color)])

  defp value("duotone", effect),
    do: Value.csv([effect.intensity, Value.color(effect.shadow), Value.color(effect.highlight)])

  defp value("colorize", effect) do
    values = [effect.opacity, Value.color(effect.color)]

    case effect.keep_alpha do
      true -> Value.csv(values ++ ["keep-alpha"])
      false -> Value.csv(values)
    end
  end

  defp value("gradient", effect),
    do:
      Value.csv([
        effect.opacity,
        Value.color(effect.color),
        effect.angle,
        effect.start,
        effect.stop
      ])

  defp value("progressive-blur", effect),
    do: Value.csv([effect.sigma, effect.angle, effect.start, effect.stop])

  defp value("detect", pairs) do
    Enum.map_join(pairs, ",", fn {class, weight} ->
      Value.scalar(class) <> ":" <> Value.scalar(weight)
    end)
  end

  defp value("format-q", qualities) do
    qualities
    |> Enum.sort()
    |> Enum.map_join(",", fn {format, {:quality, quality}} ->
      Value.scalar(format) <> ":" <> Value.scalar(quality)
    end)
  end

  defp value("autoquality", {method, fields}) do
    fields =
      Enum.map(fields, fn {key, value} ->
        name =
          case key do
            :target -> "target"
            :min_quality -> "min"
            :max_quality -> "max"
            :allowed_error -> "error"
          end

        name <> ":" <> Value.scalar(value)
      end)

    Enum.join([Atom.to_string(method) | fields], ",")
  end

  defp value("profile", value), do: Value.scalar(value)

  defp value(_key, value) when is_tuple(value) do
    value |> Tuple.to_list() |> Value.csv()
  end

  defp value(_key, value), do: Value.scalar(value)
end
