defmodule ImagePipe.Transform.NeutralResolver do
  @moduledoc """
  The neutral default resolver strategy and the delegation target for carried
  strategies.

  Implements `ImagePipe.Resolver` with the product-neutral deferred-
  orientation execution policy. A dialect-specific carried strategy (e.g. the
  TwicPics resolver under `parser/*`) composes its own lowering with this
  module's `display_frame_advance/2` and `plain_advance/2` to reuse the
  neutral flush policy instead of re-deriving it, and delegates the tags this
  module emits back to its `continue/4` at the measure seam. A dialect that
  assembles its own chain directly (rather than through the `ImagePipe.Parser`/
  `Resolver` boundary) may call those same helpers without implementing
  `ImagePipe.Resolver` at all.

  The source-dependent `%Operation.Resize{mode: :auto}` fill-vs-fit rule is
  product-neutral and lives here (`resolve_mode/2`; imgproxy `ResizeAuto`
  parity, #182/#448) — any dialect may emit it with no resolver.
  """

  # Neutral geometry resolver: owns the deferred-orientation execution policy
  # (#146/#182/#185/#211) under the ImagePipe.Resolver contract. For each plan
  # operation it emits the executable ops to run — with every orientation flush
  # (including the pre-materialize flush that smart/detect crops and
  # arbitrary/mirrored rotates need) made explicit as %Operation.Flush{}, and
  # every zero-op State write expressed as a shape advance. All geometry is
  # delegated to Lowering/ResizePlanning public helpers and the executable
  # ops' own pure dims functions; nothing is re-derived.
  #
  # Continuation classification: :measure iff the post-op dims cannot be
  # computed purely — resize, trim, and arbitrary-angle/mirrored rotate;
  # everything else advances the shape purely. Each :measure carries a named
  # tag ({:measure, tag, nil}); the matching continue/4 clause below is the
  # single place that says what happens after the measure.
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
  alias ImagePipe.Plan.Operation.Trim, as: PlanTrim
  alias ImagePipe.Transform.Lowering
  alias ImagePipe.Transform.Operation.Crop
  alias ImagePipe.Transform.Operation.ExtendCanvas
  alias ImagePipe.Transform.Operation.Flush
  alias ImagePipe.Transform.Operation.Padding
  alias ImagePipe.Transform.Operation.Resize
  alias ImagePipe.Transform.Orientation
  alias ImagePipe.Transform.PendingOrientation
  alias ImagePipe.Transform.ResizePlanning
  alias ImagePipe.Transform.SourceShape

  @impl ImagePipe.Resolver
  def init, do: nil

  @doc """
  Behavioral version of the neutral resolution algorithms. The neutral column
  now owns the `:auto` fill-vs-fit bucketing (`resolve_mode/2`, #448) in
  addition to the deferred-orientation execution policy, so a change to that
  rule bumps here — see `ImagePipe.Resolver.behavior_version/0` for the ETag
  implications.
  """
  @impl ImagePipe.Resolver
  def behavior_version, do: 1

  @impl ImagePipe.Resolver
  def resolve(%SourceShape{} = shape, nil, operation) do
    do_resolve(operation, shape)
  end

  @doc false
  @spec resolve_late_bound_guide(SourceShape.t(), CropGuided.t() | PlanResize.t()) ::
          {[struct()], ImagePipe.Resolver.continuation()}
  def resolve_late_bound_guide(%SourceShape{} = shape, %CropGuided{} = operation) do
    case pending_class(shape) do
      :pending ->
        preflush_guided_crop(operation, shape, &compensate_late_bound_crop/2)

      _none_or_identity ->
        do_resolve(operation, shape)
    end
  end

  def resolve_late_bound_guide(%SourceShape{} = shape, %PlanResize{} = operation) do
    operation = %PlanResize{operation | mode: resolve_mode(operation, shape)}

    if operation.mode != :cover do
      raise ArgumentError,
            "late-bound guide resolution supports only cover resize operations, got: " <>
              inspect(operation)
    end

    resolve_guided_resize(operation, shape, &compensate_late_bound_crop/2)
  end

  def resolve_late_bound_guide(%SourceShape{}, operation) do
    raise ArgumentError,
          "late-bound guide resolution does not support #{inspect(operation.__struct__)}"
  end

  # ── continue: the named post-measure clauses (issue #446) ─────────────────
  # One clause per tag; `shape` is the pre-op shape resolve/3 saw (the driver
  # threads it), so each clause reconstructs its result from the tag, the
  # pre-op shape, and the measured dims alone.

  @impl ImagePipe.Resolver
  def continue(:rotate, {w, h}, %SourceShape{} = shape, nil),
    do: {%{shape | width: w, height: h, frame: :display, pending_orientation: nil}, nil}

  def continue(:trim, {w, h}, %SourceShape{} = shape, nil) do
    pending =
      case pending_class(shape) do
        :pending -> shape.pending_orientation
        _none_or_identity -> nil
      end

    {%{shape | width: w, height: h, pending_orientation: pending, decode_shrink: nil}, nil}
  end

  def continue(:resize, {w, h}, %SourceShape{} = shape, nil),
    do: {%{shape | width: w, height: h, decode_shrink: nil}, nil}

  def continue({:resize_tail, tail}, {w, h}, %SourceShape{} = shape, nil) do
    {box_w, box_h} = staged_tail_dims(tail, {w, h})
    {tail, advance(%{shape | width: box_w, height: box_h, decode_shrink: nil})}
  end

  # The pending-resize stage: the (already compensated) tail runs, then the
  # flush; the shape advances to the display frame with the quarter-turn swap.
  def continue({:resize_flush_tail, tail}, {w, h}, %SourceShape{} = shape, nil) do
    po = shape.pending_orientation
    {box_w, box_h} = staged_tail_dims(tail, {w, h})
    {display_w, display_h} = swap_if_quarter_turn({box_w, box_h}, po)

    {tail ++ [%Flush{}],
     advance(%{
       shape
       | width: display_w,
         height: display_h,
         frame: :display,
         pending_orientation: nil,
         decode_shrink: nil
     })}
  end

  # ── rotate / flip folds ───────────────────────────────────────────────────
  # Right-angle, non-mirrored rotation defers into the pending orientation
  # (lossless vips_rot at the flush, imgproxy parity, #211 seam avoidance).
  defp do_resolve(%PlanRotate{angle: angle, mirror: false}, %SourceShape{} = shape)
       when angle in [0, 90, 180, 270] do
    po = shape.pending_orientation || %PendingOrientation{}
    {[], advance(%{shape | pending_orientation: PendingOrientation.fold_rotate(po, angle)})}
  end

  # Arbitrary angle or mirror: a materializing op. An explicit flush before the
  # rotate lands the rotation in the display frame (EXIF auto-orient -> then
  # user rotation). decode_shrink stays untouched (nothing clears it at a
  # rotate; no parser places a shrink consumer after rotation).
  defp do_resolve(%PlanRotate{} = operation, %SourceShape{} = shape) do
    ops = Lowering.executable_operations(operation, shape)

    case pending_class(shape) do
      :pending -> {[%Flush{} | ops], measure(:rotate)}
      _none_or_identity -> {ops, measure(:rotate)}
    end
  end

  defp do_resolve(%PlanFlip{axis: axis}, %SourceShape{} = shape) do
    po = shape.pending_orientation || %PendingOrientation{}
    {[], advance(%{shape | pending_orientation: PendingOrientation.fold_flip(po, axis)})}
  end

  # ── region crop ───────────────────────────────────────────────────────────
  # Runs literally on oriented pixels: flush pending first. The lowering frame
  # is the post-flush frame — region coords rescale against the quarter-turn-
  # swapped per-axis decode_shrink factors (#185), while the out-of-bounds
  # check reads the stored original storage-frame dims when shrink-on-load
  # fired (the flush does not touch source_dimensions), else the live
  # post-flush display dims.
  # The crop clears the source frame (#180): dims = crop box, decode_shrink nil.
  defp do_resolve(%CropRegion{} = operation, %SourceShape{} = shape) do
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
  defp do_resolve(%CropGuided{} = operation, %SourceShape{} = shape) do
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
        preflush_guided_crop(operation, shape, &compensate_crop/2)

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
  # flush so the cover result-crop and tail are post-flush/literal (see
  # pending_resize_ops). Plain path: no compensation, no flush.
  #
  # A resize's realized dims can round ±1 off the naive target, so any op after
  # it must be parameterized against the MEASURED post-resize dims: the
  # emission stages at the realized-dims seam (spec §4.4). The resize is always
  # the terminal op of its stage; the stage continue/4 returns carries the
  # tail (result crop and/or flush), with the shape advanced purely from the
  # measured dims — the crop box via Crop.resolved_box_dims (the exact integers
  # Crop.execute produces on an image of that size) and the flush's exact axis
  # swap. A bare [resize] emission needs no stage and keeps the final form.
  defp do_resolve(%PlanResize{} = operation, %SourceShape{} = shape) do
    operation = %PlanResize{operation | mode: resolve_mode(operation, shape)}

    resolve_guided_resize(operation, shape, &compensate_crop/2)
  end

  # ── padding / pixelate / gradient ─────────────────────────────────────────
  # These run AFTER rotateAndFlip in imgproxy's order, i.e. in the display
  # frame; with an orientation still pending they flush first so the op decides
  # in the display frame. An identity pending is cleared without a flush
  # (streaming fast path preserved).
  defp do_resolve(%PlanPadding{} = operation, %SourceShape{} = shape),
    do:
      display_frame_advance(
        Lowering.padding_executables(operation, padding_scale(operation)),
        shape
      )

  defp do_resolve(%PlanPixelate{} = operation, %SourceShape{} = shape),
    do: display_frame_advance(Lowering.executable_operations(operation, shape), shape)

  defp do_resolve(%PlanGradient{} = operation, %SourceShape{} = shape),
    do: display_frame_advance(Lowering.executable_operations(operation, shape), shape)

  # ── trim ──────────────────────────────────────────────────────────────────
  # imgproxy's one pre-orientation op: it trims the storage frame. Trim needs
  # random access, so the chain's copy-only materialize copies the un-oriented
  # pixels and the pending is kept for a later flush. Never emits a %Flush{}.
  # An identity pending clears on the shape here (the materialize is trim's
  # flush site, with no pixel work). decode_shrink: nil is a never-shrank
  # reaffirmation — the decode planner returns 1.0 for trim chains.
  # The post-trim pending decision lives in continue(:trim, …).
  defp do_resolve(%PlanTrim{} = operation, %SourceShape{} = shape) do
    {Lowering.executable_operations(operation, shape), measure(:trim)}
  end

  # ── canvas ────────────────────────────────────────────────────────────────
  defp do_resolve(%Canvas{} = operation, %SourceShape{} = shape) do
    ops = Lowering.canvas_executables(operation, 1.0)
    plain_advance(ops, shape)
  end

  # ── background / effects (no deferred-orientation handling) ──────────────
  # These run plain, in the storage frame, with any
  # pending intact, and never trigger a flush. Effects are dimension-neutral.
  defp do_resolve(operation, %SourceShape{} = shape) do
    ops = Lowering.executable_operations(operation, shape)
    plain_advance(ops, shape)
  end

  # The composition-scale policy for a padding op: a literal ratio is its own
  # scale.
  defp padding_scale(%PlanPadding{pixel_ratio: {:ratio, n, d}}), do: n / d

  @doc """
  Resolve a `%Plan.Operation.Resize{}`'s mode against the source shape,
  bucketing the source-dependent `:auto` rule to its concrete `:fit`/`:cover`
  branch; concrete modes pass through unchanged.

  `:auto` fills when the source and target share an orientation and fits
  otherwise, compared by the sign of the width−height difference with a square
  (`diff == 0`) sharing the landscape bucket, on the DISPLAY axes (imgproxy's
  `ResizeAuto`, processing/prepare.go:88-97; #182/#233). Its provenance is
  imgproxy, but the rule is product-neutral, so the neutral column owns it and
  any dialect may emit `:auto` with no resolver.

  Public so a carried strategy that needs the concrete branch before delegation
  (e.g. the imgproxy no-enlarge padding-scale cap) shares this one rule instead
  of re-deriving it.
  """
  @spec resolve_mode(PlanResize.t(), SourceShape.t()) :: :fit | :cover | :stretch
  def resolve_mode(%PlanResize{mode: :auto} = operation, %SourceShape{} = shape) do
    # ExtractGeometry swaps the source dims for a quarter turn before the
    # comparison, so classify against the display-frame source: an EXIF 5–8 /
    # rot:90/270 source is not judged on transposed axes (#182).
    {src_w, src_h} = display_source_dims(shape)

    auto_branch(
      orientation_diff(src_w, src_h),
      orientation_diff(
        tagged_logical_pixels(operation.width),
        tagged_logical_pixels(operation.height)
      )
    )
  end

  def resolve_mode(%PlanResize{mode: mode}, %SourceShape{}), do: mode

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

  defp display_source_dims(%SourceShape{pending_orientation: %PendingOrientation{} = po} = shape),
    do: swap_if_quarter_turn({shape.width, shape.height}, po)

  defp display_source_dims(%SourceShape{width: w, height: h}), do: {w, h}

  # The compensated executable expansion for a resize under a non-identity
  # pending. A quarter turn cannot be compensated by swapping the *request* and
  # resolving in the storage frame for a cover: imgproxy resolves scale in the
  # DISPLAY frame and swaps only the final scale factors, so the min-dimension
  # cross-axis coupling happens on the display axes. The quarter-turn cover
  # therefore resolves in the display frame and only its result-crop is
  # compensated; every other branch swaps the resize request and compensates a
  # trailing crop like a gravity crop.
  defp preflush_guided_crop(%CropGuided{} = operation, %SourceShape{} = shape, compensate) do
    po = shape.pending_orientation

    lowering_shape = %SourceShape{
      shape
      | decode_shrink: orient_decode_shrink(shape.decode_shrink, po)
    }

    [crop] =
      ops =
      operation
      |> Lowering.executable_operations(lowering_shape)
      |> Enum.map(&compensate.(&1, po))

    {live_w, live_h} = SourceShape.live_dims(shape)
    {box_w, box_h} = Crop.resolved_box_dims(crop, live_w, live_h)

    {ops, advance(%{shape | width: box_w, height: box_h, decode_shrink: nil})}
  end

  defp resolve_guided_resize(%PlanResize{} = operation, %SourceShape{} = shape, compensate) do
    case pending_class(shape) do
      :pending ->
        po = shape.pending_orientation
        [resize | tail] = pending_resize_ops(operation, po, shape, compensate)
        {[resize], measure({:resize_flush_tail, tail})}

      _none_or_identity ->
        plain_resize_stage(Lowering.executable_operations(operation, shape))
    end
  end

  defp pending_resize_ops(
         %PlanResize{} = operation,
         %PendingOrientation{} = po,
         %SourceShape{} = shape,
         compensate_crop
       ) do
    if PendingOrientation.quarter_turn?(po) and
         ResizePlanning.cover_resize?(operation, shape) do
      operation
      |> ResizePlanning.cover_resize_and_crop_display_frame(
        shape,
        Lowering.tagged_executable_gravity(operation.guide)
      )
      |> Enum.map(fn
        %Crop{} = crop -> compensate_crop.(crop, po)
        other -> other
      end)
    else
      operation
      |> Lowering.executable_operations(shape)
      |> compensate_resize(po, compensate_crop)
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

  # A plain resize with an empty tail is the final form (bare [resize]); with a
  # result-crop tail it stages, advancing the shape from the measured dims.
  defp plain_resize_stage([resize]), do: {[resize], measure(:resize)}
  defp plain_resize_stage([resize | tail]), do: {[resize], measure({:resize_tail, tail})}

  # Realized dims of a resize's post-resize tail, computed purely against the
  # measured post-resize dims. The tail is at most one result crop; its box is
  # bounded to the measured frame exactly as Crop.execute bounds it.
  defp staged_tail_dims([], {w, h}), do: {w, h}
  defp staged_tail_dims([%Crop{} = crop], {w, h}), do: Crop.resolved_box_dims(crop, w, h)

  @doc """
  Advance for an op that must decide in the DISPLAY frame (imgproxy order:
  after rotateAndFlip): with a non-identity pending the flush fires first, an
  identity pending clears without a flush (streaming fast path). Public so a
  carried strategy can compose its own lowering with the neutral flush
  policy.
  """
  @spec display_frame_advance([struct()], SourceShape.t()) ::
          {[struct()], ImagePipe.Resolver.continuation()}
  def display_frame_advance(ops, %SourceShape{} = shape) do
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

  @doc """
  Plain advance: run in the current frame with any pending intact, never flush;
  canvas geometry advances the shape, everything else is dimension-neutral.
  """
  @spec plain_advance([struct()], SourceShape.t()) ::
          {[struct()], ImagePipe.Resolver.continuation()}
  def plain_advance(ops, %SourceShape{} = shape),
    do: {ops, advance(plain_ops_advance(ops, shape))}

  defp apply_op_geometry([%Padding{top: top, right: right, bottom: bottom, left: left}], {w, h}),
    do: {w + left + right, h + top + bottom}

  defp apply_op_geometry(_ops, {w, h}), do: {w, h}

  defp advance(%SourceShape{} = shape), do: {:advance, shape, nil}

  defp measure(tag), do: {:measure, tag, nil}

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

  # A pre-flush storage-frame gravity crop under a pending orientation. The crop
  # box and the odd-pixel discard side (a centered crop with an odd extent
  # difference discards one extra pixel; the storage-frame near-side bias lands
  # on the wrong display side when the flush reverses that storage axis, #146
  # Bug 2) always compensate for the pending turn; the anchor offsets remap only
  # when the gravity is already concrete.
  #
  # A strategy-deferred gravity carries a storage-frame point the plan's
  # strategy substitutes AFTER this compensation (Pinned behavior 5) — its
  # offsets are not yet concrete, so it must NOT be gravity-remapped and takes
  # box + center_bias only: a nil point substitutes to the centred anchor, which
  # needs the discard-side bias; a set point substitutes to `:fp`, which ignores
  # it. Smart/detect gravities run on display-frame pixels (flush-before) and
  # stay fully literal.
  defp compensate_crop(
         %Crop{crop_from: :gravity, gravity: gravity} = crop,
         %PendingOrientation{} = po
       ) do
    if materializing_gravity?(gravity) do
      crop
    else
      crop
      |> remap_concrete_offsets(po)
      |> put_center_bias(po)
      |> swap_box_for_quarter_turn(po)
    end
  end

  defp compensate_crop(%Crop{} = crop, %PendingOrientation{}), do: crop

  defp compensate_late_bound_crop(
         %Crop{crop_from: :gravity} = crop,
         %PendingOrientation{} = po
       ) do
    crop
    |> put_center_bias(po)
    |> swap_box_for_quarter_turn(po)
  end

  defp compensate_late_bound_crop(%Crop{} = crop, %PendingOrientation{}), do: crop

  # The executable crop carries offsets in their tagged unit form.
  # Orientation.compensate_gravity_for/2 ports imgproxy's RotateAndFlip, which
  # operates on the bare float offset: unwrap to the magnitude, compensate, then
  # re-wrap — and on a quarter turn the X/Y *values* swap, so the unit wrappers
  # swap with them. Only a concrete anchor/fp gravity has offsets to remap; a
  # non-concrete gravity (a strategy fills it later, in the storage frame)
  # passes through untouched.
  defp remap_concrete_offsets(
         %Crop{gravity: {tag, _, _} = gravity} = crop,
         %PendingOrientation{} = po
       )
       when tag in [:anchor, :fp] do
    {x_unit, x_value} = split_offset(crop.x_offset)
    {y_unit, y_value} = split_offset(crop.y_offset)

    {gravity, x_value, y_value} =
      Orientation.compensate_gravity_for({gravity, x_value, y_value}, po)

    {x_unit, y_unit} =
      if PendingOrientation.quarter_turn?(po), do: {y_unit, x_unit}, else: {x_unit, y_unit}

    %Crop{crop | gravity: gravity, x_offset: x_unit.(x_value), y_offset: y_unit.(y_value)}
  end

  defp remap_concrete_offsets(%Crop{} = crop, %PendingOrientation{}), do: crop

  defp put_center_bias(%Crop{} = crop, %PendingOrientation{} = po),
    do: %Crop{crop | center_bias: Orientation.center_discard_sides(po)}

  defp swap_box_for_quarter_turn(%Crop{} = crop, %PendingOrientation{} = po) do
    if PendingOrientation.quarter_turn?(po),
      do: %Crop{crop | width: crop.height, height: crop.width},
      else: crop
  end

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
  defp compensate_resize(operations, %PendingOrientation{} = po, compensate_crop) do
    Enum.map(operations, fn
      %Resize{} = resize ->
        if PendingOrientation.quarter_turn?(po), do: Orientation.swap_resize(resize), else: resize

      %Crop{} = crop ->
        compensate_crop.(crop, po)

      other ->
        other
    end)
  end
end
