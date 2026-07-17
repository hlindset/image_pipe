defmodule ImagePipe.Dialect.Native.Pipeline do
  @moduledoc """
  Inline geometry planner and group executor for the native URL dialect.

  The heart of the dialect inversion: ordinary sequential Elixir code walks a
  canonical `%Request{}`'s groups and drives them to executed pixels, in
  place of the framework's `Plan`/`Resolver`/`Executor` strategy dispatch.

  **What this module keeps from core, and why.** It removes the `Resolver`
  facade, strategy selection/registration, `Directive`, markers, and
  `%Plan{}`/`Plan.Pipeline` — but deliberately *retains* the semantic
  `Plan.Operation` structs, `SourceShape`, the `{ops, continuation}`
  vocabulary, and `ImagePipe.Transform.NeutralResolver` as a stateless
  geometry compiler (`resolve/3` + `continue/4` + `resolve_mode/2`, called
  directly with `nil` state — no `ImagePipe.Resolver` strategy involved).
  This module therefore demonstrates dialect-owned *request orchestration*
  over a retained neutral geometry compiler; it does not yet demonstrate that
  the operation mirror or the continuation vocabulary can die. See
  `.superpowers/sdd/task-14-report.md` for the full accounting (retained
  concept families, direct-lowering feasibility) feeding Task 21.

  **Fixed stage order within a group** (probe subset): trim(3) →
  region/guided crop(4) → resize(5) → cover result crop(6, automatic, part of
  the resize's own continuation tail) → blur(7) → pad(20) → bg flatten(21).
  `then` starts a new group; groups within one `run/4` call share a single
  continuously-threaded `SourceShape` (seeded once, flushed once, after the
  last group) — there is no per-group flush boundary, which is what makes the
  "cheap trim" contract work: a trim in group 2 runs on group 1's already-
  executed output dims, not the original source.

  **Input color management** brackets that order: the embedded-ICC working-space
  import runs as a preamble before the first group, and the delivery-boundary
  carry stamp runs after the last one — both owned by `run/4`, both from
  `ImagePipe.Transform.InputColorManagement`.
  """

  alias ImagePipe.Dialect.Native.Request
  alias ImagePipe.Dialect.Native.Request.Group
  alias ImagePipe.Dialect.Native.Request.Output
  alias ImagePipe.Plan.Color
  alias ImagePipe.Plan.Measure
  alias ImagePipe.Plan.Operation
  alias ImagePipe.Transform.Chain
  alias ImagePipe.Transform.DecodePlanner
  alias ImagePipe.Transform.InputColorManagement
  alias ImagePipe.Transform.NeutralResolver
  alias ImagePipe.Transform.Operation.Flush
  alias ImagePipe.Transform.PendingOrientation
  alias ImagePipe.Transform.SourceGeometry
  alias ImagePipe.Transform.SourceShape
  alias ImagePipe.Transform.State

  # Reachable `continue/4` recursion is at most depth 1 for this probe's
  # operation set (a resize's `{:resize_tail, _}`/`{:resize_flush_tail, _}`
  # stage always resolves to a terminal `{:advance, _, nil}`; `:trim` and
  # `:resize` are terminal on first measure). This cap is defensive: an
  # unexpected deeper measurement is a core-contract bug and must crash, not
  # degrade — see `follow/5` below, which has no catch-all clause past it.
  @max_continuation_depth 4

  # `trim=auto` carries no numeric tolerance in the URL grammar (unlike
  # `trim=color,tolerance`) — the dialect must pick a reasonable default
  # threshold for the fully-automatic form. Chosen to match the tolerance
  # used in OptionSpec's own worked example (`"trim=fff,10"`).
  # An unpinned probe default: recorded as an open design-owner item in the
  # dialect-owned pipelines probe report, to confirm or adjust post-probe.
  @default_trim_threshold 10.0

  @blurhash_terminal_reduction {32, 32}

  @doc """
  The dialect's decode preflight: builds the `DecodePlanner.Request` that
  informs shrink-on-load, from the request's FIRST group only — decode
  happens once, before any group runs, so only the first group's trim/crop/
  resize can safely inform it (mirrors core's "only the first pipeline"
  shrink-on-load scoping). A later group's own trim/resize (the cheap-trim
  contract) runs against whatever the first group already produced and is
  untouched by this preflight.
  """
  @spec decode_request(Request.t(), SourceGeometry.t()) :: DecodePlanner.Request.t()
  def decode_request(
        %Request{groups: [%Group{} = group | _]} = request,
        %SourceGeometry{} = geometry
      ) do
    %DecodePlanner.Request{
      resize_target: resize_target(group.resize),
      crop_extent: crop_extent(group, geometry.display_dimensions),
      trim?: group.trim != nil,
      terminal_reduction: terminal_reduction(request.output),
      required_extent: nil
    }
  end

  # An `:auto` axis is not a target: it stays `nil`, so `ratio_from_targets/4`
  # — the same function the framework's `open_options/5` reaches through
  # `resize_load_shrink/3` — takes the targeted axis's ratio alone, exactly as
  # the chain path does. Synthesizing the missing axis from the aspect ratio
  # instead binds that function's `min/2` tighter than the chain path whenever
  # the source is not exactly proportional to the requested box, shrinking less
  # and decoding more pixels than the chain path for the same request.
  # A resize with NO targeted axis normalizes to `nil`, not `{nil, nil}`: the
  # planner's precedence reads `resize_target`'s presence, so an empty box would
  # shadow `terminal_reduction` and cost the blurhash terminal its load shrink.
  defp resize_target(nil), do: nil

  defp resize_target(%{w: w, h: h}) do
    case {target_axis(w), target_axis(h)} do
      {nil, nil} -> nil
      target -> target
    end
  end

  defp target_axis(:auto), do: nil
  defp target_axis(n) when is_integer(n), do: n

  defp crop_extent(%Group{region: {_x, _y, w, h}}, {dw, dh}),
    do: {round(resolve_length(w, dw)), round(resolve_length(h, dh))}

  defp crop_extent(%Group{crop: {w, h}}, {dw, dh}),
    do: {round(resolve_length(w, dw)), round(resolve_length(h, dh))}

  defp crop_extent(%Group{}, _display_dims), do: nil

  defp terminal_reduction(%Output{terminal: :blurhash}), do: @blurhash_terminal_reduction
  defp terminal_reduction(%Output{terminal: :image}), do: nil

  @doc """
  Executes every group of a canonical `%Request{}` against a decoded state,
  in the fixed stage order, then flushes any surviving pending orientation at
  the boundary (mirrors `ImagePipe.Transform.Executor.execute_pipeline/4` +
  `flush_boundary/4`).

  `opts` accepts the same runtime options threaded to `Chain.execute/3`
  (telemetry, etc). It also accepts three test-only overrides — `:chain`,
  `:measure_dims`, `:continue` — mirroring `Executor.run/5`'s own injectable
  seams, defaulting to the real `Chain.execute/3`, a live Vix header read, and
  `NeutralResolver.continue/4` respectively. Real callers never set these.
  """
  @spec run(State.t(), SourceGeometry.t(), Request.t(), keyword()) ::
          {:ok, State.t()} | {:error, {:transform, term()} | {:decode, term()}}
  def run(%State{} = state, %SourceGeometry{} = _geometry, %Request{} = request, opts) do
    with {:ok, %State{} = state} <- condition_color(state, opts),
         {:ok, %State{} = state} <- run_groups(state, request, opts) do
      {:ok, InputColorManagement.stamp_carry(state)}
    end
  end

  # Input color management is a data-determined preamble, not a Plan operation
  # (AGENTS.md: its behavior is sourced entirely from the decoded image's own
  # headers, which no operation struct can see), so it imports the embedded
  # profile into a working space before ANY group runs, and `stamp_carry/1`
  # above hands the result to `Output.Encoder`'s colorspace-to-result step at
  # the delivery boundary. The two are one seam: without the stamp the encoder
  # takes its "no import ran" branch on an imported image and re-converts
  # already-converted pixels — a mistake that leaves the output profile header
  # correct, so only a pixel comparison catches it
  # (`ImagePipe.Dialect.ColorCarryParityTest`).
  #
  # Mirrors `Executor.seed_color_management/2` and the imgproxy dialect's own
  # `condition_color/2`, including their one divergence: no `seed_orientation`
  # gate (`run/4` IS the real-execution path here). The
  # `[:transform, :input_color_management]` span is emitted by
  # `InputColorManagement.condition/2` itself, so this dialect gets it for free
  # from the shared seam. A failure is a corrupt/unsupported profile — a decode
  # failure, surfaced as `{:decode, _}` (415), consistent with the
  # materialization contract.
  defp condition_color(%State{} = state, opts) do
    hdr? = Keyword.get(opts, :supports_hdr?, false)

    case InputColorManagement.condition(state, supports_hdr?: hdr?) do
      {:ok, %State{} = state} -> {:ok, state}
      {:error, {InputColorManagement, reason}} -> {:error, {:decode, reason}}
    end
  end

  defp run_groups(%State{} = state, %Request{} = request, opts) do
    ctx = build_ctx(opts)
    {w, h} = State.effective_source_dims(state)

    shape =
      SourceShape.seed(%{
        width: w,
        height: h,
        pending_orientation: state.pending_orientation,
        decode_shrink: state.decode_shrink
      })

    request.groups
    |> Enum.reduce_while({:ok, state, shape}, fn group, {:ok, state, shape} ->
      case run_group(state, shape, group, ctx) do
        {:ok, _state, _shape} = ok -> {:cont, ok}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, state, shape} -> flush_boundary(state, shape, ctx)
      {:error, _reason} = error -> error
    end
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

  defp run_group(state, shape, %Group{} = group, ctx) do
    group
    |> group_operations(shape)
    |> Enum.reduce_while({:ok, state, shape}, fn plan_op, {:ok, state, shape} ->
      case run_op(state, shape, plan_op, ctx) do
        {:ok, _state, _shape} = ok -> {:cont, ok}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  # `resolve/3` and `continue/4` are called as stateless toolkit functions —
  # `nil` carried state throughout, mirroring the neutral resolver's own
  # contract (no `ImagePipe.Resolver` strategy dispatch here).
  defp run_op(state, shape, plan_op, ctx) do
    state = overlay(state, shape)
    {ops, continuation} = NeutralResolver.resolve(shape, nil, plan_op)

    with {:ok, state} <- run_chain(ctx, state, ops) do
      follow(state, shape, continuation, ctx, 0)
    end
  end

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

  # Terminal: every reachable `continue/4` clause for this probe's operation
  # set (`:trim`, `:resize`, `{:resize_tail, _}`, `{:resize_flush_tail, _}`)
  # ends in a bare `{:advance, shape, nil}` — either directly (`:trim`,
  # `:resize`) or after executing one further tail stage. See the Task 14
  # report for the enumerated closed set. No clause matches past
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

  # Mirrors `Executor.flush_boundary/4`: syncs State's source-frame fields
  # from the final shape, then flushes a surviving non-identity pending
  # orientation through an explicit `%Flush{}`; an identity pending clears
  # without materializing (the streaming fast path).
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

  @doc """
  Terminal reduction: after all groups + the flush boundary (i.e. called with
  the state `run/4` returns), reduces the pipeline's output internally to fit
  the terminal's fixed working frame — a contain-resize run through the SAME
  lowering path every other resize goes through (`run_op/4`, `NeutralResolver`,
  `Chain.execute/3`), not a hand-rolled resize. A no-op for the plain image
  terminal.
  """
  @spec reduce_terminal(State.t(), Request.t(), keyword()) ::
          {:ok, State.t()} | {:error, {:transform, term()}}
  def reduce_terminal(%State{} = state, %Request{output: %Output{terminal: :image}}, _opts),
    do: {:ok, state}

  def reduce_terminal(%State{} = state, %Request{output: %Output{terminal: :blurhash}}, opts) do
    ctx = build_ctx(opts)
    {w, h} = State.effective_source_dims(state)

    shape =
      SourceShape.seed(%{
        width: w,
        height: h,
        pending_orientation: state.pending_orientation,
        decode_shrink: state.decode_shrink
      })

    {reduction_w, reduction_h} = @blurhash_terminal_reduction

    {:ok, resize} =
      Operation.resize(:fit, resize_dimension(reduction_w), resize_dimension(reduction_h),
        down: false,
        enlargement: :allow
      )

    case run_op(state, shape, resize, ctx) do
      {:ok, state, _shape} -> {:ok, state}
      {:error, _reason} = error -> error
    end
  end

  # -- per-group semantic op assembly --------------------------------------
  #
  # Built fresh for each group against that group's STARTING shape (the shape
  # as of the end of the previous group, or the seed for group 0) — the only
  # pct-relative values in the probe subset (`crop`/`region` lengths) resolve
  # against the CURRENT DISPLAY dims at this point (`SourceShape.live_dims/1`,
  # swapped for a pending quarter turn via `PendingOrientation.display_dims/2`
  # — the same computation `Decode.with_image/4` uses to seed
  # `SourceGeometry.display_dimensions`), before any of this group's own ops
  # run. This basis is the group's INPUT shape, so a pct crop/region in a
  # group that ALSO trims (stage 3, before crop's stage 4) resolves against
  # the PRE-trim display dims, not the post-trim result — a deliberate,
  # pinned choice (the group-input shape is what "current display dims"
  # means here), not an oversight; see `pipeline_pixel_test.exs` for the
  # pinning test. Resolved px lengths need no such compensation: the caller
  # already supplies them in the display frame, matching what the resolver's
  # crop path expects.

  defp group_operations(%Group{} = group, %SourceShape{} = shape) do
    display_dims =
      PendingOrientation.display_dims(SourceShape.live_dims(shape), shape.pending_orientation)

    [
      trim_op(group.trim),
      crop_op(group, display_dims),
      resize_op(group.resize, group.guide),
      blur_op(group.blur),
      pad_op(group.pad),
      bg_op(group.bg)
    ]
    |> Enum.reject(&is_nil/1)
  end

  @doc """
  The ordered semantic operation-name atoms `run/4` will execute across all
  groups — the dialect counterpart of `ImagePipe.Plan.operation_names/1`,
  feeding the `[:transform, :execute]` span's aggregate start metadata.

  A structural mirror of `group_operations/2` above (which needs a live
  `SourceShape` to resolve pct lengths, unavailable before execution): op
  *presence* per group is shape-independent, so each clause here answers
  `Operation.name/1` of the op its `group_operations/2` counterpart would
  build — including the identity elisions (`pad=0`, no crop/region).
  """
  @spec operation_names(Request.t()) :: [atom()]
  def operation_names(%Request{groups: groups}) do
    Enum.flat_map(groups, &group_operation_names/1)
  end

  defp group_operation_names(%Group{} = group) do
    [
      group.trim && :trim,
      crop_name(group),
      group.resize && :resize,
      group.blur && :blur,
      pad_name(group.pad),
      group.bg && :background
    ]
    |> Enum.reject(&is_nil/1)
  end

  defp crop_name(%Group{region: region}) when region != nil, do: :crop_region
  defp crop_name(%Group{crop: crop}) when crop != nil, do: :crop_guided
  defp crop_name(%Group{}), do: nil

  defp pad_name(nil), do: nil
  defp pad_name({0, 0, 0, 0}), do: nil
  defp pad_name({_top, _right, _bottom, _left}), do: :padding

  defp trim_op(nil), do: nil

  defp trim_op(:auto), do: build_trim_op(@default_trim_threshold, :auto)

  defp trim_op({{r, g, b}, tolerance}) do
    {:ok, color} = Color.rgb(r, g, b)
    build_trim_op(tolerance * 1.0, color)
  end

  defp build_trim_op(threshold, background) do
    {:ok, op} =
      Operation.trim(
        threshold: threshold,
        background: background,
        equal_hor: false,
        equal_ver: false
      )

    op
  end

  defp crop_op(%Group{region: {x, y, w, h}}, {dw, dh}) do
    {:ok, op} =
      Operation.crop_region(
        px(resolve_length(x, dw)),
        px(resolve_length(y, dh)),
        px(resolve_length(w, dw)),
        px(resolve_length(h, dh))
      )

    op
  end

  defp crop_op(%Group{crop: {w, h}, guide: guide}, {dw, dh}) do
    {:ok, op} =
      Operation.crop_guided(
        px(resolve_length(w, dw)),
        px(resolve_length(h, dh)),
        plan_guide(guide)
      )

    op
  end

  defp crop_op(%Group{}, _display_dims), do: nil

  defp resize_op(nil, _guide), do: nil

  defp resize_op(%{w: w, h: h, fit: fit, enlarge: enlarge?}, guide) do
    {mode, down?} = resize_mode_down(fit)

    opts =
      [down: down?, enlargement: if(enlarge?, do: :allow, else: :deny)] ++
        if guide, do: [guide: plan_guide(guide)], else: []

    {:ok, op} = Operation.resize(mode, resize_dimension(w), resize_dimension(h), opts)
    op
  end

  defp resize_mode_down(:contain), do: {:fit, false}
  defp resize_mode_down(:cover), do: {:cover, false}
  defp resize_mode_down(:cover_down), do: {:cover, true}
  defp resize_mode_down(:stretch), do: {:stretch, false}
  defp resize_mode_down(:auto), do: {:auto, false}

  defp resize_dimension(:auto), do: :auto
  defp resize_dimension(n) when is_integer(n), do: {:px, n}

  defp blur_op(nil), do: nil

  defp blur_op(sigma) do
    {:ok, op} = Operation.blur(sigma)
    op
  end

  defp pad_op(nil), do: nil

  # A pad shorthand where every side is 0 is the Tier-1 identity point (same
  # canonicalization the parser already applies to `blur=0`) — Plan.Operation's
  # own constructor rejects an all-zero padding, so this identity guard is
  # required, not merely tidy, for a literal `pad=0` request to not crash.
  defp pad_op({0, 0, 0, 0}), do: nil

  defp pad_op({top, right, bottom, left}) do
    {:ok, op} = Operation.padding({:px, top}, {:px, right}, {:px, bottom}, {:px, left})
    op
  end

  defp bg_op(nil), do: nil

  defp bg_op({r, g, b, alpha}) do
    {:ok, color} = Color.rgba(r, g, b, to_ratio!(alpha))
    {:ok, op} = Operation.background(color)
    op
  end

  # -- shared value conversion ----------------------------------------------

  # A length resolved to a plain (unrounded) number against `dim` — pct is a
  # percentage of `dim`, px passes through. Callers round + tag as their
  # target measure role (dimension vs. position) requires.
  defp resolve_length({:px, n}, _dim), do: n
  defp resolve_length({:pct, n}, dim), do: dim * n / 100

  defp px(n), do: {:px, round(n)}

  # Named 9-way anchor -> the two-axis {x_anchor, y_anchor} form Plan.Resize's
  # `guide` requires (`CropGuided` also accepts this form, so one table serves
  # both). Mirrors `Lowering.tagged_executable_gravity/1`'s own mapping.
  defp plan_guide({:anchor, name}) do
    {x, y} = anchor_pair(name)
    {:anchor, x, y}
  end

  defp plan_guide({:anchor_smart}), do: :smart

  defp plan_guide({:focus, fx, fy}), do: {:focal, to_ratio!(fx), to_ratio!(fy)}

  defp anchor_pair(:center), do: {:center, :center}
  defp anchor_pair(:top), do: {:center, :top}
  defp anchor_pair(:bottom), do: {:center, :bottom}
  defp anchor_pair(:left), do: {:left, :center}
  defp anchor_pair(:right), do: {:right, :center}
  defp anchor_pair(:top_left), do: {:left, :top}
  defp anchor_pair(:top_right), do: {:right, :top}
  defp anchor_pair(:bottom_left), do: {:left, :bottom}
  defp anchor_pair(:bottom_right), do: {:right, :bottom}

  defp to_ratio!(fraction) when is_float(fraction) do
    {:ok, ratio} = Measure.from_scale(fraction)
    ratio
  end
end
