defmodule ImagePipe.Parser.Imgproxy.Resolver do
  @moduledoc """
  imgproxy geometry-resolution strategy (spec §4.2/§4.4; #434).

  Owns the imgproxy *decision* column and delegates all shared resolution to
  `ImagePipe.Transform.NeutralResolver`:

  - The no-enlarge DPR/padding-scale cap (#237, imgproxy's unconditional
    `!Enlarge()` `DprScale = min(DPR, min(wshrink, hshrink))` block), computed
    once at the resize and carried as strategy state to later padding/canvas
    ops (compute-once-reuse, prepare.go calcScale → padding.go/extend.go).

  The `:auto` fill-vs-fit bucketing is product-neutral and lives in the neutral
  column (`NeutralResolver.resolve_mode/2`, #448); the strategy only reads the
  concrete branch back from it to size the no-enlarge cap.
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
  def resolve(%SourceShape{} = shape, _carry, %PlanResize{} = operation) do
    # The neutral column buckets :auto (NeutralResolver.resolve_mode/2, #448);
    # read the concrete branch back to size the no-enlarge padding-scale cap,
    # then delegate the operation unchanged for the neutral column to lower.
    branch = NeutralResolver.resolve_mode(operation, shape)

    carry = %{
      effective_padding_scale: padding_scale(operation, shape, branch, :resize),
      canvas_preserving_padding_scale: padding_scale(operation, shape, branch, :canvas_preserving)
    }

    delegate(operation, shape, carry)
  end

  def resolve(%SourceShape{} = shape, carry, %PlanPadding{} = operation) do
    ops = Lowering.padding_executables(operation, padding_scale_for(operation, carry))
    {ops, continuation} = NeutralResolver.display_frame_advance(ops, shape)
    {ops, ImagePipe.Resolver.rewrap(continuation, carry)}
  end

  def resolve(%SourceShape{} = shape, carry, %Canvas{} = operation) do
    ops = Lowering.canvas_executables(operation, carry.canvas_preserving_padding_scale || 1.0)
    {ops, continuation} = NeutralResolver.plain_advance(ops, shape)
    {ops, ImagePipe.Resolver.rewrap(continuation, carry)}
  end

  def resolve(%SourceShape{} = shape, carry, operation),
    do: delegate(operation, shape, carry)

  @impl ImagePipe.Resolver
  def continue(tag, dims, %SourceShape{} = shape, carry) do
    case NeutralResolver.continue(tag, dims, shape, nil) do
      {%SourceShape{} = final, nil} ->
        {final, carry}

      {ops, continuation} when is_list(ops) ->
        {ops, ImagePipe.Resolver.rewrap(continuation, carry)}
    end
  end

  # ── delegation ────────────────────────────────────────────────────────────
  # Re-wrap the neutral continuation (resolve) and re-attach the carry around
  # the neutral continue (measure seams) so the imgproxy carry survives — a
  # trim between resize and padding must not lose the stashed DprScale.
  defp delegate(operation, shape, carry) do
    {ops, continuation} = NeutralResolver.resolve(shape, nil, operation)
    {ops, ImagePipe.Resolver.rewrap(continuation, carry)}
  end

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
