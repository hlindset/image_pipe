defmodule ImagePipe.API.Serializer do
  @moduledoc false

  alias ImagePipe.API.OptionSpec
  alias ImagePipe.API.OutputOptions
  alias ImagePipe.API.SerializedValue, as: Value
  alias ImagePipe.Plan

  # Each option's URL key and its place in the serialized order, so a plan
  # writes only the options it sets, in a fixed order.
  @options OptionSpec.all()
           |> Enum.with_index()
           |> Map.new(fn {spec, index} -> {spec.name, {index, spec.key}} end)

  # A plan's rejected options follow the accepted ones of their group or of
  # the request. They exist only in plans with errors, which only
  # `ImagePipe.URL.url_with_issues/3` writes.
  @spec segments(Plan.t()) :: [String.t()]
  def segments(%Plan{groups: groups, options: options} = plan) do
    rejected = plan.rejected ++ plan.output_rejected

    groups(groups, rejected) ++
      entries(options) ++ for({{:request, key}, value} <- rejected, do: rejected(key, value))
  end

  defp presets([]), do: []
  defp presets(names), do: ["preset=" <> Enum.join(names, ",")]

  defp groups(groups, rejected) do
    groups
    |> Enum.with_index()
    |> Enum.map(fn {group, index} ->
      presets(Map.get(group, :presets, [])) ++
        entries(Map.delete(group, :presets)) ++
        for {{:group, ^index, key}, value} <- rejected, do: rejected(key, value)
    end)
    |> Enum.intersperse(["-"])
    |> List.flatten()
  end

  # Written under the option's URL name, with `!` before the value so that
  # the server rejects it whatever the value happens to look like.
  defp rejected(key, value), do: url_key(key) <> "=!" <> rejected_value(value)

  defp url_key(:presets), do: "preset"

  defp url_key(name) do
    case Map.fetch(@options, name) do
      :error ->
        name
        |> Atom.to_string()
        |> String.replace("_", "-")
        |> URI.encode(&URI.char_unreserved?/1)

      {:ok, {_index, key}} ->
        key
    end
  end

  defp rejected_value(value) do
    value
    |> rejected_text()
    |> URI.encode(&(URI.char_unreserved?(&1) or &1 in ~c",:"))
  end

  defp rejected_text(value) when is_atom(value),
    do: value |> Atom.to_string() |> String.replace("_", "-")

  defp rejected_text(value) when is_number(value) or is_binary(value), do: to_string(value)

  defp rejected_text(value) when is_list(value) or is_tuple(value) do
    items = if is_tuple(value), do: Tuple.to_list(value), else: value

    case Enum.all?(items, &(is_atom(&1) or is_number(&1) or is_binary(&1))) do
      true -> Enum.map_join(items, ",", &rejected_text/1)
      false -> inspect(value)
    end
  end

  defp rejected_text(value), do: inspect(value)

  defp entries(options) do
    options
    |> Enum.flat_map(fn {name, value} ->
      case Map.fetch(@options, name) do
        {:ok, {index, key}} -> [{index, key, value}]
        :error -> []
      end
    end)
    |> Enum.sort_by(&elem(&1, 0))
    |> Enum.map(fn {_index, key, value} -> entry(key, value) end)
  end

  defp entry(key, :unset), do: key <> "=unset"

  defp entry(key, {:unset, value}),
    do: String.replace_prefix(entry(key, value), key <> "=", key <> "=unset,")

  defp entry(key, true), do: key

  defp entry(key, value)
       when key in ["jpeg-options", "png-options", "webp-options", "avif-options"] do
    format =
      case key do
        "jpeg-options" -> :jpeg
        "png-options" -> :png
        "webp-options" -> :webp
        "avif-options" -> :avif
      end

    key <> "=" <> OutputOptions.serialize_encoder(value, format)
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

  defp value("output", {:info, placeholders}),
    do: Enum.map_join(["info" | Enum.sort(placeholders)], ",", &Value.scalar/1)

  defp value("profile", value), do: Value.scalar(value)
  defp value("wm-src64", source), do: Base.url_encode64(source, padding: false)

  defp value(_key, value) when is_tuple(value) do
    value |> Tuple.to_list() |> Value.csv()
  end

  defp value(_key, value), do: Value.scalar(value)
end
