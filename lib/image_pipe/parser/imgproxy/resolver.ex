defmodule ImagePipe.Parser.Imgproxy.Resolver do
  @moduledoc """
  imgproxy geometry-resolution strategy (spec §4.2/§4.4; #434).

  Owns the imgproxy *decision* column and delegates all shared resolution to
  `ImagePipe.Transform.NeutralResolver`:

  - `:auto` fill-vs-fit bucketing by the sign of width−height, square sharing
    the landscape bucket, on the DISPLAY axes (processing/prepare.go:88-97,
    #182) — rewritten to the concrete mode before delegation, so the neutral
    column never sees `:auto`.
  - The no-enlarge DPR/padding-scale cap (#237, imgproxy's unconditional
    `!Enlarge()` `DprScale = min(DPR, min(wshrink, hshrink))` block), computed
    once at the resize and carried as strategy state to later padding/canvas
    ops (compute-once-reuse, prepare.go calcScale → padding.go/extend.go).
  """

  @behaviour ImagePipe.Resolver

  alias ImagePipe.Plan.Operation.Canvas
  alias ImagePipe.Plan.Operation.Padding, as: PlanPadding
  alias ImagePipe.Plan.Operation.Resize, as: PlanResize
  alias ImagePipe.Transform.Lowering
  alias ImagePipe.Transform.NeutralResolver
  alias ImagePipe.Transform.Operation.Resize
  alias ImagePipe.Transform.PendingOrientation
  alias ImagePipe.Transform.ResizePlanning
  alias ImagePipe.Transform.SourceShape

  @impl ImagePipe.Resolver
  def init, do: %{effective_padding_scale: nil, canvas_preserving_padding_scale: nil}

  @impl ImagePipe.Resolver
  def behavior_version, do: 1

  @impl ImagePipe.Resolver
  def resolve(%SourceShape{} = shape, env, _carry, %PlanResize{} = operation) do
    branch = resize_branch(operation, shape)

    carry = %{
      effective_padding_scale: padding_scale(operation, shape, branch, :resize),
      canvas_preserving_padding_scale: padding_scale(operation, shape, branch, :canvas_preserving)
    }

    delegate(%PlanResize{operation | mode: branch}, shape, env, carry)
  end

  def resolve(%SourceShape{} = shape, _env, carry, %PlanPadding{} = operation) do
    ops = Lowering.padding_executables(operation, padding_scale_for(operation, carry))
    {ops, continuation} = NeutralResolver.display_frame_advance(ops, shape)
    {ops, rewrap(continuation, carry), carry}
  end

  def resolve(%SourceShape{} = shape, _env, carry, %Canvas{} = operation) do
    ops = Lowering.canvas_executables(operation, carry.canvas_preserving_padding_scale || 1.0)
    {ops, continuation} = NeutralResolver.plain_advance(ops, shape)
    {ops, rewrap(continuation, carry), carry}
  end

  def resolve(%SourceShape{} = shape, env, carry, operation),
    do: delegate(operation, shape, env, carry)

  # ── delegation ────────────────────────────────────────────────────────────
  # The neutral resolver threads nil strategy state; re-wrap the continuation
  # so the imgproxy carry survives the advance (including through :acquire —
  # a trim between resize and padding must not lose the stashed DprScale).
  defp delegate(operation, shape, env, carry) do
    {ops, continuation, nil} = NeutralResolver.resolve(shape, env, nil, operation)
    {ops, rewrap(continuation, carry), carry}
  end

  defp rewrap({:advance, %SourceShape{} = shape, nil}, carry), do: {:advance, shape, carry}

  defp rewrap({:acquire, then_fn}, carry) do
    {:acquire,
     fn dims ->
       {%SourceShape{} = shape, nil} = then_fn.(dims)
       {shape, carry}
     end}
  end

  # ── :auto bucketing (moved from ResizePlanning) ───────────────────────────
  defp resize_branch(%PlanResize{mode: :fit}, %SourceShape{}), do: :fit
  defp resize_branch(%PlanResize{mode: :cover}, %SourceShape{}), do: :cover
  defp resize_branch(%PlanResize{mode: :stretch}, %SourceShape{}), do: :stretch

  defp resize_branch(%PlanResize{mode: :auto} = operation, %SourceShape{} = shape) do
    # imgproxy's ResizeAuto compares srcW−srcH against dstW−dstH on the DISPLAY
    # axes — ExtractGeometry swaps the source dims for a quarter turn before the
    # comparison (prepare.go). Classify against the display-frame source so an
    # EXIF 5–8 / rot:90/270 source is not judged on transposed axes (#182).
    {src_w, src_h} = display_source_dims(shape)

    auto_branch(
      orientation_diff(src_w, src_h),
      orientation_diff(
        tagged_logical_pixels(operation.width),
        tagged_logical_pixels(operation.height)
      )
    )
  end

  # imgproxy buckets fill-vs-fit by the sign of the width−height difference,
  # square (diff == 0) sharing the landscape bucket; cover fills only when both
  # land in the same bucket (processing/prepare.go:88-97). :unknown = an auto
  # (omitted) dimension, which keeps the conservative fit branch.
  defp auto_branch(:unknown, _target_diff), do: :fit
  defp auto_branch(_current_diff, :unknown), do: :fit

  defp auto_branch(current_diff, target_diff)
       when (current_diff >= 0 and target_diff >= 0) or
              (current_diff < 0 and target_diff < 0),
       do: :cover

  defp auto_branch(_current_diff, _target_diff), do: :fit

  defp orientation_diff(width, height) when is_integer(width) and is_integer(height),
    do: width - height

  defp orientation_diff(_width, _height), do: :unknown

  defp tagged_logical_pixels({:px, value}), do: value
  defp tagged_logical_pixels(_dimension), do: :unknown

  # ── no-enlarge padding/DPR scale (moved from ResizePlanning; #237) ────────
  defp padding_scale(
         %PlanResize{enlargement: :allow} = operation,
         %SourceShape{},
         _branch,
         _mode
       ),
       do: tagged_dpr_float(operation.dpr)

  defp padding_scale(%PlanResize{} = operation, %SourceShape{} = shape, branch, mode) do
    # imgproxy computes the no-enlarge padding/DPR cap entirely in the display
    # frame (#182): resolve `base` against the display-frame source so the
    # fitted dims match imgproxy's.
    {src_w, src_h} = display_source_dims(shape)
    requested_scale = tagged_dpr_float(operation.dpr)
    resize = ResizePlanning.resize_from(operation, branch)

    base =
      %Resize{resize | dpr: 1.0, enlarge: true}
      |> Resize.resolve_dimensions(source_width: src_w, source_height: src_h)

    max_without_enlarge = max_padding_scale_without_enlarge(base, shape)
    compensated = compensate_no_enlarge_padding_scale(requested_scale, max_without_enlarge, mode)

    min(compensated, max(max_without_enlarge, 1.0))
  end

  # No explicit geometry (auto/auto, no zoom): imgproxy's calcScale leaves
  # dstW=srcW, dstH=srcH, so wshrink=hshrink=1 and the no-enlarge cap is
  # min(wshrink,hshrink)=1.0. A no-enlarge request is ALWAYS capped — imgproxy's
  # `!Enlarge()` block unconditionally runs `DprScale = min(DPR, min(wshrink,
  # hshrink))` — so a geometry-less dpr caps to 1 (#237). A zoom folds into the
  # requested box upstream, so a zoomed request never reaches this auto/auto
  # clause.
  defp max_padding_scale_without_enlarge(
         %{requested_width: :auto, requested_height: :auto},
         %SourceShape{}
       ),
       do: 1.0

  # The requested box is display-frame; size it against the display-frame source
  # so the no-enlarge cap couples the same axes imgproxy does (its SrcWidth is
  # ExtractGeometry-swapped under a quarter turn). Mixing the display-frame
  # request with storage-frame source dims crosses axes under a pending quarter
  # turn (#182).
  defp max_padding_scale_without_enlarge(
         %{requested_width: width, requested_height: height},
         %SourceShape{} = shape
       ) do
    {src_w, src_h} = display_source_dims(shape)
    min(src_w / width, src_h / height)
  end

  defp compensate_no_enlarge_padding_scale(requested_scale, _max, :canvas_preserving),
    do: requested_scale

  defp compensate_no_enlarge_padding_scale(requested_scale, max_without_enlarge, :resize)
       when max_without_enlarge < 1.0,
       do: requested_scale / max_without_enlarge

  defp compensate_no_enlarge_padding_scale(requested_scale, _max, _mode), do: requested_scale

  defp tagged_dpr_float({:ratio, numerator, denominator}), do: numerator / denominator

  # ── carry consumption ─────────────────────────────────────────────────────
  defp padding_scale_for(
         %PlanPadding{pixel_ratio: {:effective, _fb, :resize}},
         %{effective_padding_scale: scale}
       )
       when is_number(scale),
       do: scale

  defp padding_scale_for(
         %PlanPadding{pixel_ratio: {:effective, _fb, :canvas_preserving}},
         %{canvas_preserving_padding_scale: scale}
       )
       when is_number(scale),
       do: scale

  defp padding_scale_for(%PlanPadding{pixel_ratio: {:ratio, n, d}}, _carry), do: n / d

  defp padding_scale_for(%PlanPadding{pixel_ratio: {:effective, {:ratio, n, d}, _mode}}, _carry),
    do: n / d

  defp display_source_dims(%SourceShape{pending_orientation: po} = shape) do
    if not is_nil(po) and PendingOrientation.quarter_turn?(po),
      do: {shape.height, shape.width},
      else: {shape.width, shape.height}
  end
end
