defmodule ImagePipe.Plan.Request do
  @moduledoc """
  Canonical request data shared by parsing and execution.

  Groups express fixed-order transform intent. Output holds sparse request
  policy before format negotiation. `build/3` normalizes typed, validated
  intent supplied by request frontends. Delivery controls and request gates travel
  with this data without contributing to pixel identity.
  """

  alias ImagePipe.Plan.Request.Group
  alias ImagePipe.Plan.Request.Issue
  alias ImagePipe.Plan.Request.Output
  alias ImagePipe.Plan.Request.Validation

  @enforce_keys [:groups, :output, :source]
  defstruct groups: [],
            output: nil,
            source: nil,
            orient: :auto,
            filename: nil,
            attachment?: false,
            cachebuster: nil,
            expires: nil,
            debug?: false

  @type t :: %__MODULE__{
          groups: [Group.t()],
          output: Output.t(),
          source: String.t(),
          orient: :auto | :none,
          filename: String.t() | nil,
          attachment?: boolean(),
          cachebuster: String.t() | nil,
          expires: pos_integer() | nil,
          debug?: boolean()
        }

  @doc false
  @spec errors([map()], map(), MapSet.t(Issue.location())) :: [Issue.t()]
  def errors(groups, options, invalid \\ MapSet.new()),
    do: Validation.errors(groups, options, invalid)

  @doc false
  @spec build([map()], map(), String.t()) :: t()
  def build(groups, options, source) do
    groups = Enum.map(groups, &assemble_group/1)

    %__MODULE__{
      groups: groups,
      output: assemble_output(options),
      source: source,
      orient: Map.get(options, :orient, :auto),
      filename: Map.get(options, :filename),
      attachment?: Map.get(options, :attachment, false),
      cachebuster: Map.get(options, :cachebuster),
      expires: Map.get(options, :expires),
      debug?: Map.get(options, :debug, false)
    }
  end

  defp assemble_group(group_map) do
    resize = assemble_resize(group_map)

    %Group{
      rotate: assemble_rotation(Map.get(group_map, :rotate, 0)),
      flip: Map.get(group_map, :flip),
      gray: Map.get(group_map, :gray, false),
      bitonal: Map.get(group_map, :bitonal, false),
      dpr: Map.get(group_map, :dpr, 1.0),
      trim: assemble_trim(Map.get(group_map, :trim)),
      trim_symmetry: Map.get(group_map, :trim_symmetry),
      region: Map.get(group_map, :region),
      crop: Map.get(group_map, :crop),
      crop_ratio: Map.get(group_map, :crop_ratio),
      crop_ratio_enlarge: Map.get(group_map, :crop_ratio_enlarge, false),
      guide: assemble_guide(group_map, resize != nil),
      anchor_offset: assemble_anchor_offset(Map.get(group_map, :anchor_offset)),
      resize: resize,
      canvas: assemble_canvas(group_map),
      blur: assemble_blur(Map.get(group_map, :blur)),
      sharpen: assemble_zero_identity(Map.get(group_map, :sharpen)),
      pixelate: assemble_one_identity(Map.get(group_map, :pixelate)),
      monochrome: assemble_intensity_effect(Map.get(group_map, :monochrome)),
      duotone: assemble_intensity_effect(Map.get(group_map, :duotone)),
      brightness: assemble_zero_identity(Map.get(group_map, :brightness)),
      contrast: assemble_one_identity(Map.get(group_map, :contrast)),
      saturation: assemble_one_identity(Map.get(group_map, :saturation)),
      colorize: assemble_opacity_effect(Map.get(group_map, :colorize)),
      gradient: assemble_opacity_effect(Map.get(group_map, :gradient)),
      pad: Map.get(group_map, :padding),
      bg: assemble_bg(Map.get(group_map, :background))
    }
  end

  defp assemble_rotation(0), do: nil
  defp assemble_rotation(angle), do: angle

  defp assemble_anchor_offset(nil), do: nil

  defp assemble_anchor_offset(offset) do
    case normalize_offset(offset) do
      {{:px, 0}, {:px, 0}} -> nil
      normalized -> normalized
    end
  end

  defp assemble_canvas(group_map) do
    mode =
      cond do
        Map.get(group_map, :extend, false) -> :box
        Map.get(group_map, :extend_ratio, false) -> :ratio
        true -> nil
      end

    if mode do
      %{
        mode: mode,
        at: Map.get(group_map, :extend_at, :center),
        offset:
          group_map
          |> Map.get(:extend_offset, {{:px, 0}, {:px, 0}})
          |> normalize_offset()
      }
    end
  end

  defp normalize_offset({x, y}), do: {normalize_zero_length(x), normalize_zero_length(y)}
  defp normalize_zero_length({_unit, value}) when value == 0, do: {:px, 0}
  defp normalize_zero_length({unit, value}), do: {unit, value * 1.0}

  defp assemble_resize(group_map) do
    if resize_intent?(group_map) do
      %{
        w: Map.get(group_map, :width, :auto),
        h: Map.get(group_map, :height, :auto),
        min_w: Map.get(group_map, :min_width),
        min_h: Map.get(group_map, :min_height),
        fit: Map.get(group_map, :fit, :contain),
        enlarge: Map.get(group_map, :enlarge, false),
        zoom: Map.get(group_map, :zoom, {1.0, 1.0})
      }
    end
  end

  # One anchor/focus guides both explicit crop and cover-family resize crop.
  # A consumer without a guide receives the canonical default, anchor=center.
  defp assemble_guide(group_map, resize_intent?) do
    cond do
      Map.has_key?(group_map, :anchor) ->
        case Map.fetch!(group_map, :anchor) do
          :smart -> {:anchor_smart}
          :smart_face -> {:smart, :face_assist}
          anchor -> {:anchor, anchor}
        end

      Map.has_key?(group_map, :focus) ->
        {fx, fy} = Map.fetch!(group_map, :focus)
        {:focus, fx, fy}

      Map.has_key?(group_map, :detect) ->
        {:detect, assemble_detection(Map.fetch!(group_map, :detect))}

      guide_consumer?(group_map, resize_intent?) ->
        {:anchor, :center}

      true ->
        nil
    end
  end

  defp assemble_detection(pairs) do
    classes = Enum.map(pairs, &elem(&1, 0))
    selection = if :all in classes, do: :all, else: Enum.sort(classes)

    raw =
      Map.new(pairs, fn
        {:all, weight} -> {:default, weight}
        pair -> pair
      end)

    default = Map.get(raw, :default, 1.0)

    weights =
      Map.reject(raw, fn
        {:default, weight} -> weight == 1.0
        {_class, weight} -> weight == default
      end)

    {selection, weights}
  end

  defp assemble_trim(nil), do: nil
  defp assemble_trim(:auto), do: :auto
  # Default tolerance matches the automatic trim threshold.
  defp assemble_trim({color, nil}), do: {color, 10}
  defp assemble_trim({color, tolerance}), do: {color, tolerance}

  defp assemble_blur(nil), do: nil
  defp assemble_blur(sigma) when sigma == 0.0, do: nil
  defp assemble_blur(sigma), do: sigma

  defp assemble_zero_identity(nil), do: nil
  defp assemble_zero_identity(value) when value == 0, do: nil
  defp assemble_zero_identity(value), do: value

  defp assemble_one_identity(nil), do: nil
  defp assemble_one_identity(value) when value == 1, do: nil
  defp assemble_one_identity(value), do: value

  defp assemble_intensity_effect(nil), do: nil
  defp assemble_intensity_effect(%{intensity: intensity}) when intensity == 0, do: nil
  defp assemble_intensity_effect(effect), do: effect

  defp assemble_opacity_effect(nil), do: nil
  defp assemble_opacity_effect(%{opacity: opacity}) when opacity == 0, do: nil
  defp assemble_opacity_effect(effect), do: effect

  defp assemble_bg(nil), do: nil
  defp assemble_bg({{r, g, b}, nil}), do: {r, g, b, 1.0}
  defp assemble_bg({{r, g, b}, alpha}), do: {r, g, b, alpha}

  defp assemble_output(options) do
    %Output{
      terminal: Map.get(options, :terminal, :image),
      format: Map.get(options, :format),
      quality: Map.get(options, :quality),
      metadata: Map.get(options, :metadata),
      color_profile: Map.get(options, :color_profile),
      hdr: Map.get(options, :hdr),
      format_qualities: Map.get(options, :format_qualities, %{}),
      autoquality: Map.get(options, :autoquality),
      max_bytes: Map.get(options, :max_bytes),
      encoder_options: assemble_encoder_options(options)
    }
  end

  defp assemble_encoder_options(request_map) do
    for {key, format} <- [
          {:jpeg_options, :jpeg},
          {:png_options, :png},
          {:webp_options, :webp},
          {:avif_options, :avif}
        ],
        Map.has_key?(request_map, key),
        options = Map.fetch!(request_map, key),
        Enum.any?(Map.from_struct(options), fn {_field, value} -> not is_nil(value) end),
        into: %{},
        do: {format, options}
  end

  defp resize_intent?(options) do
    Enum.any?([:width, :height, :min_width, :min_height], fn key ->
      is_integer(Map.get(options, key))
    end)
  end

  defp guide_consumer?(options, resize_intent?) do
    Map.has_key?(options, :crop) or
      (resize_intent? and Map.get(options, :fit) in [:cover, :cover_down, :auto])
  end
end
