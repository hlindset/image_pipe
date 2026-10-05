defmodule ImagePipe.Plan.Spec.Validation do
  @moduledoc false

  alias ImagePipe.Plan.Spec.Issue

  @dimensions [:width, :height, :min_width, :min_height]
  @watermark_assets [:watermark, :watermark_source, :watermark_token]
  @watermark_options [
    :watermark_opacity,
    :watermark_scale,
    :watermark_at,
    :watermark_offset,
    :watermark_tile
  ]
  @exclusive [
    [:crop, :region],
    [:anchor, :detect],
    [:anchor, :focus],
    [:detect, :focus],
    [:watermark, :watermark_source],
    [:watermark, :watermark_token],
    [:watermark_source, :watermark_token]
  ]
  @encoders [
    jpeg_options: :jpeg,
    png_options: :png,
    webp_options: :webp,
    avif_options: :avif
  ]

  @typedoc """
  Host watermark facts, or `nil` when the caller cannot know them (URL
  generation): configured asset names and whether request sources are enabled.
  """
  @type watermarks :: nil | %{names: [String.t()], request_sources?: boolean()}

  @spec errors([map()], map(), MapSet.t(Issue.location()), watermarks()) :: [Issue.t()]
  def errors(groups, options, invalid, watermarks) do
    group_errors =
      groups
      |> Enum.with_index()
      |> Enum.flat_map(fn {group, index} ->
        group_errors(group, index, invalid) ++ watermark_errors(group, index, watermarks)
      end)

    group_errors ++ output_errors(options)
  end

  # The keys of one group whose requirement the group does not meet.
  @doc false
  @spec inert_keys(map()) :: MapSet.t(atom())
  def inert_keys(group) do
    for %Issue{reason: :inert_option, locations: locations} <-
          requirements(group, 0, MapSet.new()),
        {:group, 0, key} <- locations,
        into: MapSet.new(),
        do: key
  end

  defp watermark_errors(_group, _index, nil), do: []

  defp watermark_errors(group, index, %{names: names, request_sources?: request_sources?}) do
    unknown =
      case Map.fetch(group, :watermark) do
        {:ok, name} ->
          if name in names,
            do: [],
            else: [issue(:unknown_watermark, index, [:watermark], :unknown_watermark)]

        :error ->
          []
      end

    disabled =
      for key <- [:watermark_source, :watermark_token],
          Map.has_key?(group, key) and not request_sources?,
          do: issue(:watermark_source_disabled, index, [key], :watermark_source_disabled)

    unknown ++ disabled
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
        placement_requirements(group, index, invalid) ++
        watermark_requirements(group, index, invalid)

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
    guide? = Map.has_key?(group, :crop) or (resize_intent?(group) and cover_fit?(group))

    missing? = not guide? and not invalid?(invalid, index, @dimensions ++ [:crop, :fit])
    Enum.map([:anchor, :focus, :detect], &{&1, missing?, :guide})
  end

  @doc """
  Whether a group's `fit` resizes as cover, so a crop guide can apply to it.
  `fit=auto` resizes as contain unless both `width` and `height` are numbers.
  """
  @spec cover_fit?(map()) :: boolean()
  def cover_fit?(%{fit: :auto} = group),
    do: is_integer(Map.get(group, :width)) and is_integer(Map.get(group, :height))

  def cover_fit?(group), do: Map.get(group, :fit) == :cover

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

  defp watermark_requirements(group, index, invalid) do
    missing? =
      not Enum.any?(@watermark_assets, &Map.has_key?(group, &1)) and
        not invalid?(invalid, index, @watermark_assets)

    tile_missing? =
      not Map.get(group, :watermark_tile, false) and
        not invalid?(invalid, index, [:watermark_tile])

    Enum.map(@watermark_options, &{&1, missing?, :watermark}) ++
      [{:watermark_gap, tile_missing?, :watermark_tile}]
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
    for key <- [:anchor_offset, :extend_offset, :watermark_offset, :watermark_gap],
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

  defp output_errors(options) do
    search? = Map.get(options, :autoquality, false) != false

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
          do: issue(:inert_option, :request, [key], {:requires, {:format, format}})

    conflict ++ png ++ encoders
  end

  defp issue(reason, scope, keys, detail) do
    locations = Enum.map(keys, &location(scope, &1))
    %Issue{reason: reason, locations: locations, detail: detail, severity: severity(reason)}
  end

  defp severity(:inert_option), do: :warning
  defp severity(_reason), do: :error

  defp location(:request, key), do: {:request, key}
  defp location(index, key), do: {:group, index, key}
end
