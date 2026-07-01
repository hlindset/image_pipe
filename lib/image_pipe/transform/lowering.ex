defmodule ImagePipe.Transform.Lowering do
  @moduledoc false

  # Lowers a %Plan.Operation.*{} into the executable %Transform.Operation.*{}
  # sequence it runs as. Plain, context-independent translation plus the
  # shrink-on-load coordinate rescale; resize-mode expansion delegates to
  # ImagePipe.Transform.ResizePlanning (this module threads the translated crop
  # gravity into it as a parameter, keeping ResizePlanning a leaf).

  alias ImagePipe.Plan.Color
  alias ImagePipe.Plan.Operation.Background, as: PlanBackground
  alias ImagePipe.Plan.Operation.Bitonal, as: PlanBitonal
  alias ImagePipe.Plan.Operation.Blur, as: PlanBlur
  alias ImagePipe.Plan.Operation.Brightness, as: PlanBrightness
  alias ImagePipe.Plan.Operation.Canvas
  alias ImagePipe.Plan.Operation.Colorize, as: PlanColorize
  alias ImagePipe.Plan.Operation.Contrast, as: PlanContrast
  alias ImagePipe.Plan.Operation.CropGuided
  alias ImagePipe.Plan.Operation.CropRegion
  alias ImagePipe.Plan.Operation.Duotone, as: PlanDuotone
  alias ImagePipe.Plan.Operation.Gradient, as: PlanGradient
  alias ImagePipe.Plan.Operation.Gray, as: PlanGray
  alias ImagePipe.Plan.Operation.Monochrome, as: PlanMonochrome
  alias ImagePipe.Plan.Operation.Padding, as: PlanPadding
  alias ImagePipe.Plan.Operation.Pixelate, as: PlanPixelate
  alias ImagePipe.Plan.Operation.Resize, as: PlanResize
  alias ImagePipe.Plan.Operation.Rotate, as: PlanRotate
  alias ImagePipe.Plan.Operation.Saturation, as: PlanSaturation
  alias ImagePipe.Plan.Operation.Sharpen, as: PlanSharpen
  alias ImagePipe.Plan.Operation.Trim, as: PlanTrim
  alias ImagePipe.Transform.Geometry
  alias ImagePipe.Transform.Operation.Background
  alias ImagePipe.Transform.Operation.Bitonal
  alias ImagePipe.Transform.Operation.Blur
  alias ImagePipe.Transform.Operation.Brightness
  alias ImagePipe.Transform.Operation.Colorize
  alias ImagePipe.Transform.Operation.Contrast
  alias ImagePipe.Transform.Operation.Crop
  alias ImagePipe.Transform.Operation.Duotone
  alias ImagePipe.Transform.Operation.ExtendCanvas
  alias ImagePipe.Transform.Operation.Gradient
  alias ImagePipe.Transform.Operation.Gray
  alias ImagePipe.Transform.Operation.Monochrome
  alias ImagePipe.Transform.Operation.Padding
  alias ImagePipe.Transform.Operation.Pixelate
  alias ImagePipe.Transform.Operation.Rotate
  alias ImagePipe.Transform.Operation.Saturation
  alias ImagePipe.Transform.Operation.Sharpen
  alias ImagePipe.Transform.Operation.Trim
  alias ImagePipe.Transform.ResizePlanning
  alias ImagePipe.Transform.State

  @spec executable_operations(struct(), State.t(), map()) :: [struct()]
  def executable_operations(%PlanResize{} = operation, %State{} = state, context) do
    ResizePlanning.lower(operation, state, context, tagged_executable_gravity(operation.guide))
  end

  def executable_operations(%CropGuided{} = operation, %State{} = state, _context) do
    crop =
      %Crop{
        width: crop_dimension(operation.width),
        height: crop_dimension(operation.height),
        crop_from: :gravity,
        gravity: tagged_executable_gravity(operation.guide),
        x_offset: operation.x_offset,
        y_offset: operation.y_offset,
        aspect_ratio: operation.aspect_ratio,
        enlarge: operation.enlarge
      }

    [rescale_crop_for_decode_shrink(crop, state.decode_shrink)]
  end

  def executable_operations(%CropRegion{} = operation, %State{} = state, _context) do
    crop =
      %Crop{
        width: crop_dimension(operation.width),
        height: crop_dimension(operation.height),
        crop_from: %{
          left: crop_coordinate(operation.x),
          top: crop_coordinate(operation.y)
        },
        reject_out_of_bounds: reject_region_out_of_bounds?(operation, state)
      }

    [rescale_crop_for_decode_shrink(crop, state.decode_shrink)]
  end

  def executable_operations(%Canvas{} = operation, %State{}, context) do
    # imgproxy dpr-scales the extend target box (TargetWidth = Scale(width, DprScale),
    # prepare.go) and absolute extend offsets (RoundToEven(offset * DprScale),
    # calc_position.go), keeping the composition dpr-stable — it skips the enlarge-off
    # DprScale compensation when extend is enabled. The resize op records exactly that
    # composition-preserving scale; thread it into the canvas op the same way padding
    # does via scaled_padding_side. (Like padding, zoom is not folded into the scale.)
    scale = context.canvas_preserving_padding_scale || 1.0

    width = operation.width |> canvas_dimension() |> scale_canvas_dimension(scale)
    height = operation.height |> canvas_dimension() |> scale_canvas_dimension(scale)

    [
      %ExtendCanvas{
        rule: canvas_rule(width, height),
        gravity: tagged_executable_gravity(operation.placement),
        x_offset: scale_extend_offset(operation.x_offset, scale),
        y_offset: scale_extend_offset(operation.y_offset, scale),
        background: executable_fill(operation.fill)
      }
    ]
  end

  def executable_operations(%PlanPadding{} = operation, %State{} = state, context) do
    scale = effective_padding_scale(operation, state, context)

    [
      %Padding{
        top: scaled_padding_side(operation.top, scale),
        right: scaled_padding_side(operation.right, scale),
        bottom: scaled_padding_side(operation.bottom, scale),
        left: scaled_padding_side(operation.left, scale),
        fill: executable_fill(operation.fill)
      }
    ]
  end

  def executable_operations(%PlanBackground{} = operation, %State{}, _context) do
    [%Background{color: Color.to_rgba_list(operation.color)}]
  end

  def executable_operations(%PlanBlur{sigma: sigma}, %State{}, _context),
    do: [%Blur{sigma: sigma}]

  def executable_operations(%PlanSharpen{sigma: sigma}, %State{}, _context),
    do: [%Sharpen{sigma: sigma}]

  def executable_operations(%PlanPixelate{size: size}, %State{}, _context),
    do: [%Pixelate{size: size}]

  def executable_operations(%PlanMonochrome{} = operation, %State{}, _context) do
    [
      %Monochrome{
        intensity: tagged_ratio_to_float(operation.intensity),
        color: Color.to_rgb_list(operation.color)
      }
    ]
  end

  def executable_operations(%PlanDuotone{} = operation, %State{}, _context) do
    [
      %Duotone{
        intensity: tagged_ratio_to_float(operation.intensity),
        shadow: Color.to_rgb_list(operation.shadow),
        highlight: Color.to_rgb_list(operation.highlight)
      }
    ]
  end

  def executable_operations(%PlanBrightness{value: value}, %State{}, _context),
    do: [%Brightness{value: value}]

  def executable_operations(%PlanContrast{value: value}, %State{}, _context),
    do: [%Contrast{value: value}]

  def executable_operations(%PlanBitonal{}, %State{}, _context), do: [%Bitonal{}]

  def executable_operations(%PlanGray{}, %State{}, _context), do: [%Gray{}]

  def executable_operations(%PlanRotate{angle: angle, mirror: mirror}, %State{}, _context),
    do: [%Rotate{angle: angle, mirror: mirror}]

  def executable_operations(%PlanSaturation{value: value}, %State{}, _context),
    do: [%Saturation{value: value}]

  def executable_operations(%PlanColorize{} = operation, %State{}, _context) do
    [
      %Colorize{
        opacity: tagged_ratio_to_float(operation.opacity),
        color: Color.to_rgb_list(operation.color),
        keep_alpha: operation.keep_alpha
      }
    ]
  end

  def executable_operations(%PlanGradient{} = operation, %State{}, _context) do
    [
      %Gradient{
        opacity: tagged_ratio_to_float(operation.opacity),
        color: Color.to_rgb_list(operation.color),
        angle: operation.angle,
        start: operation.start,
        stop: operation.stop
      }
    ]
  end

  def executable_operations(%PlanTrim{} = operation, %State{}, _context),
    do: [
      %Trim{
        threshold: operation.threshold,
        background: operation.background,
        equal_hor: operation.equal_hor,
        equal_ver: operation.equal_ver
      }
    ]

  defp crop_dimension(:full_axis), do: :auto
  defp crop_dimension({:px, value}), do: {:pixels, value}
  defp crop_dimension({:ratio, numerator, denominator}), do: {:scale, numerator, denominator}

  defp crop_coordinate({:px, value}), do: {:pixels, value}
  defp crop_coordinate({:ratio, numerator, denominator}), do: {:scale, numerator, denominator}

  defp reject_region_out_of_bounds?(%CropRegion{on_out_of_bounds: :clamp}, _state), do: false

  # Decide "wholly outside" in the ORIGINAL source frame (`effective_source_dims`),
  # against the un-rescaled request coordinates — a region entirely outside the image
  # is a property of the request vs. the reported source dimensions, independent of
  # the decoded resolution. Evaluating it after `rescale_crop_for_decode_shrink` would
  # let the coordinate rescale's rounding (`round(orig / shrink)`) push a near-edge
  # *partial* overlap up to the shrunk width and spuriously reject a serviceable
  # request. `resolve_position` clamps negatives to 0, so the only way to be wholly
  # outside is an origin at or past the far edge.
  defp reject_region_out_of_bounds?(%CropRegion{on_out_of_bounds: :reject} = operation, state) do
    {src_w, src_h} = State.effective_source_dims(state)

    Geometry.resolve_position(crop_coordinate(operation.x), src_w) >= src_w or
      Geometry.resolve_position(crop_coordinate(operation.y), src_h) >= src_h
  end

  # Rescale an executable crop's ABSOLUTE coordinates for shrink-on-load through a
  # preceding crop (#151). Shrink-on-load decoded the image smaller by the realized
  # per-axis factor, so a crop expressed in stored-source pixels must divide by that
  # factor to select the same region on the shrunk frame — imgproxy's
  # `CropWidth = max(1, Shrink(CropWidth, wpreshrink))` and the absolute-gravity-
  # offset adjustment (scale_on_load.go:136-153). Width/height and explicit
  # region coordinates rescale unconditionally when absolute; pixel gravity offsets
  # rescale only for non-focus-point gravity (imgproxy guards on `Type !=
  # GravityFocusPoint`, since focus coords are inherently relative). Relative
  # ({:scale,_}/{:percent,_}) dims, coords, and offsets, and `:auto`, are untouched
  # because they already track the shrunk frame proportionally.
  defp rescale_crop_for_decode_shrink(%Crop{} = crop, nil), do: crop

  defp rescale_crop_for_decode_shrink(%Crop{} = crop, %{w: wshrink, h: hshrink}) do
    %Crop{
      crop
      | width: shrink_abs_dimension(crop.width, wshrink),
        height: shrink_abs_dimension(crop.height, hshrink),
        crop_from: shrink_crop_from(crop.crop_from, wshrink, hshrink),
        x_offset: shrink_abs_offset(crop.x_offset, crop.gravity, wshrink),
        y_offset: shrink_abs_offset(crop.y_offset, crop.gravity, hshrink)
    }
  end

  # imgproxy: CropWidth = max(1, Round(CropWidth / preshrink)).
  defp shrink_abs_dimension({:pixels, value}, shrink),
    do: {:pixels, max(1, round(value / shrink))}

  defp shrink_abs_dimension(other, _shrink), do: other

  defp shrink_crop_from(%{left: left, top: top}, wshrink, hshrink) do
    %{left: shrink_abs_coordinate(left, wshrink), top: shrink_abs_coordinate(top, hshrink)}
  end

  defp shrink_crop_from(other, _wshrink, _hshrink), do: other

  defp shrink_abs_coordinate({:pixels, value}, shrink),
    do: {:pixels, max(0, round(value / shrink))}

  defp shrink_abs_coordinate(other, _shrink), do: other

  # Absolute pixel gravity offsets rescale by RoundToEven(offset / preshrink), but
  # NOT for focus-point gravity (imgproxy leaves GravityFocusPoint offsets alone —
  # focus coords are relative). Relative offsets ({:scale,_}/{:percent,_}/number)
  # are already proportional to the shrunk bounds and pass through.
  defp shrink_abs_offset(offset, {:fp, _x, _y}, _shrink), do: offset

  defp shrink_abs_offset({:pixels, value}, _gravity, shrink),
    do: {:pixels, round_half_to_even(value / shrink)}

  defp shrink_abs_offset(other, _gravity, _shrink), do: other

  defp canvas_dimension(:auto), do: :auto
  defp canvas_dimension({:px, value}), do: {:pixels, value}
  defp canvas_dimension({:ratio, numerator, denominator}), do: {:ratio, numerator / denominator}

  defp canvas_rule({:ratio, width}, {:ratio, height}), do: {:aspect_ratio, {width, height}}
  defp canvas_rule(width, height), do: {:dimensions, width, height}

  # imgproxy scales the fixed extend target box by the effective DPR
  # (TargetWidth = imath.Scale(width, DprScale); imath.Scale rounds half away from
  # zero, matching Erlang round/1). `:auto` (keep the image size) and `{:ratio, _}`
  # (the aspect-ratio canvas, computed from the already-dpr-scaled image) are not
  # pixel boxes and are left untouched.
  defp scale_canvas_dimension({:pixels, value}, scale), do: {:pixels, round(value * scale)}
  defp scale_canvas_dimension(dimension, _scale), do: dimension

  # imgproxy dpr-scales an absolute extend offset (|offset| >= 1.0) by
  # imath.RoundToEven (calc_position.go). A fractional (|offset| < 1.0) offset is
  # imgproxy's "fraction of the dimension" form, which ImagePipe does not implement;
  # it is passed through unchanged rather than mis-scaled.
  defp scale_extend_offset(offset, scale) when abs(offset) >= 1.0,
    do: round_half_to_even(offset * scale)

  defp scale_extend_offset(offset, _scale), do: offset

  defp executable_fill(:transparent), do: :transparent

  defp executable_fill({:solid, %Color{alpha: {:ratio, numerator, denominator}} = color})
       when numerator == denominator do
    {:color, Color.to_rgb_list(color)}
  end

  defp executable_fill({:solid, %Color{} = color}), do: {:color, Color.to_rgba_list(color)}

  defp effective_padding_scale(
         %PlanPadding{pixel_ratio: {:effective, _fallback, :resize}},
         %State{},
         %{effective_padding_scale: scale}
       )
       when is_number(scale),
       do: scale

  defp effective_padding_scale(
         %PlanPadding{pixel_ratio: {:effective, _fallback, :canvas_preserving}},
         %State{},
         %{canvas_preserving_padding_scale: scale}
       )
       when is_number(scale),
       do: scale

  defp effective_padding_scale(
         %PlanPadding{pixel_ratio: {:ratio, numerator, denominator}},
         %State{},
         _context
       ),
       do: numerator / denominator

  defp effective_padding_scale(
         %PlanPadding{pixel_ratio: {:effective, {:ratio, numerator, denominator}, _mode}},
         %State{},
         _context
       ),
       do: numerator / denominator

  defp scaled_padding_side({:px, value}, scale), do: round_half_to_even(value * scale)

  defp round_half_to_even(value) do
    floor = Float.floor(value)
    fraction = value - floor

    cond do
      fraction < 0.5 -> trunc(floor)
      fraction > 0.5 -> trunc(floor) + 1
      rem(trunc(floor), 2) == 0 -> trunc(floor)
      true -> trunc(floor) + 1
    end
  end

  def tagged_executable_gravity(:center), do: {:anchor, :center, :center}
  def tagged_executable_gravity(:top_left), do: {:anchor, :left, :top}
  def tagged_executable_gravity(:top), do: {:anchor, :center, :top}
  def tagged_executable_gravity(:top_right), do: {:anchor, :right, :top}
  def tagged_executable_gravity(:left), do: {:anchor, :left, :center}
  def tagged_executable_gravity(:right), do: {:anchor, :right, :center}
  def tagged_executable_gravity(:bottom_left), do: {:anchor, :left, :bottom}
  def tagged_executable_gravity(:bottom), do: {:anchor, :center, :bottom}
  def tagged_executable_gravity(:bottom_right), do: {:anchor, :right, :bottom}
  def tagged_executable_gravity({:anchor, x, y}), do: {:anchor, x, y}

  # Carried (TwicPics) gravity passes through to the executable Crop, which reads
  # State.focus and normalizes it to a focal point at the libvips boundary.
  def tagged_executable_gravity(:carried), do: :carried

  def tagged_executable_gravity({:focal, x, y}),
    do: {:fp, tagged_ratio_to_float(x), tagged_ratio_to_float(y)}

  def tagged_executable_gravity(:smart), do: :smart
  def tagged_executable_gravity({:smart, :face_assist}), do: {:smart, :face_assist}
  def tagged_executable_gravity({:detect, {spec, weights}}), do: {:detect, {spec, weights}}

  defp tagged_ratio_to_float({:ratio, numerator, denominator}), do: numerator / denominator
end
