defmodule ImagePipe.API.Serializer do
  @moduledoc false

  alias ImagePipe.API.OutputOptions
  alias ImagePipe.API.SerializedValue, as: Value
  alias ImagePipe.Plan.Request

  @spec segments(Request.t()) :: [String.t()]
  def segments(%Request{} = request) do
    groups(request.groups) ++
      entries([
        {"orient", nondefault(request.orient, :auto)},
        {"filename", request.filename},
        {"attachment", request.attachment?},
        {"cb", request.cachebuster},
        {"expires", request.expires},
        {"debug", request.debug?}
      ]) ++ output(request.output)
  end

  defp groups([group]), do: group(group)

  defp groups(groups) do
    groups
    |> Enum.map(fn group ->
      case group(group) do
        [] -> ["dpr=1"]
        segments -> segments
      end
    end)
    |> Enum.intersperse(["then"])
    |> List.flatten()
  end

  defp group(group) do
    entries([
      {"rotate", group.rotate},
      {"flip", group.flip},
      {"gray", group.gray},
      {"bitonal", group.bitonal},
      {"dpr", nondefault(group.dpr, 1.0)},
      {"trim", group.trim},
      {"trim-symmetry", group.trim_symmetry},
      {"region", group.region},
      {"crop", group.crop},
      {"crop-ratio", group.crop_ratio},
      {"crop-ratio-enlarge", group.crop_ratio_enlarge},
      {"anchor-offset", group.anchor_offset}
    ]) ++
      guide(group.guide) ++
      resize(group.resize) ++
      canvas(group.canvas) ++
      entries([
        {"blur", group.blur},
        {"sharpen", group.sharpen},
        {"pixelate", group.pixelate},
        {"monochrome", group.monochrome},
        {"duotone", group.duotone},
        {"brightness", group.brightness},
        {"contrast", group.contrast},
        {"saturation", group.saturation},
        {"colorize", group.colorize},
        {"gradient", group.gradient},
        {"pad", group.pad},
        {"bg", group.bg}
      ])
  end

  defp guide(nil), do: []
  defp guide({:anchor, anchor}), do: entries([{"anchor", anchor}])
  defp guide({:anchor_smart}), do: ["anchor=smart"]
  defp guide({:smart, :face_assist}), do: ["anchor=smart-face"]
  defp guide({:focus, x, y}), do: entries([{"focus", {x, y}}])
  defp guide({:detect, detect}), do: entries([{"detect", detect}])

  defp resize(nil), do: []

  defp resize(resize) do
    entries([
      {"w", nondefault(resize.w, :auto)},
      {"h", nondefault(resize.h, :auto)},
      {"min-w", resize.min_w},
      {"min-h", resize.min_h},
      {"fit", nondefault(resize.fit, :contain)},
      {"enlarge", resize.enlarge},
      {"zoom", nondefault(resize.zoom, {1.0, 1.0})}
    ])
  end

  defp canvas(nil), do: []

  defp canvas(canvas) do
    flag =
      case canvas.mode do
        :box -> "extend"
        :ratio -> "extend-ratio"
      end

    [
      flag
      | entries([
          {"extend-at", nondefault(canvas.at, :center)},
          {"extend-offset", nondefault(canvas.offset, {{:px, 0}, {:px, 0}})}
        ])
    ]
  end

  defp output(output) do
    entries([
      {"output", nondefault(output.terminal, :image)},
      {"format", output.format},
      {"q", output.quality},
      {"meta", output.metadata},
      {"profile", output.color_profile},
      {"hdr", output.hdr},
      {"format-q", nondefault(output.format_qualities, %{})},
      {"autoquality", output.autoquality},
      {"max-bytes", output.max_bytes}
    ]) ++
      Enum.map(Enum.sort(output.encoder_options), fn {format, options} ->
        Value.scalar(format) <> "-options=" <> OutputOptions.serialize_encoder(options, format)
      end)
  end

  defp entries(pairs) do
    Enum.flat_map(pairs, fn
      {_key, nil} -> []
      {_key, false} -> []
      {key, true} -> [key]
      {key, value} -> [key <> "=" <> value(key, value)]
    end)
  end

  defp value("trim", {color, tolerance}), do: Value.csv([Value.color(color), tolerance])
  defp value("crop-ratio", {:ratio, numerator, denominator}), do: "#{numerator}:#{denominator}"

  defp value("bg", {r, g, b, alpha}), do: Value.csv([Value.color({r, g, b}), alpha])

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

  defp value("detect", {classes, weights}) do
    classes =
      case classes do
        :all -> [:default | Enum.sort(Map.keys(Map.delete(weights, :default)))]
        classes -> classes
      end

    Enum.map_join(classes, ",", fn class ->
      name =
        case class do
          :default -> "all"
          class -> class
        end

      weight = Map.get(weights, class, Map.get(weights, :default, 1.0))
      name <> ":" <> Value.scalar(weight)
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

  defp nondefault(value, default) when value == default, do: nil
  defp nondefault(value, _default), do: value
end
