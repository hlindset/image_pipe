defmodule ImagePipe.Transform.ResizePlanning do
  @moduledoc false

  # imgproxy resize-parity resolution: lowers a %Plan.Operation.Resize{} into the
  # executable resize (+ optional result-crop) sequence, classifies the auto
  # fill-vs-fit branch, and computes the no-enlarge padding/DPR scale. The gravity
  # for any result-crop is threaded in as a parameter (translated by Lowering) so
  # this module stays a leaf — it never calls back into Lowering.

  alias ImagePipe.Plan.Operation.Resize, as: PlanResize
  alias ImagePipe.Transform.Operation.Crop
  alias ImagePipe.Transform.Operation.Resize
  alias ImagePipe.Transform.PendingOrientation
  alias ImagePipe.Transform.SourceShape

  @spec lower(PlanResize.t(), SourceShape.t(), term()) :: [struct()]
  def lower(%PlanResize{mode: :fit} = operation, %SourceShape{} = shape, gravity) do
    fit_resize_and_result_crop(resize_from(operation, :fit), operation, shape, gravity)
  end

  def lower(%PlanResize{mode: :cover} = operation, %SourceShape{} = shape, gravity) do
    operation
    |> resize_from(:cover)
    |> cover_resize_and_crop(shape, gravity, {operation.x_offset, operation.y_offset})
  end

  def lower(%PlanResize{mode: :stretch} = operation, %SourceShape{}, _gravity) do
    [resize_from(operation, :stretch)]
  end

  def lower(%PlanResize{mode: :auto} = operation, %SourceShape{} = shape, gravity) do
    branch = plan_resize_branch(operation, shape)
    resize = resize_from(operation, branch)
    tagged_executable_resize_operations(branch, resize, operation, shape, gravity)
  end

  defp tagged_executable_resize_operations(
         :cover,
         %Resize{} = resize,
         operation,
         %SourceShape{} = shape,
         gravity
       ) do
    cover_resize_and_crop(
      resize,
      shape,
      gravity,
      {operation.x_offset, operation.y_offset}
    )
  end

  defp tagged_executable_resize_operations(
         :fit,
         %Resize{} = resize,
         operation,
         %SourceShape{} = shape,
         gravity
       ) do
    fit_resize_and_result_crop(resize, operation, shape, gravity)
  end

  # A cover resize scales the whole image to cover the box (the intermediate
  # always overflows it), then crops back. Like the fit path's cropToResult, the
  # crop box is the literal requested dimensions (result_box_*), NOT the
  # min-expanded target: when mw/mh drive the cover scale past the requested box,
  # the min-dimension guarantee survives on the short axis while the long axis is
  # trimmed back to what was asked for (imgproxy prepare.go TargetWidth + crop.go
  # cropToResult, #236). The intermediate covers result_box on both axes, so the
  # crop always fires.
  @spec cover_resize_and_crop(
          Resize.t(),
          SourceShape.t(),
          term(),
          {PlanResize.offset(), PlanResize.offset()}
        ) :: [struct()]
  def cover_resize_and_crop(
        %Resize{} = resize,
        %SourceShape{} = shape,
        gravity,
        {x_offset, y_offset}
      ) do
    {src_w, src_h} = {shape.width, shape.height}

    dimensions =
      Resize.resolve_dimensions(resize,
        source_width: src_w,
        source_height: src_h
      )

    [
      resize,
      %Crop{
        width: result_box_crop_dimension(dimensions.result_box_width),
        height: result_box_crop_dimension(dimensions.result_box_height),
        crop_from: :gravity,
        gravity: gravity,
        x_offset: x_offset,
        y_offset: y_offset,
        offset_scale: dimensions.effective_dpr
      }
    ]
  end

  # A fit resize mirrors imgproxy's scale → cropToResult: scale into the requested
  # box, then crop back to it. The crop bites only when min-dimensions (mw/mh)
  # forced the scaled image past the box on an axis; a plain fit scales inside the
  # box and stays a single resize. The crop box is the literal requested dimensions
  # (result_box_*), NOT the min-expanded target, so the min-dimension guarantee on
  # the short axis survives while the long axis is trimmed (imgproxy prepare.go
  # TargetWidth + crop.go cropToResult).
  defp fit_resize_and_result_crop(
         %Resize{} = resize,
         %PlanResize{} = operation,
         %SourceShape{} = shape,
         gravity
       ) do
    {src_w, src_h} = {shape.width, shape.height}
    dimensions = Resize.resolve_dimensions(resize, source_width: src_w, source_height: src_h)

    if fit_result_crop_bites?(dimensions) do
      [
        resize,
        %Crop{
          width: result_box_crop_dimension(dimensions.result_box_width),
          height: result_box_crop_dimension(dimensions.result_box_height),
          crop_from: :gravity,
          gravity: gravity,
          x_offset: operation.x_offset,
          y_offset: operation.y_offset,
          offset_scale: dimensions.effective_dpr
        }
      ]
    else
      [resize]
    end
  end

  defp fit_result_crop_bites?(dimensions) do
    fit_axis_exceeds?(dimensions.result_box_width, dimensions.intermediate_width) or
      fit_axis_exceeds?(dimensions.result_box_height, dimensions.intermediate_height)
  end

  defp fit_axis_exceeds?(:auto, _intermediate), do: false
  defp fit_axis_exceeds?(box, intermediate), do: box < intermediate

  defp result_box_crop_dimension(:auto), do: :auto
  defp result_box_crop_dimension(value), do: {:pixels, value}

  # True when this PlanResize expands into a cover (fill) resize + result-crop —
  # either an explicit cover, or an auto resize whose branch resolves to cover.
  @spec cover_resize?(PlanResize.t(), SourceShape.t()) :: boolean()
  def cover_resize?(%PlanResize{mode: :cover}, %SourceShape{}), do: true

  def cover_resize?(%PlanResize{mode: :auto} = operation, %SourceShape{} = shape),
    do: plan_resize_branch(operation, shape) == :cover

  def cover_resize?(%PlanResize{}, %SourceShape{}), do: false

  # Quarter-turn cover expansion resolved in the DISPLAY frame (imgproxy parity).
  #
  # imgproxy's calcScale runs against the display-frame source dims (swapped by
  # ExtractGeometry) and the min-dimension coupling (prepare.go:146-158) closes
  # over those display axes; scale.go:10-12 then swaps only the scale factors to
  # apply them to the stored pixels. We mirror that: swap the storage source dims
  # to the display frame, resolve `resolve_dimensions` with the ORIGINAL request,
  # then swap the resolved intermediate/target back into the storage frame. The
  # executable resize is a forcing resize onto the storage-frame intermediate so
  # Resize.execute reproduces those exact dims rather than re-deriving (and
  # re-coupling) them in the storage frame. The result-crop carries the
  # display-frame result-box dims (the literal requested box, #236) and is
  # swapped + remapped by compensate_crop.
  @spec cover_resize_and_crop_display_frame(PlanResize.t(), SourceShape.t(), term()) :: [struct()]
  def cover_resize_and_crop_display_frame(
        %PlanResize{} = operation,
        %SourceShape{} = shape,
        gravity
      ) do
    {src_w, src_h} = {shape.width, shape.height}
    resize = resize_from(operation, :cover)

    display =
      Resize.resolve_dimensions(resize,
        source_width: src_h,
        source_height: src_w
      )

    [
      %Resize{
        mode: :force,
        width: {:pixels, display.intermediate_height},
        height: {:pixels, display.intermediate_width},
        enlarge: true
      },
      %Crop{
        width: result_box_crop_dimension(display.result_box_width),
        height: result_box_crop_dimension(display.result_box_height),
        crop_from: :gravity,
        gravity: gravity,
        x_offset: operation.x_offset,
        y_offset: operation.y_offset,
        offset_scale: display.effective_dpr
      }
    ]
  end

  defp resize_from(operation, mode) do
    %Resize{
      mode: resize_mode(mode, operation),
      width: tagged_executable_resize_dimension(operation.width),
      height: tagged_executable_resize_dimension(operation.height),
      min_width: tagged_executable_optional_resize_dimension(operation.min_width),
      min_height: tagged_executable_optional_resize_dimension(operation.min_height),
      zoom_x: operation.zoom_x,
      zoom_y: operation.zoom_y,
      dpr: tagged_dpr_float(operation.dpr),
      enlarge: operation.enlargement == :allow,
      reject_enlargement: operation.enlargement == :reject,
      max_width: operation.max_width,
      max_height: operation.max_height,
      max_area: operation.max_area
    }
  end

  defp resize_mode(:cover, %PlanResize{down: true}), do: :fill_down
  defp resize_mode(:cover, %PlanResize{}), do: :fill
  defp resize_mode(:fit, %PlanResize{}), do: :fit
  defp resize_mode(:stretch, %PlanResize{}), do: :force

  defp tagged_executable_resize_dimension(:auto), do: :auto
  defp tagged_executable_resize_dimension({:px, value}), do: {:pixels, value}

  defp tagged_executable_resize_dimension({:ratio, numerator, denominator}),
    do: {:ratio, numerator, denominator}

  defp tagged_executable_optional_resize_dimension(nil), do: nil

  defp tagged_executable_optional_resize_dimension(dimension),
    do: tagged_executable_resize_dimension(dimension)

  @spec resize_padding_scale(PlanResize.t(), SourceShape.t(), :resize | :canvas_preserving) ::
          number()
  def resize_padding_scale(%PlanResize{enlargement: :allow} = operation, %SourceShape{}, _mode),
    do: tagged_dpr_float(operation.dpr)

  def resize_padding_scale(%PlanResize{} = operation, %SourceShape{} = shape, mode) do
    # imgproxy computes the no-enlarge padding/DPR cap entirely in the display
    # frame: the fitted target dims (`base.requested_*`) and the source it caps
    # them against are both ExtractGeometry-swapped under a quarter turn. Resolve
    # `base` against the display-frame source so the fitted dims match imgproxy's
    # (a fit against the storage frame fits the transposed axes and skews the cap).
    {src_w, src_h} = display_source_dims(shape)
    requested_scale = tagged_dpr_float(operation.dpr)
    branch = plan_resize_branch(operation, shape)
    resize = resize_from(operation, branch)

    base =
      %{resize | dpr: 1.0, enlarge: true}
      |> Resize.resolve_dimensions(
        source_width: src_w,
        source_height: src_h
      )

    max_without_enlarge = max_padding_scale_without_enlarge(base, shape)
    compensated = compensate_no_enlarge_padding_scale(requested_scale, max_without_enlarge, mode)

    clamp_padding_scale(compensated, max_without_enlarge)
  end

  # No explicit geometry (auto/auto, no zoom): imgproxy's calcScale leaves
  # dstW=srcW, dstH=srcH, so wshrink=hshrink=1 and the no-enlarge cap is
  # min(wshrink,hshrink)=1.0. A no-enlarge request is ALWAYS capped — imgproxy's
  # `!Enlarge()` block unconditionally runs `DprScale = min(DPR, min(wshrink,
  # hshrink))` — so a geometry-less dpr (`pd:…/dpr:N` with no `w`/`h`) caps to 1
  # rather than scaling padding by the raw dpr (#237). A zoom folds into the
  # requested box upstream, so a zoomed request never reaches this auto/auto clause.
  defp max_padding_scale_without_enlarge(
         %{requested_width: :auto, requested_height: :auto},
         %SourceShape{}
       ),
       do: 1.0

  defp max_padding_scale_without_enlarge(
         %{requested_width: width, requested_height: height},
         %SourceShape{} = shape
       ) do
    # The requested box is display-frame; size it against the display-frame source
    # so the no-enlarge cap couples the same axes imgproxy does (its SrcWidth is
    # ExtractGeometry-swapped under a quarter turn). Mixing the display-frame
    # request with storage-frame source dims crosses axes under a pending quarter
    # turn (#182).
    {src_w, src_h} = display_source_dims(shape)
    min(src_w / width, src_h / height)
  end

  # Canvas-preserving composition keeps padding tied to the clamped resize scale
  # instead of compensating DPR upward when enlargement is disabled.
  defp compensate_no_enlarge_padding_scale(
         requested_scale,
         _max_without_enlarge,
         :canvas_preserving
       ),
       do: requested_scale

  defp compensate_no_enlarge_padding_scale(requested_scale, max_without_enlarge, :resize)
       when max_without_enlarge < 1.0 do
    requested_scale / max_without_enlarge
  end

  defp compensate_no_enlarge_padding_scale(requested_scale, _max_without_enlarge, _mode),
    do: requested_scale

  defp clamp_padding_scale(scale, max_without_enlarge),
    do: min(scale, max(max_without_enlarge, 1.0))

  defp plan_resize_branch(%PlanResize{mode: :fit}, %SourceShape{}), do: :fit
  defp plan_resize_branch(%PlanResize{mode: :cover}, %SourceShape{}), do: :cover
  defp plan_resize_branch(%PlanResize{mode: :stretch}, %SourceShape{}), do: :stretch

  defp plan_resize_branch(%PlanResize{mode: :auto} = operation, %SourceShape{} = shape) do
    # imgproxy's ResizeAuto compares srcW−srcH against dstW−dstH on the DISPLAY
    # axes — ExtractGeometry swaps the source dims for a quarter turn before the
    # comparison (prepare.go). Classify against the display-frame source so an
    # EXIF 5–8 / rot:90/270 source is not judged on transposed axes (#182).
    {src_w, src_h} = display_source_dims(shape)

    resize_auto_branch(
      src_w,
      src_h,
      tagged_logical_pixels(operation.width),
      tagged_logical_pixels(operation.height)
    )
  end

  # The source dims in the DISPLAY frame: the storage-frame effective source dims,
  # with the axes swapped when a quarter turn is pending (the display width axis is
  # the storage height axis, and vice versa). Used where imgproxy resolves against
  # ExtractGeometry-swapped source dims — the ResizeAuto fill-vs-fit classification
  # and the no-enlarge padding-scale cap.
  @spec display_source_dims(SourceShape.t()) :: {number(), number()}
  def display_source_dims(%SourceShape{pending_orientation: po} = shape) do
    if not is_nil(po) and PendingOrientation.quarter_turn?(po),
      do: {shape.height, shape.width},
      else: {shape.width, shape.height}
  end

  defp tagged_logical_pixels({:px, value}), do: value
  defp tagged_logical_pixels(_dimension), do: :unknown

  defp tagged_dpr_float({:ratio, numerator, denominator}), do: numerator / denominator

  defp resize_auto_branch(current_width, current_height, target_width, target_height) do
    auto_branch(
      orientation_diff(current_width, current_height),
      orientation_diff(target_width, target_height)
    )
  end

  # imgproxy buckets fill-vs-fit by the sign of the width−height difference, with a
  # square dimension (diff == 0) sharing the non-negative (landscape) bucket; cover
  # fills only when both source and target land in the same bucket
  # (processing/prepare.go:88-97). An `:unknown` diff is an auto (omitted) dimension,
  # which keeps the conservative fit branch.
  defp auto_branch(:unknown, _target_diff), do: :fit
  defp auto_branch(_current_diff, :unknown), do: :fit

  defp auto_branch(current_diff, target_diff)
       when (current_diff >= 0 and target_diff >= 0) or
              (current_diff < 0 and target_diff < 0),
       do: :cover

  defp auto_branch(_current_diff, _target_diff), do: :fit

  defp orientation_diff(width, height)
       when is_integer(width) and is_integer(height),
       do: width - height

  defp orientation_diff(_width, _height), do: :unknown
end
