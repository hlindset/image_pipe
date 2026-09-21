defmodule ImagePipe.Plan.Request.Validation do
  @moduledoc false

  alias ImagePipe.Plan.Request.Issue

  @dimensions [:width, :height, :min_width, :min_height]
  @image_options [
    :format,
    :quality,
    :format_qualities,
    :metadata,
    :color_profile,
    :hdr,
    :autoquality,
    :max_bytes,
    :jpeg_options,
    :png_options,
    :webp_options,
    :avif_options,
    :jxl_options
  ]
  @exclusive [[:crop, :region], [:anchor, :detect], [:anchor, :focus], [:detect, :focus]]
  @encoders [
    jpeg_options: :jpeg,
    png_options: :png,
    webp_options: :webp,
    avif_options: :avif,
    jxl_options: :jpeg_xl
  ]

  @spec errors([map()], map(), MapSet.t(Issue.location())) :: [Issue.t()]
  def errors(groups, options, invalid) do
    group_errors =
      groups
      |> Enum.with_index()
      |> Enum.flat_map(fn {group, index} -> group_errors(group, index, invalid) end)

    group_errors ++ terminal_errors(groups, options) ++ output_errors(options)
  end

  defp group_errors(group, index, invalid) do
    exclusive =
      for keys <- @exclusive,
          Enum.all?(keys, &Map.has_key?(group, &1)),
          do: issue(:mutually_exclusive_options, index, keys, :exclusive)

    canvas =
      case Map.get(group, :extend, false) and Map.get(group, :extend_ratio, false) do
        true -> [issue(:mutually_exclusive_options, index, [:extend, :extend_ratio], :exclusive)]
        false -> []
      end

    exclusive ++ canvas ++ offset_errors(group, index) ++ requirements(group, index, invalid)
  end

  defp requirements(group, index, invalid) do
    rules =
      resize_requirements(group, index, invalid) ++
        guide_requirements(group, index, invalid) ++
        crop_requirements(group, index, invalid) ++
        [{:trim_symmetry, absent?(group, :trim, index, invalid), :trim}] ++
        canvas_requirements(group, index, invalid) ++
        placement_requirements(group, index, invalid)

    errors =
      for {key, missing?, requirement} <- rules,
          missing? and Map.has_key?(group, key),
          do: issue(:inert_option, index, [key], {:requires, requirement})

    errors ++ auto_dimension_errors(group, index, invalid)
  end

  defp resize_requirements(group, index, invalid) do
    missing? = not resize_intent?(group) and not invalid?(invalid, index, @dimensions)

    [
      {:fit, missing?, :resize},
      {:enlarge, missing?, :resize},
      {:zoom, missing? and Map.get(group, :zoom, {1.0, 1.0}) != {1.0, 1.0}, :resize}
    ]
  end

  defp guide_requirements(group, index, invalid) do
    guide? =
      Map.has_key?(group, :crop) or
        (resize_intent?(group) and Map.get(group, :fit) in [:cover, :cover_down, :auto])

    missing? = not guide? and not invalid?(invalid, index, @dimensions ++ [:crop, :fit])
    Enum.map([:anchor, :focus, :detect], &{&1, missing?, :guide})
  end

  defp crop_requirements(group, index, invalid) do
    [
      {:crop_ratio, absent?(group, :crop, index, invalid), :crop},
      {:crop_ratio_enlarge,
       Map.get(group, :crop_ratio_enlarge, false) and absent?(group, :crop_ratio, index, invalid),
       :crop_ratio}
    ]
  end

  defp canvas_requirements(group, index, invalid) do
    box? = is_integer(Map.get(group, :width)) and is_integer(Map.get(group, :height))
    missing? = not box? and not invalid?(invalid, index, [:width, :height])

    Enum.map([:extend, :extend_ratio], &{&1, Map.get(group, &1, false) and missing?, :box})
  end

  defp placement_requirements(group, index, invalid) do
    canvas? = Map.get(group, :extend, false) or Map.get(group, :extend_ratio, false)
    canvas_invalid? = invalid?(invalid, index, [:extend, :extend_ratio])

    [
      {:extend_at, not canvas? and not canvas_invalid?, :canvas},
      {:extend_offset, not canvas? and not canvas_invalid?, :canvas},
      {:anchor_offset,
       Map.get(group, :anchor) in [nil, :smart, :smart_face] and
         not invalid?(invalid, index, [:anchor]), :named_anchor}
    ]
  end

  defp auto_dimension_errors(group, index, invalid) do
    auto_keys = Enum.filter([:width, :height], &(Map.get(group, &1) == :auto))

    case not resize_intent?(group) and not invalid?(invalid, index, @dimensions) and
           auto_keys != [] do
      true -> [issue(:inert_option, index, auto_keys, :auto_dimension)]
      false -> []
    end
  end

  defp resize_intent?(group), do: Enum.any?(@dimensions, &is_integer(Map.get(group, &1)))

  defp absent?(group, key, index, invalid),
    do: not Map.has_key?(group, key) and not invalid?(invalid, index, [key])

  defp invalid?(invalid, index, keys),
    do: Enum.any?(keys, &MapSet.member?(invalid, {:group, index, &1}))

  defp offset_errors(group, index) do
    for key <- [:anchor_offset, :extend_offset],
        offset = Map.get(group, key),
        offset != nil,
        not offset_safe?(offset, Map.get(group, :dpr, 1.0)),
        do: issue(:invalid_offset, index, [key], :invalid_offset)
  end

  defp offset_safe?({x, y}, dpr), do: offset_axis_safe?(x, dpr) and offset_axis_safe?(y, dpr)
  defp offset_axis_safe?({:pct, _value}, _dpr), do: true

  defp offset_axis_safe?({:px, value}, dpr) do
    _scaled = value * dpr * 1.0
    true
  rescue
    ArithmeticError -> false
  end

  defp terminal_errors(groups, options) do
    terminal = Map.get(options, :terminal, :image)

    group_errors =
      for {group, index} <- Enum.with_index(groups),
          key <- Map.keys(group),
          terminal == :info,
          do: issue(:inert_option, index, [key], {:terminal, terminal})

    request_errors =
      for key <- Map.keys(options),
          (key in @image_options and terminal != :image) or (key == :orient and terminal == :info),
          do: issue(:inert_option, :request, [key], {:terminal, terminal})

    group_errors ++ request_errors
  end

  defp output_errors(options) do
    search? = match?({_method, _fields}, Map.get(options, :autoquality))

    conflict =
      case Map.has_key?(options, :quality) and search? do
        true ->
          [
            issue(
              :mutually_exclusive_options,
              :request,
              [:quality, :autoquality],
              :quality_search
            )
          ]

        false ->
          []
      end

    png =
      for {key, enabled?} <- [autoquality: search?, max_bytes: Map.has_key?(options, :max_bytes)],
          Map.get(options, :format) == :png and enabled?,
          do: issue(:inert_option, :request, [key], {:requires, :quality_format})

    encoders =
      for {key, format} <- @encoders,
          requested = Map.get(options, :format),
          requested != nil and requested != format and Map.has_key?(options, key),
          do: issue(:inert_option, :request, [key], {:requires, {:format, requested}})

    conflict ++ png ++ encoders
  end

  defp issue(reason, scope, keys, detail) do
    locations = Enum.map(keys, &location(scope, &1))
    %Issue{reason: reason, locations: locations, detail: detail}
  end

  defp location(:request, key), do: {:request, key}
  defp location(index, key), do: {:group, index, key}
end
