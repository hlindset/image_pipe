defmodule ImagePipe.Native.Pipeline do
  @moduledoc """
  Inline geometry planner and group executor for the native URL dialect.

  Ordinary sequential Elixir code walks a canonical `%Request{}`'s groups and
  drives them to executed pixels.

  **What this module takes from core.** The semantic `Plan.Operation` structs,
  `SourceShape`, the `{ops, continuation}` vocabulary, and
  `ImagePipe.Transform.NeutralResolver` as a stateless geometry compiler
  (`resolve/3` + `continue/4` + `resolve_mode/2`, called directly with `nil`
  state). The dialect owns the request orchestration around them.

  **Fixed stage order within a group**: rotate(1) → flip(2) → trim(3) →
  region/guided crop(4) → resize(5) → cover result crop(6, automatic, part of
  the resize's own continuation tail) → blur(7) → sharpen(8) → pixelate(9) →
  gray(10) → bitonal(11) → monochrome(12) → duotone(13) → brightness(14) →
  contrast(15) → saturation(16) → colorize(17) → gradient(18) → canvas(19) →
  pad(20) → bg flatten(21).
  `then` starts a new group whose input is the preceding group's result.
  Groups share a continuously-threaded `SourceShape`. Pending orientation is
  flushed before stages that require displayed pixels, including trim, and
  at the request boundary.

  **Input color management** brackets that order: the embedded-ICC working-space
  import runs as a preamble before the first group, and the delivery-boundary
  carry stamp runs after the last one — both owned by `run/4`, both from
  `ImagePipe.Transform.InputColorManagement`.
  """

  alias ImagePipe.Native.Request
  alias ImagePipe.Native.Request.Group
  alias ImagePipe.Native.Request.Output
  alias ImagePipe.Plan.Color
  alias ImagePipe.Plan.Measure
  alias ImagePipe.Plan.Operation
  alias ImagePipe.Transform
  alias ImagePipe.Transform.Chain
  alias ImagePipe.Transform.DecodePlanner
  alias ImagePipe.Transform.InputColorManagement
  alias ImagePipe.Transform.Lowering
  alias ImagePipe.Transform.Materializer
  alias ImagePipe.Transform.NeutralResolver
  alias ImagePipe.Transform.Operation.Crop
  alias ImagePipe.Transform.Operation.ExtendCanvas
  alias ImagePipe.Transform.Operation.Flush
  alias ImagePipe.Transform.Operation.Resize
  alias ImagePipe.Transform.PendingOrientation
  alias ImagePipe.Transform.ResizePlanning
  alias ImagePipe.Transform.SourceGeometry
  alias ImagePipe.Transform.SourceShape
  alias ImagePipe.Transform.State
  alias Vix.Vips.Image, as: VipsImage
  alias Vix.Vips.MutableImage, as: VipsMutableImage

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
  def decode_request(%Request{groups: [%Group{rotate: angle} | _]}, _geometry)
      when angle != nil and angle not in [90, 180, 270] do
    # Arbitrary rotation changes the crop frame through resampling. Decode
    # the full source so later source-pixel coordinates stay exact.
    %DecodePlanner.Request{}
  end

  def decode_request(
        %Request{groups: [%Group{} = group | _]} = request,
        %SourceGeometry{} = geometry
      ) do
    {dw, dh} = geometry.display_dimensions
    quarter_turn? = group.rotate in [90, 270]
    crop_dimensions = if quarter_turn?, do: {dh, dw}, else: {dw, dh}

    %DecodePlanner.Request{
      resize_target: resize_target(group.resize, group.dpr),
      crop_extent: crop_extent(group, crop_dimensions),
      user_quarter_turn?: quarter_turn?,
      trim?: group.trim != nil,
      terminal_reduction: terminal_reduction(request),
      required_extent: nil
    }
  end

  # An `:auto` axis is not a target: it stays `nil`, so the planner's
  # `ratio_from_targets/4` takes the targeted axis's ratio alone. Synthesizing
  # the missing axis from the aspect ratio instead binds that function's `min/2`
  # tighter whenever the source is not exactly proportional to the requested
  # box, shrinking less and decoding more pixels than the request calls for.
  # A resize with NO targeted axis normalizes to `nil`, not `{nil, nil}`: the
  # planner's precedence reads `resize_target`'s presence, so an empty box would
  # shadow `terminal_reduction` and cost the blurhash terminal its load shrink.
  defp resize_target(nil, _dpr), do: nil

  defp resize_target(%{min_w: min_w, min_h: min_h}, _dpr)
       when min_w != nil or min_h != nil,
       do: nil

  defp resize_target(%{w: w, h: h, zoom: {zx, zy}}, dpr) do
    case {target_axis(w, zx * dpr), target_axis(h, zy * dpr)} do
      {nil, nil} -> nil
      target -> target
    end
  end

  defp target_axis(:auto, _scale), do: nil
  defp target_axis(n, scale), do: n * scale

  defp crop_extent(%Group{region: {_x, _y, w, h}}, {dw, dh}),
    do: {round(resolve_length(w, dw)), round(resolve_length(h, dh))}

  defp crop_extent(%Group{crop: {_w, _h}} = group, display_dims),
    do: crop_dimensions(group, display_dims)

  defp crop_extent(%Group{}, _display_dims), do: nil

  defp terminal_reduction(%Request{groups: [_group], output: %Output{terminal: :blurhash}}),
    do: @blurhash_terminal_reduction

  defp terminal_reduction(%Request{}), do: nil

  @doc """
  Executes every group of a canonical `%Request{}` against a decoded state,
  in the fixed stage order, then flushes any surviving pending orientation at
  the request boundary.

  `opts` accepts the same runtime options threaded to `Chain.execute/3`
  (telemetry, etc). It also accepts three test-only overrides — `:chain`,
  `:measure_dims`, `:continue` — defaulting to `Chain.execute/3`, a live Vix header read, and
  `NeutralResolver.continue/4` respectively. Real callers never set these.
  """
  @spec run(State.t(), SourceGeometry.t(), Request.t(), keyword()) ::
          {:ok, State.t()} | {:error, {:transform, term()} | {:decode, term()}}
  def run(%State{} = state, %SourceGeometry{} = _geometry, %Request{} = request, opts) do
    state = seed_detector(state, opts)

    with {:ok, %State{} = state} <- condition_color(state, opts),
         {:ok, %State{} = state} <- run_groups(state, request, opts),
         {:ok, %State{} = state} <- normalize_output_orientation(state, request, opts) do
      {:ok, InputColorManagement.stamp_carry(state)}
    end
  end

  defp seed_detector(%State{} = state, opts) do
    %State{state | detector: Transform.resolve_detector(Keyword.get(opts, :detector, :default))}
  end

  defp normalize_output_orientation(
         %State{} = state,
         %Request{output: %Output{terminal: :image} = output},
         opts
       ) do
    if retains_source_metadata?(output, opts) do
      remove_non_normal_orientation(state)
    else
      {:ok, state}
    end
  end

  defp normalize_output_orientation(%State{} = state, %Request{}, _opts), do: {:ok, state}

  defp retains_source_metadata?(%Output{metadata: :keep}, _opts), do: true

  defp retains_source_metadata?(%Output{metadata: nil}, opts),
    do: not Keyword.get(opts, :strip_metadata, true)

  defp retains_source_metadata?(%Output{}, _opts), do: false

  defp remove_non_normal_orientation(%State{} = state) do
    case VipsImage.header_value(state.image, "orientation") do
      {:ok, 1} ->
        {:ok, state}

      {:ok, _orientation} ->
        remove_output_orientation(state)

      {:error, _reason} ->
        {:ok, state}
    end
  end

  defp remove_output_orientation(%State{} = state) do
    with {:ok, %State{} = state} <- materialize_for_orientation_metadata(state),
         {:ok, image} <-
           VipsImage.mutate(state.image, fn mutable ->
             VipsMutableImage.remove(mutable, "orientation")
             :ok
           end) do
      {:ok, %State{state | image: image}}
    else
      {:error, {:decode, _reason}} = error -> error
      {:error, reason} -> {:error, {:transform, reason}}
    end
  end

  defp materialize_for_orientation_metadata(%State{materialized?: true} = state),
    do: {:ok, state}

  defp materialize_for_orientation_metadata(%State{} = state) do
    case Materializer.materialize(state) do
      {:ok, state} -> {:ok, state}
      {:error, reason} -> {:error, {:decode, reason}}
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
  # (`ImagePipe.Native.ColorManagementWireTest`).
  # `InputColorManagement.condition/2` emits the input-color-management span.
  # Corrupt or unsupported profiles surface as decode failures (415).
  # ex_dna:disable-for-next-line
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

  # ex_dna:disable-for-next-line
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
    with {:ok, state, shape} <- rotate_group(state, shape, group.rotate, ctx),
         {:ok, state, shape} <- flip_group(state, shape, group.flip, ctx),
         {:ok, state, shape} <- trim_group(state, shape, group, ctx) do
      run_group_body(state, shape, group, ctx)
    end
  end

  defp rotate_group(state, shape, nil, _ctx), do: {:ok, state, shape}

  defp rotate_group(state, shape, angle, ctx),
    do: run_op(state, shape, %Operation.Rotate{angle: angle}, ctx)

  defp flip_group(state, shape, nil, _ctx), do: {:ok, state, shape}

  defp flip_group(state, shape, axis, ctx),
    do: run_op(state, shape, %Operation.Flip{axis: axis}, ctx)

  defp trim_group(state, shape, %Group{trim: nil}, _ctx), do: {:ok, state, shape}

  defp trim_group(state, shape, %Group{} = group, ctx) do
    with {:ok, state} <- flush_boundary(state, shape, ctx) do
      {width, height} = ctx.measure_dims.(state.image)

      shape = %SourceShape{
        width: width,
        height: height,
        frame: :display,
        pending_orientation: nil,
        decode_shrink: nil
      }

      run_op(state, shape, trim_op(group.trim, group.trim_symmetry), ctx)
    end
  end

  defp run_group_body(state, shape, group, ctx) do
    with {:ok, state, shape, dpr} <-
           run_group_operations(state, shape, group_operations(group, shape), group.dpr, ctx),
         {:ok, state, shape} <- run_canvas(state, shape, group, dpr, ctx),
         {:ok, state, shape, _dpr} <-
           run_group_operations(state, shape, [pad_op(group.pad), bg_op(group.bg)], dpr, ctx) do
      {:ok, state, shape}
    end
  end

  defp run_group_operations(state, shape, operations, dpr, ctx) do
    operations
    |> Enum.reject(&is_nil/1)
    |> Enum.reduce_while({:ok, state, shape, dpr}, fn plan_op, {:ok, state, shape, dpr} ->
      case run_group_op(state, shape, plan_op, dpr, ctx) do
        {:ok, _state, _shape, _dpr} = ok -> {:cont, ok}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  defp run_group_op(state, shape, %Operation.Resize{} = op, dpr, ctx) do
    {mode, target} = native_resize_target(op, shape, dpr)

    op = %{
      op
      | mode: resolved_target_execution_mode(mode),
        width: {:px, target.width},
        height: {:px, target.height},
        min_width: nil,
        min_height: nil,
        zoom_x: 1.0,
        zoom_y: 1.0,
        dpr: {:ratio, 1, 1},
        enlargement: :allow,
        down: false,
        x_offset: resize_offset(op.x_offset, mode, target.dpr),
        y_offset: resize_offset(op.y_offset, mode, target.dpr)
    }

    with {:ok, state, shape} <- run_op(state, shape, op, ctx),
         do: {:ok, state, shape, target.dpr}
  end

  defp run_group_op(state, shape, %Operation.Padding{} = op, dpr, ctx) do
    {ops, continuation} =
      op |> Lowering.padding_executables(dpr) |> NeutralResolver.display_frame_advance(shape)

    with {:ok, state} <- run_chain(ctx, overlay(state, shape), ops),
         {:ok, state, shape} <- follow(state, shape, continuation, ctx, 0),
         do: {:ok, state, shape, dpr}
  end

  defp run_group_op(state, shape, op, dpr, ctx) do
    with {:ok, state, shape} <- run_op(state, shape, op, ctx),
         do: {:ok, state, shape, dpr}
  end

  defp native_resize_target(op, shape, dpr) do
    mode = native_resize_mode(op, shape)

    {width, height} =
      PendingOrientation.display_dims({shape.width, shape.height}, shape.pending_orientation)

    resize = ResizePlanning.resize_from(op, mode)

    target =
      Resize.native_target(%{resize | dpr: dpr}, source_width: width, source_height: height)

    {mode, target}
  end

  defp native_resize_mode(
         %Operation.Resize{
           mode: :auto,
           width: {:px, w},
           height: {:px, h},
           zoom_x: zx,
           zoom_y: zy
         },
         shape
       ) do
    {sw, sh} =
      PendingOrientation.display_dims({shape.width, shape.height}, shape.pending_orientation)

    case sw >= sh == w * zx >= h * zy do
      true -> :cover
      false -> :fit
    end
  end

  defp native_resize_mode(op, shape), do: NeutralResolver.resolve_mode(op, shape)

  # The target has already applied fit and final pixel rounding. Lower it through
  # stretch so the executable resize does not fit the rounded box a second time.
  defp resolved_target_execution_mode(:fit), do: :stretch
  defp resolved_target_execution_mode(mode), do: mode

  defp run_canvas(state, shape, %Group{canvas: nil}, _dpr, _ctx),
    do: {:ok, state, shape}

  defp run_canvas(state, shape, %Group{canvas: canvas, resize: resize}, dpr, ctx) do
    {width, height} =
      shape
      |> SourceShape.live_dims()
      |> PendingOrientation.display_dims(shape.pending_orientation)

    rule = canvas_rule(canvas.mode, resize, dpr)
    {:ok, {canvas_width, canvas_height}} = ExtendCanvas.resolved_canvas_dims(rule, width, height)
    {x, y} = canvas.offset
    {anchor_x, anchor_y} = anchor_pair(canvas.at)

    operation = %ExtendCanvas{
      rule: rule,
      gravity: {:anchor, anchor_x, anchor_y},
      x_offset: canvas_offset(x, canvas_width, dpr),
      y_offset: canvas_offset(y, canvas_height, dpr),
      background: :transparent
    }

    {ops, _advance} = NeutralResolver.display_frame_advance([operation], shape)

    with {:ok, state} <- run_chain(ctx, overlay(state, shape), ops) do
      {:ok, state, %SourceShape{width: canvas_width, height: canvas_height, frame: :display}}
    end
  end

  defp canvas_rule(:box, %{w: w, h: h}, dpr), do: {:dimensions, w * dpr, h * dpr}
  defp canvas_rule(:ratio, %{w: w, h: h}, _dpr), do: {:aspect_ratio, {w, h}}

  defp canvas_offset({:px, value}, _dimension, dpr), do: value * dpr
  defp canvas_offset({:pct, value}, dimension, _dpr), do: dimension * value / 100

  # `resolve/3` and `continue/4` are called as stateless toolkit functions —
  # `nil` carried state throughout, mirroring the neutral resolver's own
  # contract.
  defp run_op(state, shape, plan_op, ctx) do
    state = overlay(state, shape)
    {ops, continuation} = NeutralResolver.resolve(shape, nil, plan_op)

    with {:ok, state} <- run_chain(ctx, state, ops) do
      follow(state, shape, continuation, ctx, 0)
    end
  end

  # Every executable op's execute-time `State.effective_source_dims/
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

  # Terminal: every reachable `continue/4` clause for this probe's operation
  # set (`:trim`, `:resize`, `{:resize_tail, _}`, `{:resize_flush_tail, _}`)
  # ends in a bare `{:advance, shape, nil}` — either directly (`:trim`,
  # `:resize`) or after executing one further tail stage. No clause matches past
  # `@max_continuation_depth` — an unexpected deeper measurement is a
  # core-contract bug and must crash here, not degrade silently.
  # ex_dna:disable-for-next-line
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

  # ex_dna:disable-for-next-line
  defp run_chain(ctx, state, ops) do
    case ctx.chain.(state, ops, ctx.opts) do
      {:ok, _state} = ok -> ok
      {:error, reason} -> {:error, {:transform, reason}}
    end
  end

  # Syncs State's source-frame fields
  # from the final shape, then flushes a surviving non-identity pending
  # orientation through an explicit `%Flush{}`; an identity pending clears
  # without materializing (the streaming fast path).
  # ex_dna:disable-for-next-line
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
  # Crop percentages use the effective display frame after rotation, flip,
  # and trim. Keep lengths in source pixels here: lowering applies the realized
  # decode shrink once when translating them into decoded-image coordinates.

  defp group_operations(%Group{} = group, %SourceShape{} = shape) do
    display_dims =
      PendingOrientation.display_dims({shape.width, shape.height}, shape.pending_orientation)

    crop = crop_op(group, display_dims)
    resize = resize_op(group.resize, group.guide) |> with_offsets(group.anchor_offset)
    crop_dpr = crop_offset_dpr(group, shape, crop, resize)

    [
      crop |> with_offsets(group.anchor_offset) |> scale_offsets(crop_dpr),
      resize,
      blur_op(group.blur),
      sharpen_op(group.sharpen),
      pixelate_op(group.pixelate),
      if(group.gray, do: %Operation.Gray{}),
      if(group.bitonal, do: %Operation.Bitonal{}),
      monochrome_op(group.monochrome),
      duotone_op(group.duotone),
      brightness_op(group.brightness),
      contrast_op(group.contrast),
      saturation_op(group.saturation),
      colorize_op(group.colorize),
      gradient_op(group.gradient)
    ]
  end

  defp crop_offset_dpr(%Group{anchor_offset: nil, dpr: dpr}, _shape, _crop, _resize),
    do: dpr

  defp crop_offset_dpr(%Group{dpr: dpr}, _shape, nil, _resize), do: dpr
  defp crop_offset_dpr(%Group{dpr: dpr}, _shape, _crop, nil), do: dpr

  defp crop_offset_dpr(%Group{dpr: dpr}, shape, crop, resize) do
    # Placement does not change crop dimensions. Resolve that shape first so
    # the crop and subsequent resize use the same enlargement-limited DPR.
    {_ops, {:advance, cropped_shape, nil}} = NeutralResolver.resolve(shape, nil, crop)
    {_mode, target} = native_resize_target(resize, cropped_shape, dpr)
    target.dpr
  end

  defp with_offsets(nil, _offset), do: nil
  defp with_offsets(op, nil), do: op
  defp with_offsets(%Operation.CropRegion{} = op, _offset), do: op

  defp with_offsets(%Operation.Resize{mode: mode} = op, _offset)
       when mode not in [:cover, :auto],
       do: op

  defp with_offsets(op, {x, y}),
    do: %{op | x_offset: tagged_offset(x), y_offset: tagged_offset(y)}

  defp tagged_offset({:px, value}), do: {:pixels, value}
  defp tagged_offset({:pct, value}), do: {:scale, value / 100}

  defp scale_offsets(%Operation.CropGuided{} = op, dpr),
    do: %{
      op
      | x_offset: scale_pixel_offset(op.x_offset, dpr),
        y_offset: scale_pixel_offset(op.y_offset, dpr)
    }

  defp scale_offsets(op, _dpr), do: op

  defp scale_pixel_offset({:pixels, value}, dpr), do: {:pixels, value * dpr}
  defp scale_pixel_offset({:scale, _value} = offset, _dpr), do: offset

  defp resize_offset(offset, :cover, dpr), do: scale_pixel_offset(offset, dpr)
  defp resize_offset(_offset, _mode, _dpr), do: {:pixels, 0.0}

  @doc """
  The ordered semantic operation-name atoms `run/4` will execute across all
  groups, feeding the transform span's aggregate start metadata.

  Operation presence per group is shape-independent. This lists the body,
  canvas, padding, and background stages without resolving runtime geometry,
  including the identity elisions (`pad=0`, no crop/region).
  """
  @spec operation_names(Request.t()) :: [atom()]
  def operation_names(%Request{groups: groups}) do
    Enum.flat_map(groups, &group_operation_names/1)
  end

  defp group_operation_names(%Group{} = group) do
    for {value, name} <- [
          {group.rotate, :rotate},
          {group.flip, :flip},
          {group.trim, :trim},
          {group.region || group.crop, crop_name(group)},
          {group.resize, :resize},
          {group.blur, :blur},
          {group.sharpen, :sharpen},
          {group.pixelate, :pixelate},
          {group.gray, :gray},
          {group.bitonal, :bitonal},
          {group.monochrome, :monochrome},
          {group.duotone, :duotone},
          {group.brightness, :brightness},
          {group.contrast, :contrast},
          {group.saturation, :saturation},
          {group.colorize, :colorize},
          {group.gradient, :gradient},
          {group.canvas, :canvas},
          {pad_name(group.pad), :padding},
          {group.bg, :background}
        ],
        value not in [nil, false],
        do: name
  end

  defp crop_name(%Group{region: region}) when region != nil, do: :crop_region
  defp crop_name(%Group{crop: crop}) when crop != nil, do: :crop_guided
  defp crop_name(%Group{}), do: nil

  defp pad_name(nil), do: nil
  defp pad_name({0, 0, 0, 0}), do: nil
  defp pad_name({_top, _right, _bottom, _left}), do: :padding

  defp trim_op(:auto, symmetry), do: build_trim_op(@default_trim_threshold, :auto, symmetry)

  defp trim_op({{r, g, b}, tolerance}, symmetry) do
    {:ok, color} = Color.rgb(r, g, b)
    build_trim_op(tolerance * 1.0, color, symmetry)
  end

  defp build_trim_op(threshold, background, symmetry) do
    {:ok, op} =
      Operation.trim(
        threshold: threshold,
        background: background,
        equal_hor: symmetry in [:horizontal, :both],
        equal_ver: symmetry in [:vertical, :both]
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

  defp crop_op(%Group{crop: {_w, _h}, guide: guide} = group, display_dims) do
    {width, height} = crop_dimensions(group, display_dims)

    {:ok, op} =
      Operation.crop_guided(
        px(width),
        px(height),
        plan_guide(guide)
      )

    op
  end

  defp crop_op(%Group{}, _display_dims), do: nil

  defp crop_dimensions(%Group{crop: {w, h}} = group, {dw, dh}) do
    crop = %Crop{
      width: {:pixels, round(resolve_length(w, dw))},
      height: {:pixels, round(resolve_length(h, dh))},
      crop_from: :gravity,
      aspect_ratio: group.crop_ratio,
      enlarge: group.crop_ratio_enlarge
    }

    Crop.resolved_box_dims(crop, dw, dh)
  end

  defp resize_op(nil, _guide), do: nil

  defp resize_op(
         %{w: w, h: h, fit: fit, enlarge: enlarge?, zoom: {zx, zy}, min_w: mw, min_h: mh},
         guide
       ) do
    {mode, down?} = resize_mode_down(fit)

    opts =
      [
        down: down?,
        enlargement: if(enlarge?, do: :allow, else: :deny),
        zoom_x: zx,
        zoom_y: zy,
        min_width: optional_dimension(mw),
        min_height: optional_dimension(mh)
      ] ++
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

  defp optional_dimension(nil), do: nil
  defp optional_dimension(n), do: resize_dimension(n)

  defp blur_op(nil), do: nil

  defp blur_op(sigma) do
    {:ok, op} = Operation.blur(sigma)
    op
  end

  defp sharpen_op(nil), do: nil

  defp sharpen_op(sigma) do
    {:ok, op} = Operation.sharpen(sigma)
    op
  end

  defp pixelate_op(nil), do: nil

  defp pixelate_op(size) do
    {:ok, op} = Operation.pixelate(size)
    op
  end

  defp monochrome_op(nil), do: nil

  defp monochrome_op(%{intensity: intensity, color: color}) do
    {:ok, op} = Operation.monochrome(to_ratio!(intensity), rgb!(color))
    op
  end

  defp duotone_op(nil), do: nil

  defp duotone_op(%{intensity: intensity, shadow: shadow, highlight: highlight}) do
    {:ok, op} = Operation.duotone(to_ratio!(intensity), rgb!(shadow), rgb!(highlight))
    op
  end

  defp brightness_op(nil), do: nil

  defp brightness_op(value) do
    {:ok, op} = Operation.brightness(value)
    op
  end

  defp contrast_op(nil), do: nil

  defp contrast_op(value) do
    {:ok, op} = Operation.contrast(value)
    op
  end

  defp saturation_op(nil), do: nil

  defp saturation_op(value) do
    {:ok, op} = Operation.saturation(value)
    op
  end

  defp colorize_op(nil), do: nil

  defp colorize_op(%{opacity: opacity, color: color, keep_alpha: keep_alpha}) do
    {:ok, op} = Operation.colorize(to_ratio!(opacity), rgb!(color), keep_alpha)
    op
  end

  defp gradient_op(nil), do: nil

  defp gradient_op(%{
         opacity: opacity,
         color: color,
         angle: angle,
         start: start,
         stop: stop
       }) do
    {:ok, op} = Operation.gradient(to_ratio!(opacity), rgb!(color), angle, start, stop)
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

  defp rgb!({red, green, blue}) do
    {:ok, color} = Color.rgb(red, green, blue)
    color
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

  defp plan_guide({:smart, :face_assist} = guide), do: guide
  defp plan_guide({:detect, {_classes, _weights}} = guide), do: guide

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
