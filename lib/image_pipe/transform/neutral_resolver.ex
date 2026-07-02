defmodule ImagePipe.Transform.NeutralResolver do
  @moduledoc false

  # Neutral geometry resolver: owns the deferred-orientation execution policy
  # (#146/#182/#185/#211) under the ImagePipe.Resolver contract. For each plan
  # operation it emits the executable ops to run — with every orientation flush
  # (including the pre-materialize flush that smart/detect crops and
  # arbitrary/mirrored rotates need) made explicit as %Operation.Flush{}, and
  # every zero-op State write expressed as a shape advance (geometry) or an
  # emitted %Operation.StateUpdate{} (non-geometry). All geometry is delegated
  # to Lowering/ResizePlanning public helpers and the executable ops' own pure
  # dims functions; nothing is re-derived.
  #
  # Continuation classification: :acquire iff the post-op dims cannot be
  # computed purely — resize, trim, and arbitrary-angle/mirrored rotate;
  # everything else advances the shape purely.
  #
  # An identity pending never emits a %Flush{}: at the first would-be flush site
  # it is cleared on the shape instead (the driver overlay propagates the clear
  # to State), preserving the streaming fast path.
  #
  # Pinned divergence (arbitrary/mirrored rotate row): with the flush implicit
  # in the pre-op materialize, a pipeline with both a trim and an arbitrary
  # rotate would rotate un-oriented pixels (trim's materialize marks the state
  # materialized, so the rotate's materialize is skipped). No parser can produce
  # that pipeline (imgproxy `rot` is right-angle-only, IIIF has no trim,
  # TwicPics has no arbitrary-angle rotate), so this row always flushes first;
  # every parser-reachable pipeline is pixel-identical.

  @behaviour ImagePipe.Resolver

  alias ImagePipe.Plan.Operation.Canvas
  alias ImagePipe.Plan.Operation.CropGuided
  alias ImagePipe.Plan.Operation.CropRegion
  alias ImagePipe.Plan.Operation.Flip, as: PlanFlip
  alias ImagePipe.Plan.Operation.Gradient, as: PlanGradient
  alias ImagePipe.Plan.Operation.Padding, as: PlanPadding
  alias ImagePipe.Plan.Operation.Pixelate, as: PlanPixelate
  alias ImagePipe.Plan.Operation.Resize, as: PlanResize
  alias ImagePipe.Plan.Operation.Rotate, as: PlanRotate
  alias ImagePipe.Plan.Operation.SetFocus
  alias ImagePipe.Plan.Operation.Trim, as: PlanTrim
  alias ImagePipe.Transform.Focus
  alias ImagePipe.Transform.Lowering
  alias ImagePipe.Transform.Operation.Crop
  alias ImagePipe.Transform.Operation.ExtendCanvas
  alias ImagePipe.Transform.Operation.Flush
  alias ImagePipe.Transform.Operation.Padding
  alias ImagePipe.Transform.Operation.Resize
  alias ImagePipe.Transform.Operation.StateUpdate
  alias ImagePipe.Transform.Orientation
  alias ImagePipe.Transform.PendingOrientation
  alias ImagePipe.Transform.ResizePlanning
  alias ImagePipe.Transform.SourceShape

  @impl ImagePipe.Resolver
  def init, do: nil

  @impl ImagePipe.Resolver
  def behavior_version, do: 1

  @impl ImagePipe.Resolver
  def resolve(%SourceShape{} = shape, env, nil, operation) do
    {ops, continuation} = do_resolve(operation, shape, env)
    {ops, continuation, nil}
  end

  # ── rotate / flip folds ───────────────────────────────────────────────────
  # Right-angle, non-mirrored rotation defers into the pending orientation
  # (lossless vips_rot at the flush, imgproxy parity, #211 seam avoidance).
  defp do_resolve(%PlanRotate{angle: angle, mirror: false}, %SourceShape{} = shape, _env)
       when angle in [0, 90, 180, 270] do
    po = shape.pending_orientation || %PendingOrientation{}
    {[], advance(%{shape | pending_orientation: PendingOrientation.fold_rotate(po, angle)})}
  end

  # Arbitrary angle or mirror: a materializing op. An explicit flush before the
  # rotate lands the rotation in the display frame (EXIF auto-orient -> then
  # user rotation). decode_shrink stays untouched (nothing clears it at a
  # rotate; no parser places a shrink consumer after rotation).
  defp do_resolve(%PlanRotate{} = operation, %SourceShape{} = shape, _env) do
    ops = Lowering.executable_operations(operation, shape)

    then_fn = fn {w, h} ->
      {%{shape | width: w, height: h, frame: :display, pending_orientation: nil}, nil}
    end

    case pending_class(shape) do
      :pending -> {[%Flush{} | ops], {:acquire, then_fn}}
      _none_or_identity -> {ops, {:acquire, then_fn}}
    end
  end

  defp do_resolve(%PlanFlip{axis: axis}, %SourceShape{} = shape, _env) do
    po = shape.pending_orientation || %PendingOrientation{}
    {[], advance(%{shape | pending_orientation: PendingOrientation.fold_flip(po, axis)})}
  end

  # ── SetFocus ──────────────────────────────────────────────────────────────
  # Positional focus: resolve the operand against the live frame at this chain
  # position and commit the carried point through an explicit state update. No
  # pixel work, no flush.
  defp do_resolve(%SetFocus{point: operand}, %SourceShape{} = shape, _env) do
    {live_w, live_h} = SourceShape.live_dims(shape)

    display =
      case shape.pending_orientation do
        nil -> {live_w, live_h}
        po -> swap_if_quarter_turn({live_w, live_h}, po)
      end

    focus_ctx = %{display: display, storage: {live_w, live_h}, decode_shrink: shape.decode_shrink}
    resolved = Focus.resolve(operand, focus_ctx, shape.pending_orientation)
    {[%StateUpdate{fields: %{focus: resolved}}], advance(shape)}
  end

  # ── region crop ───────────────────────────────────────────────────────────
  # Runs literally on oriented pixels: flush pending first. The lowering frame
  # is the post-flush frame — region coords rescale against the quarter-turn-
  # swapped per-axis decode_shrink factors (#185), while the out-of-bounds
  # check reads the stored original storage-frame dims when shrink-on-load
  # fired (the flush does not touch source_dimensions), else the live
  # post-flush display dims.
  # The crop clears the source frame (#180): dims = crop box, decode_shrink nil.
  defp do_resolve(%CropRegion{} = operation, %SourceShape{} = shape, _env) do
    case pending_class(shape) do
      :pending ->
        po = shape.pending_orientation
        {pf_w, pf_h} = post_flush_effective_dims(shape, po)

        lowering_shape = %SourceShape{
          shape
          | width: pf_w,
            height: pf_h,
            frame: :display,
            pending_orientation: nil,
            decode_shrink: orient_decode_shrink(shape.decode_shrink, po)
        }

        [crop] = ops = Lowering.executable_operations(operation, lowering_shape)
        {live_w, live_h} = swap_if_quarter_turn(SourceShape.live_dims(shape), po)
        {box_w, box_h} = Crop.resolved_box_dims(crop, live_w, live_h)

        {[%Flush{} | ops],
         advance(%{
           shape
           | width: box_w,
             height: box_h,
             frame: :display,
             pending_orientation: nil,
             decode_shrink: nil
         })}

      identity_or_none ->
        # Identity: the would-be flush clears the pending without pixel work
        # (orient_decode_shrink is a no-op for a non-quarter-turn identity).
        [crop] = ops = Lowering.executable_operations(operation, shape)
        {live_w, live_h} = SourceShape.live_dims(shape)
        {box_w, box_h} = Crop.resolved_box_dims(crop, live_w, live_h)

        pending = if identity_or_none == :identity, do: nil, else: shape.pending_orientation

        {ops,
         advance(%{
           shape
           | width: box_w,
             height: box_h,
             pending_orientation: pending,
             decode_shrink: nil
         })}
    end
  end

  # ── gravity crop ──────────────────────────────────────────────────────────
  defp do_resolve(%CropGuided{} = operation, %SourceShape{} = shape, _env) do
    pending_class = pending_class(shape)
    materializing? = materializing_gravity?(operation.guide)

    cond do
      pending_class == :pending and materializing? ->
        # Smart/detect crops need display-frame pixels: the explicit flush
        # fires first and the crop stays literal, lowered against the
        # pre-flush state (the unoriented decode_shrink).
        po = shape.pending_orientation
        [crop] = ops = Lowering.executable_operations(operation, shape)
        {live_w, live_h} = swap_if_quarter_turn(SourceShape.live_dims(shape), po)
        {box_w, box_h} = Crop.resolved_box_dims(crop, live_w, live_h)

        {[%Flush{} | ops],
         advance(%{
           shape
           | width: box_w,
             height: box_h,
             frame: :display,
             pending_orientation: nil,
             decode_shrink: nil
         })}

      pending_class == :pending ->
        # Compensated crop pre-flush in the storage frame; NO trailing flush —
        # the flush fires at the next flushing op or the pipeline boundary.
        # decode_shrink is storage-frame; the crop dims are display-frame and
        # compensate_crop swaps their axes for the quarter turn AFTER the
        # rescale, so the per-axis factors are pre-swapped (#185).
        po = shape.pending_orientation

        lowering_shape = %SourceShape{
          shape
          | decode_shrink: orient_decode_shrink(shape.decode_shrink, po)
        }

        [crop] =
          ops =
          operation
          |> Lowering.executable_operations(lowering_shape)
          |> Enum.map(&compensate_crop(&1, po))

        {live_w, live_h} = SourceShape.live_dims(shape)
        {box_w, box_h} = Crop.resolved_box_dims(crop, live_w, live_h)

        {ops, advance(%{shape | width: box_w, height: box_h, decode_shrink: nil})}

      true ->
        # No pending, or identity pending: the crop runs literally in the live
        # frame. An identity pending is kept (this row is not a flush site) —
        # except for a materializing (smart/detect) gravity, whose flush site
        # clears the identity pending without pixel work.
        [crop] = ops = Lowering.executable_operations(operation, shape)
        {live_w, live_h} = SourceShape.live_dims(shape)
        {box_w, box_h} = Crop.resolved_box_dims(crop, live_w, live_h)

        pending =
          if pending_class == :identity and materializing?,
            do: nil,
            else: shape.pending_orientation

        {ops,
         advance(%{
           shape
           | width: box_w,
             height: box_h,
             pending_orientation: pending,
             decode_shrink: nil
         })}
    end
  end

  # ── resize ────────────────────────────────────────────────────────────────
  # Non-identity pending: compensate for the pending orientation, run, then
  # flush so the cover result-crop and tail are post-flush/literal. The
  # quarter-turn cover expansion resolves in the DISPLAY frame and only its
  # result-crop is compensated (see ResizePlanning.cover_resize_and_crop_
  # display_frame); every other branch swaps the resize request and compensates
  # any trailing crop like a gravity crop.
  defp do_resolve(%PlanResize{} = operation, %SourceShape{} = shape, _env) do
    case pending_class(shape) do
      :pending ->
        po = shape.pending_orientation
        ops = pending_resize_ops(operation, po, shape)

        then_fn = fn {w, h} ->
          {%{
             shape
             | width: w,
               height: h,
               frame: :display,
               pending_orientation: nil,
               decode_shrink: nil
           }, nil}
        end

        {ops ++ [%Flush{}], {:acquire, then_fn}}

      _none_or_identity ->
        # Plain path (no compensation, no flush). An identity pending is kept
        # (this row is not a flush site); the pipeline boundary clears it
        # without pixels.
        ops = Lowering.executable_operations(operation, shape)

        then_fn = fn {w, h} ->
          {%{shape | width: w, height: h, decode_shrink: nil}, nil}
        end

        {ops, {:acquire, then_fn}}
    end
  end

  # ── padding / pixelate / gradient ─────────────────────────────────────────
  # These run AFTER rotateAndFlip in imgproxy's order, i.e. in the display
  # frame; with an orientation still pending they flush first so the op decides
  # in the display frame. An identity pending is cleared without a flush
  # (streaming fast path preserved).
  defp do_resolve(%PlanPadding{} = operation, %SourceShape{} = shape, env),
    do:
      resolve_display_frame_op(
        Lowering.padding_executables(operation, padding_scale(operation, env.ctx)),
        shape
      )

  defp do_resolve(%PlanPixelate{} = operation, %SourceShape{} = shape, _env),
    do: resolve_display_frame_op(Lowering.executable_operations(operation, shape), shape)

  defp do_resolve(%PlanGradient{} = operation, %SourceShape{} = shape, _env),
    do: resolve_display_frame_op(Lowering.executable_operations(operation, shape), shape)

  # ── trim ──────────────────────────────────────────────────────────────────
  # imgproxy's one pre-orientation op: it trims the storage frame. Trim needs
  # random access, so the chain's copy-only materialize copies the un-oriented
  # pixels and the pending is kept for a later flush. Never emits a %Flush{}.
  # An identity pending clears on the shape here (the materialize is trim's
  # flush site, with no pixel work). decode_shrink: nil is a never-shrank
  # reaffirmation — the decode planner returns 1.0 for trim chains.
  defp do_resolve(%PlanTrim{} = operation, %SourceShape{} = shape, _env) do
    ops = Lowering.executable_operations(operation, shape)

    pending =
      case pending_class(shape) do
        :pending -> shape.pending_orientation
        _none_or_identity -> nil
      end

    then_fn = fn {w, h} ->
      {%{shape | width: w, height: h, pending_orientation: pending, decode_shrink: nil}, nil}
    end

    {ops, {:acquire, then_fn}}
  end

  # ── canvas ────────────────────────────────────────────────────────────────
  defp do_resolve(%Canvas{} = operation, %SourceShape{} = shape, env) do
    ops = Lowering.canvas_executables(operation, env.ctx.canvas_preserving_padding_scale || 1.0)
    {ops, advance(plain_ops_advance(ops, shape))}
  end

  # ── background / effects (no deferred-orientation handling) ──────────────
  # These run plain, in the storage frame, with any
  # pending intact, and never trigger a flush. Effects are dimension-neutral.
  defp do_resolve(operation, %SourceShape{} = shape, _env) do
    ops = Lowering.executable_operations(operation, shape)
    {ops, advance(plain_ops_advance(ops, shape))}
  end

  # The composition-scale policy for a padding op (imgproxy pd:/dpr coupling):
  # an :effective pixel_ratio reads the scale the resize row stashed on the
  # per-pipeline context; a literal ratio is its own scale.
  defp padding_scale(%PlanPadding{pixel_ratio: {:effective, _fb, :resize}}, %{
         effective_padding_scale: s
       })
       when is_number(s),
       do: s

  defp padding_scale(
         %PlanPadding{pixel_ratio: {:effective, _fb, :canvas_preserving}},
         %{canvas_preserving_padding_scale: s}
       )
       when is_number(s),
       do: s

  defp padding_scale(%PlanPadding{pixel_ratio: {:ratio, n, d}}, _ctx), do: n / d

  defp padding_scale(%PlanPadding{pixel_ratio: {:effective, {:ratio, n, d}, _mode}}, _ctx),
    do: n / d

  # The compensated executable expansion for a resize under a non-identity
  # pending. A quarter turn cannot be compensated by swapping the *request* and
  # resolving in the storage frame for a cover: imgproxy resolves scale in the
  # DISPLAY frame and swaps only the final scale factors, so the min-dimension
  # cross-axis coupling happens on the display axes. The quarter-turn cover
  # therefore resolves in the display frame and only its result-crop is
  # compensated; every other branch swaps the resize request and compensates a
  # trailing crop like a gravity crop.
  defp pending_resize_ops(
         %PlanResize{} = operation,
         %PendingOrientation{} = po,
         %SourceShape{} = shape
       ) do
    if PendingOrientation.quarter_turn?(po) and
         ResizePlanning.cover_resize?(operation, shape) do
      operation
      |> ResizePlanning.cover_resize_and_crop_display_frame(
        shape,
        Lowering.tagged_executable_gravity(operation.guide)
      )
      |> Enum.map(fn
        %Crop{} = crop -> compensate_crop(crop, po)
        other -> other
      end)
    else
      operation
      |> Lowering.executable_operations(shape)
      |> compensate_resize(po)
    end
  end

  defp plain_ops_advance([%ExtendCanvas{rule: rule}], %SourceShape{} = shape) do
    {live_w, live_h} = SourceShape.live_dims(shape)

    # The planner can only construct a valid canvas rule, so `resolved_canvas_dims`
    # cannot return `{:error, _}` here; match `{:ok, _}` only so an impossible
    # malformed rule crashes loudly instead of silently leaving the shape
    # unadvanced (a stale-dims geometry bug carried into the next op's lowering).
    {:ok, {w, h}} = ExtendCanvas.resolved_canvas_dims(rule, live_w, live_h)

    # resolved_canvas_dims resolves against the live frame (via live_dims), so the
    # canvas dims are already live-frame and an outstanding shrink no longer applies:
    # clear it to keep the shape frame-coherent, as every reset site does. Retaining
    # it would make a later shape-derived read (live_dims) double-divide the live-frame
    # dims by a stale factor.
    %{shape | width: w, height: h, decode_shrink: nil}
  end

  defp plain_ops_advance(_ops, %SourceShape{} = shape), do: shape

  # Padding/pixelate/gradient share one shape: with a non-identity
  # pending, flush first (display frame), else run plain. The ops are already
  # lowered by the caller.
  defp resolve_display_frame_op(ops, %SourceShape{} = shape) do
    case pending_class(shape) do
      :pending ->
        po = shape.pending_orientation
        {w, h} = swap_if_quarter_turn({shape.width, shape.height}, po)
        {w, h} = apply_op_geometry(ops, {w, h})

        {[%Flush{} | ops],
         advance(%{shape | width: w, height: h, frame: :display, pending_orientation: nil})}

      identity_or_none ->
        # raw dims: shrink-on-load is always consumed by a resize before any
        # display-frame op reaches here (parser invariant), so decode_shrink is
        # nil; live_dims (used at the canvas row above) is the shrink-tolerant
        # form.
        {w, h} = apply_op_geometry(ops, {shape.width, shape.height})
        pending = if identity_or_none == :identity, do: nil, else: shape.pending_orientation
        {ops, advance(%{shape | width: w, height: h, pending_orientation: pending})}
    end
  end

  defp apply_op_geometry([%Padding{top: top, right: right, bottom: bottom, left: left}], {w, h}),
    do: {w + left + right, h + top + bottom}

  defp apply_op_geometry(_ops, {w, h}), do: {w, h}

  defp advance(%SourceShape{} = shape), do: {:advance, shape, nil}

  defp pending_class(%SourceShape{pending_orientation: nil}), do: :none

  defp pending_class(%SourceShape{pending_orientation: %PendingOrientation{} = po}),
    do: if(PendingOrientation.identity?(po), do: :identity, else: :pending)

  defp swap_if_quarter_turn({w, h}, %PendingOrientation{} = po) do
    if PendingOrientation.quarter_turn?(po), do: {h, w}, else: {w, h}
  end

  # What post-flush lowering reads via State.effective_source_dims: the
  # flush does not touch source_dimensions, so when shrink-on-load fired the
  # stored original storage-frame dims still answer; otherwise the live
  # post-flush (display-frame) image answers.
  defp post_flush_effective_dims(%SourceShape{decode_shrink: nil} = shape, po),
    do: swap_if_quarter_turn({shape.width, shape.height}, po)

  defp post_flush_effective_dims(%SourceShape{width: w, height: h}, _po), do: {w, h}

  # Pre-swap decode_shrink's per-axis factors for a quarter turn so the later
  # `compensate_crop` axis swap lands each display axis on the factor of the
  # storage axis it becomes. A half turn does not swap dims, so its factors
  # stay put.
  defp orient_decode_shrink(nil, _po), do: nil

  defp orient_decode_shrink(%{w: w, h: h} = shrink, %PendingOrientation{} = po) do
    if PendingOrientation.quarter_turn?(po), do: %{shrink | w: h, h: w}, else: shrink
  end

  defp materializing_gravity?(:smart), do: true
  defp materializing_gravity?({:smart, _}), do: true
  defp materializing_gravity?({:detect, _}), do: true
  defp materializing_gravity?(_other), do: false

  # A carried-focus crop reads State.focus, which lives in the storage frame and
  # already tracks the focused content — so it must NOT be gravity-remapped like
  # an imgproxy focus-point spec. Only the crop box needs the quarter-turn dim
  # swap; the flush then rotates image + focus together. (imgproxy never emits
  # :carried.) This clause MUST precede the {crop_from: :gravity, gravity}
  # clause below, which a :carried crop would otherwise match.
  #
  # A nil State.focus makes Crop.execute fall back to a centred crop, so this
  # crop still needs the center-discard-side compensation (#146 Bug 2) that the
  # gravity clause applies. For a set focus the crop resolves to `:fp` gravity,
  # which ignores center_bias, so setting it unconditionally here is harmless.
  defp compensate_crop(%Crop{gravity: :carried} = crop, %PendingOrientation{} = po) do
    crop = %Crop{crop | center_bias: Orientation.center_discard_sides(po)}

    if PendingOrientation.quarter_turn?(po),
      do: %Crop{crop | width: crop.height, height: crop.width},
      else: crop
  end

  defp compensate_crop(
         %Crop{crop_from: :gravity, gravity: gravity} = crop,
         %PendingOrientation{} = po
       ) do
    if materializing_gravity?(gravity) do
      # Smart/detect crops run on display-frame pixels (flush-before), so they
      # stay literal (no compensation).
      crop
    else
      # The executable crop carries offsets in their tagged unit form.
      # Orientation.compensate_gravity_for/2 ports imgproxy's RotateAndFlip,
      # which operates on the bare float offset. Unwrap to the bare magnitude,
      # compensate, then re-wrap — and on a quarter turn the X/Y *values* swap,
      # so the unit wrappers swap with them.
      {x_unit, x_value} = split_offset(crop.x_offset)
      {y_unit, y_value} = split_offset(crop.y_offset)

      {gravity, x_value, y_value} =
        Orientation.compensate_gravity_for({gravity, x_value, y_value}, po)

      {x_unit, y_unit} =
        if PendingOrientation.quarter_turn?(po), do: {y_unit, x_unit}, else: {x_unit, y_unit}

      # A centered crop with an odd extent difference discards one extra pixel;
      # the storage-frame near-side bias lands on the wrong display side when
      # the flush reverses that storage axis (#146 Bug 2).
      center_bias = Orientation.center_discard_sides(po)

      crop = %Crop{
        crop
        | gravity: gravity,
          x_offset: x_unit.(x_value),
          y_offset: y_unit.(y_value),
          center_bias: center_bias
      }

      if PendingOrientation.quarter_turn?(po) do
        %Crop{crop | width: crop.height, height: crop.width}
      else
        crop
      end
    end
  end

  defp compensate_crop(%Crop{} = crop, %PendingOrientation{}), do: crop

  # Split a tagged crop offset into {rewrap_fun, bare_value}. Orientation
  # compensation negates/swaps the magnitude; the rewrap restores the unit so
  # the executable crop still resolves the offset against the right bounds.
  defp split_offset({:pixels, value}), do: {&{:pixels, &1}, value * 1.0}
  defp split_offset({:scale, value}), do: {&{:scale, &1}, value * 1.0}
  defp split_offset({:scale, num, den}), do: {&{:scale, &1}, num / den}
  defp split_offset({:percent, value}), do: {&{:percent, &1 * 100}, value / 100}
  defp split_offset(value) when is_number(value), do: {& &1, value * 1.0}

  # Compensate a resize expansion in the storage frame for the fit/force/
  # stretch and non-quarter-turn cover paths: the resize's requested dims swap
  # on a quarter turn, and any trailing cover result-crop is compensated like a
  # gravity crop. The whole expansion runs pre-flush; the emitted %Flush{}
  # follows, leaving the tail post-flush/literal.
  defp compensate_resize(operations, %PendingOrientation{} = po) do
    Enum.map(operations, fn
      %Resize{} = resize ->
        if PendingOrientation.quarter_turn?(po), do: Orientation.swap_resize(resize), else: resize

      %Crop{} = crop ->
        compensate_crop(crop, po)

      other ->
        other
    end)
  end
end
