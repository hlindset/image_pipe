defmodule ImagePipe.Dialect.Imgproxy.Pipeline do
  @moduledoc """
  Inline per-pipeline geometry for the imgproxy dialect.

  Scoping reproduces `ImagePipe.Transform.Executor.execute_pipeline/4`, NOT
  `ImagePipe.Dialect.Native.Pipeline` [spec §Pipeline 1]: imgproxy `-`
  pipelines each re-seed `SourceShape` from the prior pipeline's output,
  start a fresh carry, and flush pending orientation at their own boundary —
  a pipeline's output is the next pipeline's input, so each ends in the
  display frame. Only the executed image/`State` crosses a pipeline boundary.

  Native's `then` groups are the opposite: one seed, one flush after the last
  group, with the shape threaded continuously. Copying that shape here would
  be silently wrong — a group boundary is not a pipeline boundary.
  """

  alias ImagePipe.Dialect.Imgproxy.PipelineRequest
  alias ImagePipe.Plan.Operation
  alias ImagePipe.Plan.Operation.Canvas
  alias ImagePipe.Plan.Operation.Padding, as: PlanPadding
  alias ImagePipe.Plan.Operation.Resize, as: PlanResize
  alias ImagePipe.Transform.Chain
  alias ImagePipe.Transform.Lowering
  alias ImagePipe.Transform.NeutralResolver
  alias ImagePipe.Transform.Operation.Flush
  alias ImagePipe.Transform.Operation.Resize
  alias ImagePipe.Transform.PendingOrientation
  alias ImagePipe.Transform.ResizePlanning
  alias ImagePipe.Transform.SourceGeometry
  alias ImagePipe.Transform.SourceShape
  alias ImagePipe.Transform.State

  # Reachable `continue/4` recursion is at most depth 1 for this operation set
  # (a resize's `{:resize_tail, _}`/`{:resize_flush_tail, _}` stage always
  # resolves to a terminal `{:advance, _, nil}`). This cap is defensive: an
  # unexpected deeper measurement is a core-contract bug and must crash, not
  # degrade — see `follow/5`, which has no catch-all clause past it.
  @max_continuation_depth 4

  # The carry a pipeline starts with. Fresh per pipeline: a `-` boundary
  # re-runs the equivalent of the framework strategy's `init/0`, so a scale
  # computed by one pipeline's resize can never reach the next pipeline's
  # padding (`Executor.execute_pipeline/4` — "a fresh init/0 per pipeline").
  @empty_carry %{effective_padding_scale: nil, canvas_preserving_padding_scale: nil}

  @default_gravity {:anchor, :center, :center}

  @doc """
  Executes every `-` pipeline of an imgproxy request against a decoded state.

  `opts` accepts the same runtime options threaded to `Chain.execute/3`
  (telemetry, etc). It also accepts three test-only overrides — `:chain`,
  `:measure_dims`, `:continue` — mirroring `Executor.run/5`'s own injectable
  seams, defaulting to the real `Chain.execute/3`, a live Vix header read, and
  `NeutralResolver.continue/4` respectively. Real callers never set these.
  """
  @spec run(State.t(), SourceGeometry.t(), %{pipelines: [PipelineRequest.t()]}, keyword()) ::
          {:ok, State.t()} | {:error, {:transform, term()}}
  def run(%State{} = state, %SourceGeometry{} = _geometry, %{pipelines: pipelines}, opts) do
    ctx = build_ctx(opts)

    Enum.reduce_while(pipelines, {:ok, state}, fn %PipelineRequest{} = preq, {:ok, state} ->
      case run_pipeline(state, preq, ctx) do
        {:ok, %State{} = state} -> {:cont, {:ok, state}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  # Per-pipeline: fresh shape seed, fresh carry, own flush boundary. The seed
  # reads the STATE (not a threaded shape) — the previous pipeline's boundary
  # already synced State from its final shape, so the executed image is the
  # only thing that crosses.
  defp run_pipeline(%State{} = state, %PipelineRequest{} = preq, ctx) do
    {w, h} = State.effective_source_dims(state)

    shape =
      SourceShape.seed(%{
        width: w,
        height: h,
        pending_orientation: state.pending_orientation,
        decode_shrink: state.decode_shrink
      })

    pctx = pipeline_ctx(preq)

    with {:ok, state, shape, _carry} <-
           run_ops(state, shape, @empty_carry, operations(preq, shape), pctx, ctx) do
      flush_boundary(state, shape, ctx)
    end
  end

  # The padding/canvas mode is parse-time-decidable request data [spec D5]:
  # nothing here consults runtime geometry, which is exactly why the framework's
  # `{:effective, fallback, mode}` marker is pure redundancy once one module owns
  # both emit and run. Ports `plan_builder.ex:677-686` and the whole predicate
  # closure it reaches — including `resize_target_ratio/1`, which reads
  # width/height rather than any `extend*` field.
  defp pipeline_ctx(%PipelineRequest{} = preq) do
    mode =
      if extend_operation_requested?(preq) or extend_aspect_ratio_emits?(preq),
        do: :canvas_preserving,
        else: :resize

    %{mode: mode, dpr_fallback: preq.dpr || 1.0}
  end

  defp extend_operation_requested?(%PipelineRequest{extend: false, extend_requested: true}),
    do: false

  defp extend_operation_requested?(%PipelineRequest{} = request) do
    request.extend == true or
      not is_nil(request.extend_gravity) or
      not is_nil(request.extend_x_offset) or
      not is_nil(request.extend_y_offset)
  end

  defp extend_aspect_ratio_requested?(%PipelineRequest{extend_aspect_ratio: extend?}), do: extend?

  defp extend_aspect_ratio_emits?(%PipelineRequest{} = request) do
    extend_aspect_ratio_requested?(request) and match?({:ok, _}, resize_target_ratio(request))
  end

  defp resize_target_ratio(%PipelineRequest{width: {:pixels, w}, height: {:pixels, h}})
       when w > 0 and h > 0,
       do: {:ok, {w, h}}

  defp resize_target_ratio(%PipelineRequest{}), do: :no_ratio

  # -- semantic op assembly -------------------------------------------------
  #
  # A subset of `plan_builder.ex`'s stage order (trim -> orientation -> crop ->
  # resize -> effects -> canvas -> padding -> background): the stages the carry
  # contract needs. Task 9 lands the remaining stages around these.
  #
  # The emission rules are ported rather than approximated, because they decide
  # whether the carry exists at all: `resize_rule_requested?/1` means a bare
  # `dpr` with no width/height still emits an `:auto`/`:auto` resize, so the
  # carry is populated (and, for a no-enlarge request, capped to 1.0) instead of
  # falling back. Approximating this would make the dialect diverge from the
  # framework arm precisely on the padding-scale rows the dual-run suite compares.

  defp operations(%PipelineRequest{} = preq, _shape) do
    [
      trim_op(preq),
      resize_op(preq),
      blur_op(preq),
      canvas_op(preq),
      padding_op(preq)
    ]
    |> Enum.reject(&is_nil/1)
  end

  defp trim_op(%PipelineRequest{trim: nil}), do: nil

  defp trim_op(%PipelineRequest{trim: trim}) do
    {:ok, op} = Operation.trim(trim)
    op
  end

  # Ports `plan_builder.ex:363-415`: an explicit geometry OR any resize rule
  # (min_width/min_height/zoom/dpr) emits a resize; nothing else does.
  defp resize_op(%PipelineRequest{width: nil, height: nil} = preq),
    do: resize_from_rule(preq)

  defp resize_op(%PipelineRequest{width: {:pixels, 0}, height: {:pixels, 0}} = preq),
    do: resize_from_rule(preq)

  defp resize_op(%PipelineRequest{} = preq), do: build_resize(preq)

  defp resize_from_rule(%PipelineRequest{} = preq) do
    if resize_rule_requested?(preq), do: build_resize(preq)
  end

  defp resize_rule_requested?(%PipelineRequest{} = preq) do
    not is_nil(preq.min_width) or
      not is_nil(preq.min_height) or
      not is_nil(preq.zoom_x) or
      not is_nil(preq.zoom_y) or
      not is_nil(preq.dpr)
  end

  defp build_resize(%PipelineRequest{} = preq) do
    {:ok, op} =
      Operation.resize(
        resize_mode(preq.resizing_type),
        resize_dimension(preq.width),
        resize_dimension(preq.height),
        dpr: preq.dpr || 1.0,
        enlargement: if(preq.enlarge, do: :allow, else: :deny)
      )

    op
  end

  defp resize_mode(:fit), do: :fit
  defp resize_mode(:fill), do: :cover
  defp resize_mode(:fill_down), do: :cover
  defp resize_mode(:force), do: :stretch
  defp resize_mode(:auto), do: :auto

  defp resize_dimension(nil), do: :auto
  defp resize_dimension({:pixels, 0}), do: :auto
  defp resize_dimension({:pixels, value}), do: {:px, value}

  defp blur_op(%PipelineRequest{effects: %{blur: nil}}), do: nil

  defp blur_op(%PipelineRequest{effects: %{blur: sigma}}) do
    {:ok, op} = Operation.blur(sigma)
    op
  end

  # Ports `plan_builder.ex:428-444`'s extend operation (anchor placements only;
  # Task 9 adds the focal-point form).
  defp canvas_op(%PipelineRequest{} = preq) do
    if extend_operation_requested?(preq) do
      {:ok, op} =
        Operation.canvas(
          canvas_dimension(preq.width),
          canvas_dimension(preq.height),
          canvas_placement(preq.extend_gravity || @default_gravity),
          fill: :transparent,
          overflow: :reject,
          x_offset: preq.extend_x_offset || 0.0,
          y_offset: preq.extend_y_offset || 0.0
        )

      op
    end
  end

  defp canvas_dimension(nil), do: :auto
  defp canvas_dimension({:pixels, 0}), do: :auto
  defp canvas_dimension({:pixels, value}), do: {:px, value}

  defp canvas_placement({:anchor, x, y}), do: anchor_guide(x, y)

  defp anchor_guide(:center, :center), do: :center
  defp anchor_guide(:left, :top), do: :top_left
  defp anchor_guide(:center, :top), do: :top
  defp anchor_guide(:right, :top), do: :top_right
  defp anchor_guide(:left, :center), do: :left
  defp anchor_guide(:right, :center), do: :right
  defp anchor_guide(:left, :bottom), do: :bottom_left
  defp anchor_guide(:center, :bottom), do: :bottom
  defp anchor_guide(:right, :bottom), do: :bottom_right

  # The `{:effective, fallback, mode}` marker is NEVER constructed [spec D5]:
  # the dialect owns both emit and run, so the mode lives in `pipeline_ctx/1`
  # and the scale is handed to `Lowering.padding_executables/2` as an argument.
  # `pixel_ratio` is inert here — `padding_executables/2` reads only the sides
  # and the fill — but it is emitted as the request's own concrete ratio rather
  # than left to default, so the Plan op still describes the request truthfully.
  defp padding_op(%PipelineRequest{
         padding_top: 0,
         padding_right: 0,
         padding_bottom: 0,
         padding_left: 0
       }),
       do: nil

  defp padding_op(%PipelineRequest{} = preq) do
    {:ok, op} =
      Operation.padding(
        {:px, preq.padding_top},
        {:px, preq.padding_right},
        {:px, preq.padding_bottom},
        {:px, preq.padding_left},
        pixel_ratio: dpr_ratio(preq),
        fill: :transparent
      )

    op
  end

  defp dpr_ratio(%PipelineRequest{dpr: nil}), do: {:ratio, 1, 1}

  defp dpr_ratio(%PipelineRequest{dpr: dpr}) do
    {:ok, %{dpr: ratio}} = Operation.resize(:fit, :auto, :auto, dpr: dpr)
    ratio
  end

  defp run_ops(state, shape, carry, ops, pctx, ctx) do
    Enum.reduce_while(ops, {:ok, state, shape, carry}, fn plan_op, {:ok, state, shape, carry} ->
      case run_op(state, shape, carry, plan_op, pctx, ctx) do
        {:ok, _state, _shape, _carry} = ok -> {:cont, ok}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  # The imgproxy decision column. Everything else delegates to the neutral
  # column below. `resolve/3` and `continue/4` are called as stateless toolkit
  # functions (`nil` carried state throughout): no `ImagePipe.Resolver` strategy
  # dispatch is involved, and the carry is this module's own pipeline-local
  # variable, not resolver state.

  # The carry is computed HERE, from the PRE-resolve shape, before any
  # continuation is followed — reproducing `resolver.ex:37-49` exactly. It is
  # never recomputed in `follow/5` [spec §Pipeline 2 "update point"], and the
  # incoming carry is discarded: a resize replaces both slots outright.
  defp run_op(state, shape, _carry, %PlanResize{} = op, _pctx, ctx) do
    # The neutral column buckets `:auto` (`NeutralResolver.resolve_mode/2`,
    # #448); read the concrete branch back to size the no-enlarge cap, then
    # delegate the operation unchanged for the neutral column to lower.
    branch = NeutralResolver.resolve_mode(op, shape)

    carry = %{
      effective_padding_scale: padding_scale(op, shape, branch, :resize),
      canvas_preserving_padding_scale: padding_scale(op, shape, branch, :canvas_preserving)
    }

    state = overlay(state, shape)
    {ops, continuation} = NeutralResolver.resolve(shape, nil, op)

    with {:ok, state} <- run_chain(ctx, state, ops),
         {:ok, state, shape} <- follow(state, shape, continuation, ctx, 0) do
      {:ok, state, shape, carry}
    end
  end

  defp run_op(state, shape, carry, %PlanPadding{} = op, pctx, ctx) do
    state = overlay(state, shape)
    ops = Lowering.padding_executables(op, padding_scale_for(pctx, carry))
    {ops, continuation} = NeutralResolver.display_frame_advance(ops, shape)

    with {:ok, state} <- run_chain(ctx, state, ops),
         {:ok, state, shape} <- follow(state, shape, continuation, ctx, 0) do
      {:ok, state, shape, carry}
    end
  end

  defp run_op(state, shape, carry, %Canvas{} = op, _pctx, ctx) do
    state = overlay(state, shape)
    ops = Lowering.canvas_executables(op, carry.canvas_preserving_padding_scale || 1.0)
    {ops, continuation} = NeutralResolver.plain_advance(ops, shape)

    with {:ok, state} <- run_chain(ctx, state, ops),
         {:ok, state, shape} <- follow(state, shape, continuation, ctx, 0) do
      {:ok, state, shape, carry}
    end
  end

  # Neutral delegation. Carries the pipeline-local carry across untouched — an
  # effect between the resize and the padding must not lose the stashed
  # DprScale (the regression the framework resolver's own delegation comment
  # names).
  defp run_op(state, shape, carry, plan_op, _pctx, ctx) do
    state = overlay(state, shape)
    {ops, continuation} = NeutralResolver.resolve(shape, nil, plan_op)

    with {:ok, state} <- run_chain(ctx, state, ops),
         {:ok, state, shape} <- follow(state, shape, continuation, ctx, 0) do
      {:ok, state, shape, carry}
    end
  end

  # ── carry consumption ─────────────────────────────────────────────────────
  # The two fallbacks are DIFFERENT (`resolver.ex:151-168`): padding falls back
  # to the request dpr, canvas (below, in its `run_op/6` clause) to 1.0.
  defp padding_scale_for(%{mode: :resize, dpr_fallback: fb}, %{effective_padding_scale: s}),
    do: s || fb

  defp padding_scale_for(
         %{mode: :canvas_preserving, dpr_fallback: fb},
         %{canvas_preserving_padding_scale: s}
       ),
       do: s || fb

  # ── no-enlarge padding/DPR scale (#237) ───────────────────────────────────
  # Copied VERBATIM from `lib/image_pipe/parser/imgproxy/resolver.ex:87-174` —
  # parity-critical arithmetic reproducing imgproxy's unconditional `!Enlarge()`
  # `DprScale = min(DPR, min(wshrink, hshrink))` block (prepare.go calcScale ->
  # padding.go/extend.go). Do not "improve" it.
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

  defp display_source_dims(%SourceShape{pending_orientation: po} = shape) do
    if not is_nil(po) and PendingOrientation.quarter_turn?(po),
      do: {shape.height, shape.width},
      else: {shape.width, shape.height}
  end

  defp build_ctx(opts) do
    %{
      chain: Keyword.get(opts, :chain, &Chain.execute/3),
      measure_dims: Keyword.get(opts, :measure_dims, &default_measure_dims/1),
      continue: Keyword.get(opts, :continue, &NeutralResolver.continue/4),
      opts: opts
    }
  end

  defp default_measure_dims(image), do: {Image.width(image), Image.height(image)}

  # THE sync rule, one site, mirroring `Executor`'s private `overlay/2`
  # exactly: every executable op's execute-time `State.effective_source_dims/
  # decode_shrink/pending_orientation` read routes through the resolver-
  # advanced shape, because `Chain.execute/3` reads those off `State`, not off
  # the shape directly (resolve-time reads, inside `NeutralResolver`/
  # `Lowering`, take the shape directly and need no overlay).
  defp overlay(%State{} = state, %SourceShape{} = shape) do
    %State{
      state
      | pending_orientation: shape.pending_orientation,
        decode_shrink: shape.decode_shrink,
        source_dimensions: {shape.width, shape.height}
    }
  end

  # Terminal: every reachable `continue/4` clause for this operation set ends
  # in a bare `{:advance, shape, nil}` — either directly (`:trim`, `:resize`)
  # or after executing one further tail stage. No clause matches past
  # `@max_continuation_depth` — an unexpected deeper measurement is a
  # core-contract bug and must crash here, not degrade silently.
  defp follow(state, _pre_shape, {:advance, shape, nil}, _ctx, _depth),
    do: {:ok, state, shape}

  defp follow(state, pre_shape, {:measure, tag, nil}, ctx, depth)
       when depth < @max_continuation_depth do
    dims = ctx.measure_dims.(state.image)

    case ctx.continue.(tag, dims, pre_shape, nil) do
      {%SourceShape{} = shape, nil} ->
        {:ok, state, shape}

      {tail_ops, continuation} ->
        with {:ok, state} <- run_chain(ctx, state, tail_ops) do
          follow(state, pre_shape, continuation, ctx, depth + 1)
        end
    end
  end

  defp run_chain(ctx, state, ops) do
    case ctx.chain.(state, ops, ctx.opts) do
      {:ok, _state} = ok -> ok
      {:error, reason} -> {:error, {:transform, reason}}
    end
  end

  # Mirrors `Executor.flush_boundary/4`, called once per PIPELINE (not once
  # per request): syncs State's source-frame fields from the final shape, then
  # flushes a surviving non-identity pending orientation through an explicit
  # `%Flush{}`; an identity pending clears without materializing (the
  # streaming fast path). Unconditional — a pipeline that assembled no
  # operations at all still ends in the display frame.
  defp flush_boundary(%State{} = state, %SourceShape{} = shape, ctx) do
    state = %State{
      state
      | pending_orientation: shape.pending_orientation,
        decode_shrink: shape.decode_shrink,
        source_dimensions: boundary_source_dimensions(shape)
    }

    case shape.pending_orientation do
      nil ->
        {:ok, state}

      %PendingOrientation{} = po ->
        if PendingOrientation.identity?(po) do
          {:ok, %State{state | pending_orientation: nil}}
        else
          run_chain(ctx, state, [%Flush{}])
        end
    end
  end

  defp boundary_source_dimensions(%SourceShape{decode_shrink: nil}), do: nil
  defp boundary_source_dimensions(%SourceShape{width: w, height: h}), do: {w, h}
end
