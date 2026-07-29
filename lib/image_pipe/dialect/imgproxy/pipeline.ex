defmodule ImagePipe.Dialect.Imgproxy.Pipeline do
  @moduledoc """
  Inline per-pipeline geometry for the imgproxy dialect.

  Scoping reproduces `ImagePipe.Transform.Executor`'s per-pipeline scoping, NOT
  `ImagePipe.Dialect.Native.Pipeline` [spec §Pipeline 1]: imgproxy `-`
  pipelines each re-seed `SourceShape` from the prior pipeline's output,
  start a fresh carry, and flush pending orientation at their own boundary —
  a pipeline's output is the next pipeline's input, so each ends in the
  display frame. Only the executed image/`State` crosses a pipeline boundary.

  Native's `then` groups are the opposite: one seed, one flush after the last
  group, with the shape threaded continuously. Copying that shape here would
  be silently wrong — a group boundary is not a pipeline boundary.

  Semantic operation assembly lives in `ImagePipe.Dialect.Imgproxy.Assembly` —
  this module is the resolve-loop driver and the carry math that consumes it.
  """

  alias ImagePipe.Dialect.Imgproxy.Assembly
  alias ImagePipe.Dialect.Imgproxy.CropRequest
  alias ImagePipe.Dialect.Imgproxy.Orientation
  alias ImagePipe.Dialect.Imgproxy.PipelineRequest
  alias ImagePipe.Plan.Operation.Canvas
  alias ImagePipe.Plan.Operation.Padding, as: PlanPadding
  alias ImagePipe.Plan.Operation.Resize, as: PlanResize
  alias ImagePipe.Transform
  alias ImagePipe.Transform.Chain
  alias ImagePipe.Transform.DecodePlanner
  alias ImagePipe.Transform.InputColorManagement
  alias ImagePipe.Transform.Lowering
  alias ImagePipe.Transform.NeutralResolver
  alias ImagePipe.Transform.Operation.Flush
  alias ImagePipe.Transform.Operation.Resize
  alias ImagePipe.Transform.PendingOrientation
  alias ImagePipe.Transform.ResizePlanning
  alias ImagePipe.Transform.SourceGeometry
  alias ImagePipe.Transform.SourceShape
  alias ImagePipe.Transform.State

  @typedoc """
  What `run/4` and `decode_request/2` need of a request: its `-` pipelines, and
  nothing else.

  Structural rather than `Request.t()` on purpose — this module reads exactly one
  field, and the looser contract is what lets the pipeline tests drive `run/4`
  with a bare `%{pipelines: [...]}` instead of assembling a whole `%Request{}`
  around the field under test.

  The `optional(any()) => any()` is load-bearing: Elixir's `%{pipelines: t}`
  shorthand means a **closed** map with that one key, which `%Request{}` — eleven
  fields — can never satisfy. Without it the contract was unsatisfiable by its
  only production caller, and `mix dialyzer` said so.
  """
  @type pipelined_request() :: %{
          required(:pipelines) => [PipelineRequest.t()],
          optional(any()) => any()
        }

  # Reachable `continue/4` recursion is at most depth 1 for this operation set
  # (a resize's `{:resize_tail, _}`/`{:resize_flush_tail, _}` stage always
  # resolves to a terminal `{:advance, _, nil}`). This cap is defensive: an
  # unexpected deeper measurement is a core-contract bug and must crash, not
  # degrade — see `follow/5`, which has no catch-all clause past it.
  @max_continuation_depth 4

  # The carry a pipeline starts with. Fresh per pipeline: a `-` boundary starts
  # a new carry, so a scale computed by one pipeline's resize can never reach
  # the next pipeline's padding.
  @empty_carry %{effective_padding_scale: nil, canvas_preserving_padding_scale: nil}

  @doc """
  The dialect's decode preflight: builds the `DecodePlanner.Request` that
  informs shrink-on-load, from the request's FIRST pipeline only.

  Decode happens once, before any pipeline runs, so only the first pipeline's
  trim/crop/resize/rotate can safely inform it — a later `-` pipeline runs
  against whatever the first already produced, so only the first pipeline may
  drive shrink-on-load.

  Every field is derived to agree with what the planner computes from the
  equivalent op chain (`DecodePlanner.request_from_chain/3`). The two paths
  *converge* rather than approximate each other: this function resolves the same
  per-axis extents that path resolves, and both then hand them to the planner's
  own `ratio_from_targets/4`. What that leaves this function to reproduce is
  three rules:

    * `min_width`/`min_height` disable shrink outright, so a request carrying
      either yields `resize_target: nil` rather than a box;
    * a concrete target is inflated by `dpr` and the per-axis `zoom`, because
      the residual resize will scale up to it and a shrink sized against the
      uninflated box would decode below it and resize a softened image;
    * a zero-sentinel or absent dimension is not a target at all, so an
      auto/auto resize (a bare `dpr:`, say) yields no box.

  Convergence is structural wherever a value is lowered: every value this
  function inflates or clamps by is read back from `Assembly` — the one module
  that lowers the dialect's spellings — so it is *the* value the operation
  carries, not a second derivation of it. `Assembly.crop_dimension/1` for a
  crop's tagged measure, `Assembly.dpr_ratio/1` for the dpr's exact rational.
  Re-deriving either from the raw request value instead is what breaks the
  agreement — see `resize_target/1` and `crop_axis_extent/2`.

  `zoom` is the one exception, and its agreement is *asserted rather than
  structural*: nothing lowers it — `Assembly` hands the operation the same plain
  float and the planner passes floats through untouched — so this function
  re-derives the same `|| 1.0` default `Assembly` applies. The two agree because
  both spell the default identically, which the decode-preflight property pins
  (its factor generator emits `nil`); no lowering guarantees it.

  An axis with no target stays `nil` and an inflated extent stays fractional —
  see `resize_target/1`, and `t:DecodePlanner.Request.resize_target/0` for why
  the field admits both.

  `pipeline_assembly_test.exs`'s sibling `decode_preflight_test.exs` pins that
  agreement against the op-chain path directly rather than restating it, by
  example and by property.
  """
  @spec decode_request(pipelined_request(), SourceGeometry.t()) ::
          DecodePlanner.Request.t()
  def decode_request(
        %{pipelines: [%PipelineRequest{} = preq | _]},
        %SourceGeometry{} = geometry
      ) do
    quarter_turn? = user_quarter_turn?(preq)

    %DecodePlanner.Request{
      resize_target: resize_target(preq),
      crop_extent: crop_extent(preq, planning_dims(geometry, quarter_turn?)),
      trim?: preq.trim != nil,
      terminal_reduction: nil,
      required_extent: nil,
      user_quarter_turn?: quarter_turn?
    }
  end

  # The frame this pipeline's crop and resize dimensions are expressed against —
  # the source displayed through the NET turn (EXIF ∘ user rotate), which is the
  # same frame `open_options_for/5` swaps its shrink axes into.
  #
  # NOT `geometry.display_dimensions`: that is swapped by the EXIF turn ALONE, so
  # the two frames disagree exactly when a user rotate changes the net turn — a
  # `rot:90` on an EXIF-quarter-turn source cancels to net 180, leaving the shrink
  # axes unswapped while `display_dimensions` stays swapped. Since
  # `display_dimensions` is `swap^exif(storage)` and the net turn is
  # `exif XOR user`, applying the user turn to the display frame lands exactly on
  # `swap^net(storage)`.
  defp planning_dims(%SourceGeometry{display_dimensions: {w, h}}, true), do: {h, w}
  defp planning_dims(%SourceGeometry{display_dimensions: dims}, false), do: dims

  # Assembly emits at most one rotate, in stage 2 — always before the stage-4
  # resize — so the chain's `user_rotate_angle_before_resize/1` sum is just this
  # angle.
  defp user_quarter_turn?(%PipelineRequest{orientation: %Orientation{rotate: angle}}),
    do: rem(angle, 180) == 90

  defp crop_extent(%PipelineRequest{crop: nil}, _display_dims), do: nil

  defp crop_extent(%PipelineRequest{crop: %CropRequest{} = crop}, {dw, dh}),
    do: {crop_axis_extent(crop.width, dw), crop_axis_extent(crop.height, dh)}

  # Mirrors `DecodePlanner.crop_axis_extent/2` clause for clause, over the SAME
  # tagged measure the chain's own crop operation carries — `Assembly.
  # crop_dimension/1` is the one place the dialect's spellings lower, so routing
  # through it converges the two paths instead of re-deriving the extent here.
  #
  # Re-deriving is what a `{:scale, _}` punishes: the operation carries an exact
  # rational, and `round(dim * num / den)` is not `round(dim * float)` at a
  # half-pixel boundary (`{:scale, 0.29}` against 2850 -> 827 vs 826), which
  # moves the shrink ratio and, on webp's continuous `scale:`, the decode itself.
  defp crop_axis_extent(dimension, dim) do
    {:ok, measure} = Assembly.crop_dimension(dimension)
    tagged_crop_axis_extent(measure, dim)
  end

  defp tagged_crop_axis_extent(:full_axis, dim), do: dim
  defp tagged_crop_axis_extent({:px, n}, dim), do: min(n, dim)

  defp tagged_crop_axis_extent({:ratio, num, den}, dim),
    do: min(dim, max(1, round(dim * num / den)))

  # `DecodePlanner.chain_resize_target/1`'s min_* clause: a min_* floor interacts
  # with aspect ratio in ways that are not a per-axis multiplier, so the chain
  # path declines to shrink at all. No target box can express that; `nil`
  # reproduces it.
  defp resize_target(%PipelineRequest{min_width: mw, min_height: mh})
       when not is_nil(mw) or not is_nil(mh),
       do: nil

  # An untargeted axis stays `nil` rather than being synthesized from the aspect
  # ratio: `ratio_from_targets/4` — the SAME function the chain path reaches
  # through `DecodePlanner.chain_resize_target/1` — then takes that axis's ratio
  # alone, exactly as the chain does. A derived partner axis would instead bind
  # its `min/2` tighter whenever the frame is not exactly proportional, shrinking
  # less and decoding more pixels than the chain path for the same request.
  #
  # The extents are NOT rounded, for the same reason: the planner
  # divides by the fractional dpr/zoom-inflated target directly, so rounding here
  # would move the ratio (visibly, on webp's continuous `scale:`) and would round
  # a sub-pixel target — `rs:fit:1:0/dpr:0.4` — down to a division by zero.
  # The dpr is resolved through `Assembly.dpr_ratio/1` — the one place the
  # request's dpr lowers — for the same reason `crop_axis_extent/2` routes
  # through `Assembly.crop_dimension/1`: the resize operation carries an exact
  # rational, and re-deriving the extent from the raw float here is what
  # punishes you. `Plan.Operation` lowers a float dpr through `Float.round(7)`,
  # so `dpr:1.0000000000001` carries `{:ratio, 1, 1}` and targets a flat 400px,
  # where the float inflates the same target to 400.00000000004 — enough to drop
  # a 3200px jpeg's shrink from 8 to 4 and decode 4x the pixels.
  #
  # `zoom` is deliberately NOT routed the same way: `Assembly` hands it to the
  # operation as a plain float and `DecodePlanner.zoom_factor/1` passes floats
  # through untouched, so the raw value IS the value the operation carries.
  #
  # A dpr with no rational (`dpr:0.00000001`, which rounds to zero at the
  # seventh decimal) is a request `Assembly.operations/1` rejects outright, so
  # the chain never reaches the preflight with one. Declining to shrink is the
  # answer for any caller that does: sizing a decode against a target no
  # operation will ever carry is worse than not shrinking.
  defp resize_target(%PipelineRequest{} = preq) do
    with {:ok, dpr} <- Assembly.dpr_ratio(preq),
         {target_w, target_h} when not (is_nil(target_w) and is_nil(target_h)) <-
           {target_extent(preq.width, dpr, preq.zoom_x),
            target_extent(preq.height, dpr, preq.zoom_y)} do
      {target_w, target_h}
    else
      _no_target -> nil
    end
  end

  # `px_target_extent/3` + `target_extent/3`: only a concrete pixel dimension is
  # a target, inflated by dpr and the axis's zoom. The multiplication is ordered
  # `(n * dpr) * zoom` to match `DecodePlanner.target_extent/3`'s own
  # `dim * (n / d) * zoom_factor(zoom)` — float multiplication does not
  # associate, and the two paths must land on the same bits, not merely close.
  defp target_extent(nil, _dpr, _zoom), do: nil
  defp target_extent({:pixels, 0}, _dpr, _zoom), do: nil

  defp target_extent({:pixels, n}, {:ratio, num, den}, zoom),
    do: n * (num / den) * (zoom || 1.0)

  @doc """
  Executes every `-` pipeline of an imgproxy request against a decoded state.

  `opts` accepts the same runtime options threaded to `Chain.execute/3`
  (telemetry, etc). It also accepts three test-only overrides — `:chain`,
  `:measure_dims`, `:continue` — mirroring `Executor.run_neutral/4`'s own injectable
  seams, defaulting to the real `Chain.execute/3`, a live Vix header read, and
  `NeutralResolver.continue/4` respectively. Real callers never set these.

  A pipeline whose geometry `Assembly.operations/1` rejects (`rs:fill` with no
  dimensions, say) halts the reduce with that rejection, unwrapped — the same
  tuple `check_geometry/1` raises for the request at parse time.

  Runs the input color-management preamble before the first pipeline; a failure
  there is a decode failure, `{:error, {:decode, reason}}`.
  """
  @spec run(State.t(), SourceGeometry.t(), pipelined_request(), keyword()) ::
          {:ok, State.t()}
          | {:error, {:transform, term()} | {:decode, term()} | Assembly.error()}
  def run(%State{} = state, %SourceGeometry{} = _geometry, %{pipelines: pipelines}, opts) do
    ctx = build_ctx(opts)
    state = seed_detector(state, opts)

    with {:ok, %State{} = state} <- condition_color(state, opts),
         {:ok, %State{} = state} <- run_pipelines(pipelines, state, ctx) do
      {:ok, InputColorManagement.stamp_carry(state)}
    end
  end

  # Seeds the host-configured detector onto the transform state so object-guided
  # crops (`{:detect, _}` guides flowing into `Crop.execute/2`) reach it. Mirrors
  # the fields `ImagePipe.Transform.Executor.execute/3` sets — minus
  # `telemetry_opts`, which `ImagePipe.Decode.with_image/4` already seeded.
  defp seed_detector(%State{} = state, opts) do
    %State{
      state
      | detector: Transform.resolve_detector(Keyword.get(opts, :detector, :default)),
        detector_required: Keyword.get(opts, :detector_required, false)
    }
  end

  # The postamble to `condition_color/2`'s preamble, and required by it: the
  # import leaves the working-space image on `State`, and ONLY this stamp tells
  # `Output.Encoder`'s colorspace-to-result step that it ran. Without it the
  # encoder takes its "no import ran" branch on an imported image — re-converting
  # an already-converted image (scp on) or skipping the source-profile re-export
  # (scp:0). Both mistakes leave the output profile header unchanged, so only a
  # pixel comparison catches them (`ImagePipe.Dialect.ColorCarryParityTest`).
  #
  # The stamp lands at the delivery boundary, which here is `run/4`'s tail: the
  # last operation has run, and the only things left are `Output.Clamp` and the
  # encoder — neither of which drops image metadata. It is `run/4`'s tail rather
  # than the caller's so the preamble and its postamble stay one seam, in one
  # module, and every `run/4` caller gets both.

  # Mirrors `Executor.execute_pipelines/3`: the first failing pipeline halts the
  # rest.
  defp run_pipelines(pipelines, %State{} = state, ctx) do
    Enum.reduce_while(pipelines, {:ok, state}, fn %PipelineRequest{} = preq, {:ok, state} ->
      case run_pipeline(state, preq, ctx) do
        {:ok, %State{} = state} -> {:cont, {:ok, state}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  # Input color management is a data-determined preamble, not a Plan operation
  # (AGENTS.md: its behavior is sourced entirely from the decoded image's own
  # headers, which no operation struct can see). It imports the embedded profile
  # into a working space before ANY operation runs — so it belongs here, ahead of
  # the pipeline reduce, and runs exactly once per request rather than once per
  # `-` pipeline (`condition/2` is idempotent via `color_imported?`, but the
  # boundary is the request's).
  #
  # Mirrors `Executor.seed_color_management/2`. A failure is a
  # corrupt/unsupported profile — a decode failure, surfaced as `{:decode, _}`
  # (415) to stay consistent with the materialization contract, NOT as
  # `{:transform, _}`. The `[:transform, :input_color_management]` span is
  # emitted by `InputColorManagement.condition/2` itself, so this dialect gets it
  # for free from the shared seam.
  #
  # One deliberate divergence: no `seed_input_color_management` gate. The
  # Executor runs the preamble only on the real-execution path and skips it when
  # planning; this dialect's `run/4` IS the real-execution path — there is no
  # planning caller to gate against — so the gate has no counterpart here rather
  # than being dropped.
  defp condition_color(%State{} = state, opts) do
    hdr? = Keyword.get(opts, :supports_hdr?, false)

    case InputColorManagement.condition(state, supports_hdr?: hdr?) do
      {:ok, %State{} = state} -> {:ok, state}
      {:error, {InputColorManagement, reason}} -> {:error, {:decode, reason}}
    end
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

    pctx = Assembly.pipeline_ctx(preq)

    with {:ok, ops} <- Assembly.operations(preq),
         {:ok, state, shape, _carry} <- run_ops(state, shape, @empty_carry, ops, pctx, ctx) do
      flush_boundary(state, shape, ctx)
    end
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
  # functions (`nil` carried state throughout), and the carry is this module's
  # own pipeline-local variable.

  # The carry is computed HERE, from the PRE-resolve shape, before any
  # continuation is followed. It is never recomputed in `follow/5`
  # [spec §Pipeline 2 "update point"], and the incoming carry is discarded: a
  # resize replaces both slots outright.
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
  # DprScale.
  defp run_op(state, shape, carry, plan_op, _pctx, ctx) do
    state = overlay(state, shape)
    {ops, continuation} = NeutralResolver.resolve(shape, nil, plan_op)

    with {:ok, state} <- run_chain(ctx, state, ops),
         {:ok, state, shape} <- follow(state, shape, continuation, ctx, 0) do
      {:ok, state, shape, carry}
    end
  end

  # ── carry consumption ─────────────────────────────────────────────────────
  # The 1.0 fallback fires only when the pipeline emitted no resize: a set dpr
  # always emits one (`resize_rule_requested?/1` reads `dpr`), which fills the
  # slot — so a nil slot implies a nil dpr.
  defp padding_scale_for(%{mode: :resize}, %{effective_padding_scale: s}),
    do: s || 1.0

  defp padding_scale_for(%{mode: :canvas_preserving}, %{canvas_preserving_padding_scale: s}),
    do: s || 1.0

  # ── no-enlarge padding/DPR scale (#237) ───────────────────────────────────
  # Parity-critical arithmetic reproducing imgproxy's unconditional `!Enlarge()`
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
  # ex_dna:disable-for-next-line
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

  # ex_dna:disable-for-next-line
  defp boundary_source_dimensions(%SourceShape{decode_shrink: nil}), do: nil
  defp boundary_source_dimensions(%SourceShape{width: w, height: h}), do: {w, h}
end
