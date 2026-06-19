defmodule ImagePipe.Plan.KeyData do
  @moduledoc """
  Canonical keyword data helpers for semantic Plan cache keys.

  Tagged geometry values are already-normalized semantic values. Plan
  constructors normalize DPR before operations reach cache key construction, so
  key data never depends on raw IEEE float representation.
  """

  alias ImagePipe.Plan.Color
  alias ImagePipe.Plan.Operation.Background
  alias ImagePipe.Plan.Operation.Blur
  alias ImagePipe.Plan.Operation.Brightness
  alias ImagePipe.Plan.Operation.Canvas
  alias ImagePipe.Plan.Operation.Colorize
  alias ImagePipe.Plan.Operation.Contrast
  alias ImagePipe.Plan.Operation.CropGuided
  alias ImagePipe.Plan.Operation.CropRegion
  alias ImagePipe.Plan.Operation.Duotone
  alias ImagePipe.Plan.Operation.Flip
  alias ImagePipe.Plan.Operation.Monochrome
  alias ImagePipe.Plan.Operation.Padding
  alias ImagePipe.Plan.Operation.Pixelate
  alias ImagePipe.Plan.Operation.Resize
  alias ImagePipe.Plan.Operation.Rotate
  alias ImagePipe.Plan.Operation.Saturation
  alias ImagePipe.Plan.Operation.SetFocus
  alias ImagePipe.Plan.Operation.Sharpen
  alias ImagePipe.Plan.Operation.Trim

  @crop_anchor_guides [
    :center,
    :top_left,
    :top,
    :top_right,
    :left,
    :right,
    :bottom_left,
    :bottom,
    :bottom_right
  ]

  @type geometry_value ::
          :auto
          | :full_axis
          | {:px, pos_integer()}
          | {:ratio, non_neg_integer(), pos_integer()}

  @type ratio_data :: [
          {:unit, :ratio}
          | {:numerator, non_neg_integer()}
          | {:denominator, pos_integer()}
        ]

  @spec data(geometry_value() | struct()) :: keyword()
  def data(%Canvas{} = operation) do
    [
      op: :canvas,
      width: data(operation.width),
      height: data(operation.height),
      placement: guide_data(operation.placement),
      fill: fill_data(operation.fill),
      overflow: operation.overflow,
      x_offset: operation.x_offset,
      y_offset: operation.y_offset
    ]
  end

  def data(%CropGuided{} = operation) do
    [
      op: :crop_guided,
      width: data(operation.width),
      height: data(operation.height),
      guide: guide_data(operation.guide),
      x_offset: operation.x_offset,
      y_offset: operation.y_offset,
      aspect_ratio: crop_aspect_ratio_data(operation.aspect_ratio),
      enlarge: operation.enlarge
    ]
  end

  def data(%CropRegion{} = operation) do
    [
      op: :crop_region,
      x: data(operation.x),
      y: data(operation.y),
      width: data(operation.width),
      height: data(operation.height)
    ]
  end

  def data(%Resize{} = operation) do
    [
      op: :resize,
      mode: operation.mode,
      width: data(operation.width),
      height: data(operation.height),
      dpr: data(operation.dpr),
      enlargement: operation.enlargement,
      guide: guide_data(operation.guide),
      x_offset: operation.x_offset,
      y_offset: operation.y_offset,
      min_width: optional_data(operation.min_width),
      min_height: optional_data(operation.min_height),
      max_width: operation.max_width,
      max_height: operation.max_height,
      max_area: operation.max_area,
      zoom_x: operation.zoom_x,
      zoom_y: operation.zoom_y
    ]
    |> resize_rule_data(operation)
  end

  def data(%Padding{} = operation) do
    [
      op: :padding,
      top: data(operation.top),
      right: data(operation.right),
      bottom: data(operation.bottom),
      left: data(operation.left),
      pixel_ratio: data(operation.pixel_ratio),
      fill: fill_data(operation.fill)
    ]
  end

  def data(%Background{} = operation) do
    [op: :background, color: Color.key_data(operation.color)]
  end

  def data(%Trim{} = operation) do
    [
      op: :trim,
      threshold: operation.threshold,
      background: trim_background_data(operation.background),
      equal_hor: operation.equal_hor,
      equal_ver: operation.equal_ver
    ]
  end

  def data(%Rotate{angle: angle, mirror: mirror}), do: [op: :rotate, angle: angle, mirror: mirror]
  def data(%Flip{axis: axis}), do: [op: :flip, axis: axis]

  # SetFocus carries no pixel op itself, but it selects the focal point the next
  # cover/crop consumes — so it changes the stored bytes and must contribute to
  # the cache key (and, via the same material, the ETag).
  def data(%SetFocus{point: point}), do: [op: :set_focus, point: set_focus_point_data(point)]
  def data(%Blur{sigma: sigma}), do: [op: :blur, sigma: sigma]
  def data(%Sharpen{sigma: sigma}), do: [op: :sharpen, sigma: sigma]
  def data(%Pixelate{size: size}), do: [op: :pixelate, size: size]

  def data(%Monochrome{} = operation) do
    [
      op: :monochrome,
      intensity: data(operation.intensity),
      color: Color.key_data(operation.color)
    ]
  end

  def data(%Duotone{} = operation) do
    [
      op: :duotone,
      intensity: data(operation.intensity),
      shadow: Color.key_data(operation.shadow),
      highlight: Color.key_data(operation.highlight)
    ]
  end

  def data(%Colorize{} = operation) do
    [
      op: :colorize,
      opacity: data(operation.opacity),
      color: Color.key_data(operation.color),
      keep_alpha: operation.keep_alpha
    ]
  end

  def data(%Brightness{value: value}), do: [op: :brightness, value: value]
  def data(%Contrast{value: value}), do: [op: :contrast, value: value]
  def data(%Saturation{value: value}), do: [op: :saturation, value: value]

  def data(:auto), do: [unit: :auto]
  def data(:full_axis), do: [unit: :full_axis]

  def data({:px, value}) when is_integer(value) and value >= 0,
    do: [unit: :logical_px, value: value]

  def data({:ratio, numerator, denominator})
      when is_integer(numerator) and is_integer(denominator) and numerator >= 0 and
             denominator > 0 do
    ratio_data(numerator, denominator)
  end

  def data({:effective, fallback, mode}) when mode in [:resize, :canvas_preserving] do
    [
      unit: :effective_resize_pixel_ratio,
      fallback: data(fallback),
      mode: mode
    ]
  end

  defp optional_data(nil), do: nil
  defp optional_data(value), do: data(value)

  defp crop_aspect_ratio_data(nil), do: nil

  defp crop_aspect_ratio_data({:ratio, numerator, denominator}),
    do: data({:ratio, numerator, denominator})

  defp fill_data(:transparent), do: :transparent
  defp fill_data({:solid, %Color{} = color}), do: [type: :solid, color: Color.key_data(color)]

  defp trim_background_data(:auto), do: :auto
  defp trim_background_data(%Color{} = color), do: Color.key_data(color)

  defp set_focus_point_data({:coord, x, y}), do: [type: :coord, x: data(x), y: data(y)]
  defp set_focus_point_data({:anchor, h, v}), do: [type: :anchor, x: h, y: v]

  defp guide_data(:center), do: :center
  defp guide_data(:carried), do: :carried

  defp guide_data(guide) when guide in @crop_anchor_guides, do: guide

  defp guide_data({:anchor, x, y}), do: [type: :anchor, x: x, y: y]

  defp guide_data({:focal, x, y}), do: [type: :focal, x: data(x), y: data(y)]

  defp guide_data(:smart), do: [type: :smart]

  defp guide_data({:smart, :face_assist}), do: [type: :smart, assist: :face]

  defp guide_data({:detect, {:all, weights}}) when is_map(weights),
    do: [type: :detect, classes: :all, weights: weights]

  defp guide_data({:detect, {classes, weights}}) when is_list(classes) and is_map(weights),
    do: [type: :detect, classes: Enum.sort(classes), weights: weights]

  defp resize_rule_data(data, %Resize{mode: :auto}),
    do: data ++ [rule: :auto_orientation_match_v1]

  defp resize_rule_data(data, %Resize{}), do: data

  defp ratio_data(numerator, denominator) do
    gcd = Integer.gcd(numerator, denominator)

    [
      unit: :ratio,
      numerator: div(numerator, gcd),
      denominator: div(denominator, gcd)
    ]
  end
end
