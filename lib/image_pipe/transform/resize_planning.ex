defmodule ImagePipe.Transform.ResizePlanning do
  @moduledoc false

  # Neutral resize expansion: lowers a %Plan.Operation.Resize{} into the
  # executable resize (+ optional result-crop) sequence for the fit/cover/
  # stretch modes. Mode selection (the imgproxy `:auto` fill-vs-fit bucketing)
  # and the no-enlarge padding-scale cap live in the imgproxy strategy
  # (ImagePipe.Parser.Imgproxy.Resolver), which calls back into this module's
  # public `resize_from/2` for the mechanical Plan->executable translation. The
  # gravity for any result-crop is threaded in as a parameter (translated by
  # Lowering) so this module stays a leaf — it never calls back into Lowering.
  #
  # Internal lowering seam: exported from the Transform boundary for the
  # in-tree imgproxy strategy only, not part of the strategy SDK — see the
  # export-list tiers in ImagePipe.Transform.

  alias ImagePipe.Plan.Operation.Resize, as: PlanResize
  alias ImagePipe.Transform.Operation.Crop
  alias ImagePipe.Transform.Operation.Resize
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

  # True when this PlanResize expands into a cover (fill) resize + result-crop.
  # The imgproxy strategy rewrites :auto to :fit/:cover before delegation, so
  # by the time a resize reaches here mode is never :auto.
  @spec cover_resize?(PlanResize.t(), SourceShape.t()) :: boolean()
  def cover_resize?(%PlanResize{mode: :cover}, %SourceShape{}), do: true
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

  @spec resize_from(PlanResize.t(), :fit | :cover | :stretch) :: Resize.t()
  def resize_from(operation, mode) do
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

  defp tagged_dpr_float({:ratio, numerator, denominator}), do: numerator / denominator
end
