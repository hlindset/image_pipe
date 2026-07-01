defmodule ImagePipe.Transform.PlanExecutor do
  @moduledoc false

  # Deferred orientation (#146): EXIF is seeded into State.pending_orientation once,
  # on the first pipeline (seed_orientation opt); user rotate/flip fold into pending
  # rather than emitting eager ops; pre-flush crop/resize are compensated in the
  # storage frame (Orientation.compensate_gravity_for / Orientation.swap_resize);
  # pending is flushed (OrientationFlush via Materializer) at the first materializing
  # op, immediately after a resize, before a region crop, at each pipeline boundary,
  # or at the delivery backstop — whichever is first. An identity pending is cleared
  # without materializing (streaming fast path).

  alias ImagePipe.Plan
  alias ImagePipe.Plan.Color
  alias ImagePipe.Plan.Operation.Background, as: PlanBackground
  alias ImagePipe.Plan.Operation.Bitonal, as: PlanBitonal
  alias ImagePipe.Plan.Operation.Blur, as: PlanBlur
  alias ImagePipe.Plan.Operation.Brightness, as: PlanBrightness
  alias ImagePipe.Plan.Operation.Canvas
  alias ImagePipe.Plan.Operation.Colorize, as: PlanColorize
  alias ImagePipe.Plan.Operation.Contrast, as: PlanContrast
  alias ImagePipe.Plan.Operation.CropGuided
  alias ImagePipe.Plan.Operation.CropRegion
  alias ImagePipe.Plan.Operation.Duotone, as: PlanDuotone
  alias ImagePipe.Plan.Operation.Flip, as: PlanFlip
  alias ImagePipe.Plan.Operation.Gradient, as: PlanGradient
  alias ImagePipe.Plan.Operation.Gray, as: PlanGray
  alias ImagePipe.Plan.Operation.Monochrome, as: PlanMonochrome
  alias ImagePipe.Plan.Operation.Padding, as: PlanPadding
  alias ImagePipe.Plan.Operation.Pixelate, as: PlanPixelate
  alias ImagePipe.Plan.Operation.Resize, as: PlanResize
  alias ImagePipe.Plan.Operation.Rotate, as: PlanRotate
  alias ImagePipe.Plan.Operation.Saturation, as: PlanSaturation
  alias ImagePipe.Plan.Operation.SetFocus
  alias ImagePipe.Plan.Operation.Sharpen, as: PlanSharpen
  alias ImagePipe.Plan.Operation.Trim, as: PlanTrim
  alias ImagePipe.Plan.Pipeline
  alias ImagePipe.Telemetry
  alias ImagePipe.Transform.Chain
  alias ImagePipe.Transform.Focus
  alias ImagePipe.Transform.Geometry
  alias ImagePipe.Transform.InputColorManagement
  alias ImagePipe.Transform.Materializer
  alias ImagePipe.Transform.Operation.Background
  alias ImagePipe.Transform.Operation.Bitonal
  alias ImagePipe.Transform.Operation.Blur
  alias ImagePipe.Transform.Operation.Brightness
  alias ImagePipe.Transform.Operation.Colorize
  alias ImagePipe.Transform.Operation.Contrast
  alias ImagePipe.Transform.Operation.Crop
  alias ImagePipe.Transform.Operation.Duotone
  alias ImagePipe.Transform.Operation.ExtendCanvas
  alias ImagePipe.Transform.Operation.Gradient
  alias ImagePipe.Transform.Operation.Gray
  alias ImagePipe.Transform.Operation.Monochrome
  alias ImagePipe.Transform.Operation.Padding
  alias ImagePipe.Transform.Operation.Pixelate
  alias ImagePipe.Transform.Operation.Resize
  alias ImagePipe.Transform.Operation.Rotate
  alias ImagePipe.Transform.Operation.Saturation
  alias ImagePipe.Transform.Operation.Sharpen
  alias ImagePipe.Transform.Operation.Trim
  alias ImagePipe.Transform.Orientation
  alias ImagePipe.Transform.PendingOrientation
  alias ImagePipe.Transform.State
  alias Vix.Vips.Image, as: VipsImage

  @spec execute(Plan.t(), State.t(), keyword()) ::
          {:ok, State.t()} | {:error, term()}
  def execute(%Plan{pipelines: pipelines, auto_rotate: auto_rotate}, %State{} = state, opts) do
    state = %{
      state
      | detector: ImagePipe.Transform.resolve_detector(Keyword.get(opts, :detector, :default)),
        detector_required: Keyword.get(opts, :detector_required, false),
        telemetry_opts: Telemetry.telemetry_opts(opts)
    }

    state =
      if Keyword.get(opts, :seed_orientation, false) do
        %State{
          state
          | pending_orientation:
              PendingOrientation.from_exif(exif_orientation(state.image), auto_rotate)
        }
      else
        state
      end

    with {:ok, state} <- seed_color_management(state, opts) do
      execute_pipelines(pipelines, state, opts)
    end
  end

  # Input color management is a data-determined preamble seeded once on the real-
  # execution path (the same gate as EXIF orientation), not a Plan operation. It
  # imports the embedded profile into a working space before any operation. A
  # failure is a decode failure (corrupt/unsupported profile), surfaced as
  # {:decode, _} to stay consistent with the materialization contract.
  defp seed_color_management(%State{telemetry_opts: telemetry_opts} = state, opts) do
    if Keyword.get(opts, :seed_orientation, false) do
      Telemetry.span(telemetry_opts, [:transform, :input_color_management], %{}, fn ->
        run_color_management(state, opts)
      end)
    else
      {:ok, state}
    end
  end

  defp run_color_management(%State{image: image} = state, opts) do
    hdr? = Keyword.get(opts, :supports_hdr?, false)
    working_space = InputColorManagement.working_space(VipsImage.interpretation(image), hdr?)

    case InputColorManagement.condition(state, supports_hdr?: hdr?) do
      {:ok, %State{} = new_state} ->
        {{:ok, new_state},
         %{result: :ok, working_space: working_space, imported?: new_state.color_imported?}}

      {:error, {InputColorManagement, reason}} ->
        {{:error, {:decode, reason}},
         %{result: :processing_error, working_space: working_space, imported?: false}}
    end
  end

  defp exif_orientation(image) do
    case VipsImage.header_value(image, "orientation") do
      {:ok, value} when is_integer(value) -> value
      _ -> 1
    end
  end

  defp execute_pipelines(pipelines, %State{} = state, opts) do
    Enum.reduce_while(pipelines, {:ok, state}, fn pipeline, {:ok, state} ->
      case execute_pipeline(pipeline, state, opts) do
        {:ok, %State{} = state} -> {:cont, {:ok, state}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  defp execute_pipeline(%Pipeline{operations: operations}, %State{} = state, opts) do
    initial_context = %{effective_padding_scale: nil, canvas_preserving_padding_scale: nil}

    Enum.reduce_while(operations, {:ok, state, initial_context}, fn operation,
                                                                    {:ok, state, context} ->
      context = update_execution_context(operation, state, context)

      case execute_operation(operation, state, context, opts) do
        {:ok, %State{} = state} -> {:cont, {:ok, state, context}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
    # Resolve any still-pending orientation at the pipeline boundary. EXIF is
    # seeded once for the whole plan (on the first pipeline) and a pipeline's
    # output is the next pipeline's input, so each pipeline must end in the
    # display frame — deferral is scoped to a single pipeline rather than spanning
    # the chain. This is a backstop: an earlier resize / materializing op / region
    # crop usually flushed already (making this a no-op), and an identity
    # orientation is cleared without materializing (streaming fast path). It does
    # real pixel work only when a rotation is still pending here (e.g. a pipeline
    # of rotate + streaming effects, with no resize to trigger an earlier flush).
    |> case do
      {:ok, state, _context} -> flush_if_pending(state)
      {:error, _reason} = error -> error
    end
  end

  defp flush_if_pending(%State{pending_orientation: nil} = state), do: {:ok, state}

  # An identity pending orientation has no pixel work: clear it without forcing a
  # materialize so the streaming (no-rotation) fast path is preserved — the delivery
  # backstop still materializes if nothing else did.
  defp flush_if_pending(%State{pending_orientation: %PendingOrientation{} = po} = state) do
    if PendingOrientation.identity?(po) do
      {:ok, %State{state | pending_orientation: nil}}
    else
      case Materializer.materialize(state) do
        {:ok, %State{} = state} -> {:ok, state}
        {:error, reason} -> {:error, {:materialize_error, reason}}
      end
    end
  end

  # Right-angle, non-mirrored rotation defers into pending_orientation (lossless
  # vips_rot at the flush, imgproxy parity, #211 seam avoidance). Same body as before.
  defp execute_operation(%PlanRotate{angle: angle, mirror: false}, %State{} = state, _ctx, _opts)
       when angle in [0, 90, 180, 270] do
    po = state.pending_orientation || %PendingOrientation{}
    {:ok, %State{state | pending_orientation: PendingOrientation.fold_rotate(po, angle)}}
  end

  # Arbitrary angle or mirror: run as a materializing chain op. Chain's pre-op
  # materialize flushes any pending EXIF orientation first, so the rotation lands
  # in the display frame (EXIF auto-orient -> then user rotation).
  defp execute_operation(%PlanRotate{} = operation, %State{} = state, ctx, opts) do
    run_executable(operation, state, ctx, opts)
  end

  defp execute_operation(%PlanFlip{axis: axis}, %State{} = state, _ctx, _opts) do
    po = state.pending_orientation || %PendingOrientation{}
    {:ok, %State{state | pending_orientation: PendingOrientation.fold_flip(po, axis)}}
  end

  # Positional focus: resolve the operand against the live frame at this chain
  # position and store the carried point. No pixel work, no flush — a following
  # cover resize still sizes against the (possibly shrunk) source frame. The user
  # authors focus in the display frame; Focus.resolve maps it into the live
  # storage frame when an orientation is pending.
  defp execute_operation(%SetFocus{point: operand}, %State{} = state, _ctx, _opts) do
    ctx = %{
      display: display_live_dims(state),
      storage: {VipsImage.width(state.image), VipsImage.height(state.image)},
      decode_shrink: state.decode_shrink
    }

    {:ok, %State{state | focus: Focus.resolve(operand, ctx, state.pending_orientation)}}
  end

  # A crop runs before the residual resize in the fixed pipeline order. After it
  # executes, the live (cropped) image is the frame the resize must size against —
  # so clear the stored source frame (source_dimensions/decode_shrink). With
  # shrink-on-load through a preceding crop (#151) the decode was shrunk and the
  # crop coordinates were already rescaled by `decode_shrink`; leaving the stored
  # original dims set would make the resize size against the un-cropped original.
  # When no shrink fired both are already nil and this is a no-op.
  defp execute_operation(%CropRegion{} = operation, %State{} = state, ctx, opts) do
    with {:ok, %State{} = state} <- do_execute_crop(operation, state, ctx, opts) do
      {:ok, clear_source_frame(state)}
    end
  end

  defp execute_operation(%CropGuided{} = operation, %State{} = state, ctx, opts) do
    with {:ok, %State{} = state} <- do_execute_crop(operation, state, ctx, opts) do
      {:ok, clear_source_frame(state)}
    end
  end

  # Resize: compensate for a pending orientation, run, then flush so the cover
  # result-crop and tail are post-flush/literal.
  #
  # A quarter turn cannot be compensated by swapping the *request* and resolving
  # in the storage frame: imgproxy resolves scale in the DISPLAY frame (source
  # dims already swapped by ExtractGeometry) and swaps only the final scale
  # factors (scale.go:10-12), so the min-dimension cross-axis coupling
  # (prepare.go:146-158) happens on the display axes. "Swap the request, resolve
  # against storage" is the algebraic dual for plain fit/fill but BREAKS the
  # min-dim coupling. For the quarter-turn cover/auto-cover expansion we instead
  # resolve in the display frame and swap the resolved RESULT dims into storage.
  defp execute_operation(
         %PlanResize{} = operation,
         %State{pending_orientation: po} = state,
         ctx,
         opts
       )
       when not is_nil(po) do
    cond do
      PendingOrientation.identity?(po) ->
        run_executable(operation, state, ctx, opts)

      PendingOrientation.quarter_turn?(po) and cover_resize?(operation, state) ->
        # The display-frame resolver already emits a storage-frame (forcing)
        # resize and a display-frame result-crop; only the crop needs the gravity/
        # offset remap and dim swap (compensate_crop), not the resize.
        executable =
          operation
          |> cover_resize_and_crop_display_frame(state)
          |> Enum.map(fn
            %Crop{} = crop -> compensate_crop(crop, po)
            other -> other
          end)

        with {:ok, state} <- Chain.execute(state, executable, opts) do
          flush_if_pending(state)
        end

      true ->
        # Inlined so compensation sits between translate and execute.
        executable =
          operation
          |> executable_operations(state, ctx)
          |> compensate_resize(po)

        with {:ok, state} <- Chain.execute(state, executable, opts) do
          flush_if_pending(state)
        end
    end
  end

  # Padding (imgproxy stage 12), pixelate (applyFilters, stage 9), and gradient
  # (applyFilters, stage 9) all run AFTER rotateAndFlip (stage 7), i.e. in the
  # display frame. ImagePipe defers orientation, so when one of these runs with an
  # orientation still pending — the resize-less path, since any resize would already
  # have flushed — flush first so the op decides in the display frame: padding lands
  # on display sides, pixelate's block grid aligns to the display edges (partial
  # edge blocks at a non-multiple size otherwise land on the rotated edge), and the
  # gradient's directional ramp runs along the display axes (its dark end otherwise
  # lands on a storage edge). An identity pending is cleared without materializing
  # (streaming fast path preserved). colorize is uniform and commutes with
  # orientation, so it needs no such clause.
  defp execute_operation(
         %PlanPadding{} = operation,
         %State{pending_orientation: po} = state,
         ctx,
         opts
       )
       when not is_nil(po) do
    with {:ok, %State{} = state} <- flush_if_pending(state) do
      run_executable(operation, state, ctx, opts)
    end
  end

  defp execute_operation(
         %PlanPixelate{} = operation,
         %State{pending_orientation: po} = state,
         ctx,
         opts
       )
       when not is_nil(po) do
    with {:ok, %State{} = state} <- flush_if_pending(state) do
      run_executable(operation, state, ctx, opts)
    end
  end

  defp execute_operation(
         %PlanGradient{} = operation,
         %State{pending_orientation: po} = state,
         ctx,
         opts
       )
       when not is_nil(po) do
    with {:ok, %State{} = state} <- flush_if_pending(state) do
      run_executable(operation, state, ctx, opts)
    end
  end

  # Trim is imgproxy's one pre-orientation op (stage 2 < rotateAndFlip stage 7):
  # it trims the storage frame. ImagePipe's trim materializes (it needs random
  # access), but the orienting materialization would flush orientation first and
  # trim the display frame. So when an orientation is pending, materialize WITHOUT
  # orienting and run trim on the storage frame, leaving pending for the boundary
  # flush — matching imgproxy's storage-frame trim box (smart top-left corner,
  # equal_hor/equal_ver axes). An identity pending trims literally (no orientation
  # to defer). A storage-frame copy_memory failure is a decode failure, wrapped as
  # {:materialize_error, _} the same way the flush path is.
  defp execute_operation(
         %PlanTrim{} = operation,
         %State{pending_orientation: po} = state,
         ctx,
         opts
       )
       when not is_nil(po) do
    if PendingOrientation.identity?(po) do
      run_executable(operation, state, ctx, opts)
    else
      case Materializer.materialize_without_orientation(state) do
        {:ok, %State{} = state} -> run_executable(operation, state, ctx, opts)
        {:error, reason} -> {:error, {:materialize_error, reason}}
      end
    end
  end

  defp execute_operation(operation, %State{} = state, context, opts) do
    run_executable(operation, state, context, opts)
  end

  defp run_executable(operation, %State{} = state, context, opts) do
    operation
    |> executable_operations(state, context)
    |> then(&Chain.execute(state, &1, opts))
  end

  defp clear_source_frame(%State{} = state),
    do: %State{state | source_dimensions: nil, decode_shrink: nil}

  # Region crop runs literally on oriented pixels: flush pending first. The flush
  # rotates the still-shrunk image into the display frame, so the region coords —
  # authored in the display frame — rescale against swapped per-axis decode_shrink
  # factors under a quarter turn (the display width axis came from the storage height
  # axis, and vice versa). orient_decode_shrink applies that swap before the post-
  # flush crop reads decode_shrink; a half turn / flip leaves the factors put.
  defp do_execute_crop(
         %CropRegion{} = operation,
         %State{pending_orientation: po} = state,
         ctx,
         opts
       )
       when not is_nil(po) do
    with {:ok, %State{} = state} <- flush_if_pending(state) do
      oriented_shrink = orient_decode_shrink(state.decode_shrink, po)

      do_execute_crop(
        operation,
        %State{state | pending_orientation: nil, decode_shrink: oriented_shrink},
        ctx,
        opts
      )
    end
  end

  # Gravity crop: compensate the built %Crop{} gravity (type + offsets) and swap
  # its dims for a quarter turn, so cropping in the storage frame then flushing
  # matches cropping in the oriented frame.
  defp do_execute_crop(
         %CropGuided{} = operation,
         %State{pending_orientation: po} = state,
         ctx,
         opts
       )
       when not is_nil(po) do
    cond do
      PendingOrientation.identity?(po) ->
        run_executable(operation, state, ctx, opts)

      # Smart/detect crops materialize, so the auto-flush at the materializing crop
      # fires first and the crop sees oriented (display-frame) pixels — emit literal.
      materializing_gravity?(operation.guide) ->
        run_executable(operation, state, ctx, opts)

      true ->
        # Inlined so compensation sits between translate and execute. decode_shrink
        # is storage-frame; the crop dims are display-frame and `compensate_crop`
        # swaps their axes for the quarter turn AFTER the rescale, so pre-swap the
        # per-axis factors (orient_decode_shrink) — otherwise a display axis is
        # divided by the wrong storage factor (#185).
        oriented_shrink = orient_decode_shrink(state.decode_shrink, po)

        executable =
          operation
          |> executable_operations(%State{state | decode_shrink: oriented_shrink}, ctx)
          |> Enum.map(&compensate_crop(&1, po))

        Chain.execute(state, executable, opts)
    end
  end

  # No pending orientation: crop runs literally in the live frame.
  defp do_execute_crop(operation, %State{} = state, ctx, opts) do
    run_executable(operation, state, ctx, opts)
  end

  # Pre-swap decode_shrink's per-axis factors for a quarter turn so the later
  # `compensate_crop` axis swap lands each display axis on the factor of the storage
  # axis it becomes (rationale at the call site). A half turn (`quarter_turn?` false)
  # does not swap dims, so its factors stay put.
  defp orient_decode_shrink(nil, _po), do: nil

  defp orient_decode_shrink(%{w: w, h: h} = shrink, %PendingOrientation{} = po) do
    if PendingOrientation.quarter_turn?(po), do: %{shrink | w: h, h: w}, else: shrink
  end

  defp materializing_gravity?(:smart), do: true
  defp materializing_gravity?({:smart, _}), do: true
  defp materializing_gravity?({:detect, _}), do: true
  defp materializing_gravity?(_other), do: false

  # A carried-focus crop reads State.focus, which lives in the storage frame and
  # already tracks the focused content — so it must NOT be gravity-remapped like an
  # imgproxy focus-point spec. Only the crop box needs the quarter-turn dim swap;
  # the flush then rotates image + focus together. (imgproxy never emits :carried.)
  # This clause MUST precede the {crop_from: :gravity, gravity} clause below, which
  # a :carried crop would otherwise match (it is crop_from: :gravity).
  #
  # A nil State.focus makes Crop.execute fall back to a centred crop, so this crop
  # still needs the center-discard-side compensation (#146 Bug 2) that the gravity
  # clause applies — otherwise a focus-less TwicPics cover under a pending flip/turn
  # with an odd centre-crop discard keeps the wrong display-side pixel (a regression
  # from the pre-#321 `:center` guide, which took the gravity clause). For a set
  # focus the crop resolves to `:fp` gravity, which ignores center_bias, so setting
  # it unconditionally here is harmless.
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
      # Smart/detect crops materialize; the auto-flush fires first so they run on
      # display-frame pixels. Leave them literal (no compensation).
      crop
    else
      # The executable crop carries offsets in their tagged unit form
      # ({:pixels, v} | {:scale, v} | {:scale, n, d} | {:percent, v} | number).
      # Orientation.compensate_gravity_for/2 ports imgproxy's RotateAndFlip, which
      # operates on the bare float offset (gravity.go uses a single float64 X/Y).
      # Unwrap to the bare magnitude, compensate, then re-wrap — and on a quarter
      # turn the X/Y *values* swap (g.X, g.Y = g.Y, ...), so the unit wrappers swap
      # with them. The parser emits both offsets in the same unit, but tracking the
      # wrapper per-axis keeps the swap correct even if they ever differ.
      {x_unit, x_value} = split_offset(crop.x_offset)
      {y_unit, y_value} = split_offset(crop.y_offset)

      {gravity, x_value, y_value} =
        Orientation.compensate_gravity_for({gravity, x_value, y_value}, po)

      {x_unit, y_unit} =
        if PendingOrientation.quarter_turn?(po), do: {y_unit, x_unit}, else: {x_unit, y_unit}

      # A centered crop with an odd extent difference discards one extra pixel; the
      # storage-frame near-side bias lands on the wrong display side when the flush
      # reverses that storage axis. center_discard_sides/1 reports per storage axis
      # whether to flip the discard so the kept pixel matches imgproxy's display-
      # frame placement (#146 Bug 2). Harmless on non-center axes (ignored there).
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
  # compensation negates/swaps the magnitude; the rewrap restores the unit so the
  # executable crop still resolves the offset against the right bounds/scale.
  defp split_offset({:pixels, value}), do: {&{:pixels, &1}, value * 1.0}
  defp split_offset({:scale, value}), do: {&{:scale, &1}, value * 1.0}
  defp split_offset({:scale, num, den}), do: {&{:scale, &1}, num / den}
  defp split_offset({:percent, value}), do: {&{:percent, &1 * 100}, value / 100}
  defp split_offset(value) when is_number(value), do: {& &1, value * 1.0}

  # Compensate a resize expansion in the storage frame for the fit/force/stretch
  # and non-quarter-turn cover paths: the resize's requested dims swap on a quarter
  # turn (the algebraic dual that holds when there is no cross-axis min-dim
  # coupling), and any trailing cover result-crop is compensated like a gravity
  # crop (dim swap + gravity/offset remap). The whole expansion runs pre-flush; the
  # caller flushes right after, leaving the tail post-flush/literal.
  #
  # The quarter-turn cover path does NOT use this — its min-dim coupling forces a
  # display-frame resolve (cover_resize_and_crop_display_frame) and only its crop
  # needs compensation.
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

  defp update_execution_context(%PlanResize{} = operation, %State{} = state, context) do
    scale = resize_padding_scale(operation, state, :resize)
    canvas_preserving_scale = resize_padding_scale(operation, state, :canvas_preserving)

    %{
      context
      | effective_padding_scale: scale,
        canvas_preserving_padding_scale: canvas_preserving_scale
    }
  end

  defp update_execution_context(_operation, %State{}, context), do: context

  defp executable_operations(%PlanResize{mode: :fit} = operation, %State{} = state, _context) do
    fit_resize_and_result_crop(resize_from(operation, :fit), operation, state)
  end

  defp executable_operations(%PlanResize{mode: :cover} = operation, %State{} = state, _context) do
    operation
    |> resize_from(:cover)
    |> cover_resize_and_crop(
      state,
      tagged_executable_gravity(operation.guide),
      {operation.x_offset, operation.y_offset}
    )
  end

  defp executable_operations(%PlanResize{mode: :stretch} = operation, %State{}, _context) do
    [resize_from(operation, :stretch)]
  end

  defp executable_operations(%PlanResize{mode: :auto} = operation, %State{} = state, _context) do
    branch = plan_resize_branch(operation, state)
    resize = resize_from(operation, branch)

    tagged_executable_resize_operations(branch, resize, operation, state)
  end

  defp executable_operations(%CropGuided{} = operation, %State{} = state, _context) do
    crop =
      %Crop{
        width: crop_dimension(operation.width),
        height: crop_dimension(operation.height),
        crop_from: :gravity,
        gravity: tagged_executable_gravity(operation.guide),
        x_offset: operation.x_offset,
        y_offset: operation.y_offset,
        aspect_ratio: operation.aspect_ratio,
        enlarge: operation.enlarge
      }

    [rescale_crop_for_decode_shrink(crop, state.decode_shrink)]
  end

  defp executable_operations(%CropRegion{} = operation, %State{} = state, _context) do
    crop =
      %Crop{
        width: crop_dimension(operation.width),
        height: crop_dimension(operation.height),
        crop_from: %{
          left: crop_coordinate(operation.x),
          top: crop_coordinate(operation.y)
        },
        reject_out_of_bounds: reject_region_out_of_bounds?(operation, state)
      }

    [rescale_crop_for_decode_shrink(crop, state.decode_shrink)]
  end

  defp executable_operations(%Canvas{} = operation, %State{}, context) do
    # imgproxy dpr-scales the extend target box (TargetWidth = Scale(width, DprScale),
    # prepare.go) and absolute extend offsets (RoundToEven(offset * DprScale),
    # calc_position.go), keeping the composition dpr-stable — it skips the enlarge-off
    # DprScale compensation when extend is enabled. The resize op records exactly that
    # composition-preserving scale; thread it into the canvas op the same way padding
    # does via scaled_padding_side. (Like padding, zoom is not folded into the scale.)
    scale = context.canvas_preserving_padding_scale || 1.0

    width = operation.width |> canvas_dimension() |> scale_canvas_dimension(scale)
    height = operation.height |> canvas_dimension() |> scale_canvas_dimension(scale)

    [
      %ExtendCanvas{
        rule: canvas_rule(width, height),
        gravity: tagged_executable_gravity(operation.placement),
        x_offset: scale_extend_offset(operation.x_offset, scale),
        y_offset: scale_extend_offset(operation.y_offset, scale),
        background: executable_fill(operation.fill)
      }
    ]
  end

  defp executable_operations(%PlanPadding{} = operation, %State{} = state, context) do
    scale = effective_padding_scale(operation, state, context)

    [
      %Padding{
        top: scaled_padding_side(operation.top, scale),
        right: scaled_padding_side(operation.right, scale),
        bottom: scaled_padding_side(operation.bottom, scale),
        left: scaled_padding_side(operation.left, scale),
        fill: executable_fill(operation.fill)
      }
    ]
  end

  defp executable_operations(%PlanBackground{} = operation, %State{}, _context) do
    [%Background{color: Color.to_rgba_list(operation.color)}]
  end

  defp executable_operations(%PlanBlur{sigma: sigma}, %State{}, _context),
    do: [%Blur{sigma: sigma}]

  defp executable_operations(%PlanSharpen{sigma: sigma}, %State{}, _context),
    do: [%Sharpen{sigma: sigma}]

  defp executable_operations(%PlanPixelate{size: size}, %State{}, _context),
    do: [%Pixelate{size: size}]

  defp executable_operations(%PlanMonochrome{} = operation, %State{}, _context) do
    [
      %Monochrome{
        intensity: tagged_ratio_to_float(operation.intensity),
        color: Color.to_rgb_list(operation.color)
      }
    ]
  end

  defp executable_operations(%PlanDuotone{} = operation, %State{}, _context) do
    [
      %Duotone{
        intensity: tagged_ratio_to_float(operation.intensity),
        shadow: Color.to_rgb_list(operation.shadow),
        highlight: Color.to_rgb_list(operation.highlight)
      }
    ]
  end

  defp executable_operations(%PlanBrightness{value: value}, %State{}, _context),
    do: [%Brightness{value: value}]

  defp executable_operations(%PlanContrast{value: value}, %State{}, _context),
    do: [%Contrast{value: value}]

  defp executable_operations(%PlanBitonal{}, %State{}, _context), do: [%Bitonal{}]

  defp executable_operations(%PlanGray{}, %State{}, _context), do: [%Gray{}]

  defp executable_operations(%PlanRotate{angle: angle, mirror: mirror}, %State{}, _context),
    do: [%Rotate{angle: angle, mirror: mirror}]

  defp executable_operations(%PlanSaturation{value: value}, %State{}, _context),
    do: [%Saturation{value: value}]

  defp executable_operations(%PlanColorize{} = operation, %State{}, _context) do
    [
      %Colorize{
        opacity: tagged_ratio_to_float(operation.opacity),
        color: Color.to_rgb_list(operation.color),
        keep_alpha: operation.keep_alpha
      }
    ]
  end

  defp executable_operations(%PlanGradient{} = operation, %State{}, _context) do
    [
      %Gradient{
        opacity: tagged_ratio_to_float(operation.opacity),
        color: Color.to_rgb_list(operation.color),
        angle: operation.angle,
        start: operation.start,
        stop: operation.stop
      }
    ]
  end

  defp executable_operations(%PlanTrim{} = operation, %State{}, _context),
    do: [
      %Trim{
        threshold: operation.threshold,
        background: operation.background,
        equal_hor: operation.equal_hor,
        equal_ver: operation.equal_ver
      }
    ]

  defp tagged_executable_resize_operations(
         :cover,
         %Resize{} = resize,
         operation,
         %State{} = state
       ) do
    cover_resize_and_crop(
      resize,
      state,
      tagged_executable_gravity(operation.guide),
      {operation.x_offset, operation.y_offset}
    )
  end

  defp tagged_executable_resize_operations(:fit, %Resize{} = resize, operation, %State{} = state) do
    fit_resize_and_result_crop(resize, operation, state)
  end

  # A cover resize scales the whole image to cover the box (the intermediate
  # always overflows it), then crops back. Like the fit path's cropToResult, the
  # crop box is the literal requested dimensions (result_box_*), NOT the
  # min-expanded target: when mw/mh drive the cover scale past the requested box,
  # the min-dimension guarantee survives on the short axis while the long axis is
  # trimmed back to what was asked for (imgproxy prepare.go TargetWidth + crop.go
  # cropToResult, #236). The intermediate covers result_box on both axes, so the
  # crop always fires.
  defp cover_resize_and_crop(%Resize{} = resize, %State{} = state, gravity, {x_offset, y_offset}) do
    {src_w, src_h} = State.effective_source_dims(state)

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
  defp fit_resize_and_result_crop(%Resize{} = resize, %PlanResize{} = operation, %State{} = state) do
    {src_w, src_h} = State.effective_source_dims(state)
    dimensions = Resize.resolve_dimensions(resize, source_width: src_w, source_height: src_h)

    if fit_result_crop_bites?(dimensions) do
      [
        resize,
        %Crop{
          width: result_box_crop_dimension(dimensions.result_box_width),
          height: result_box_crop_dimension(dimensions.result_box_height),
          crop_from: :gravity,
          gravity: tagged_executable_gravity(operation.guide),
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
  defp cover_resize?(%PlanResize{mode: :cover}, %State{}), do: true

  defp cover_resize?(%PlanResize{mode: :auto} = operation, %State{} = state),
    do: plan_resize_branch(operation, state) == :cover

  defp cover_resize?(%PlanResize{}, %State{}), do: false

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
  defp cover_resize_and_crop_display_frame(%PlanResize{} = operation, %State{} = state) do
    {src_w, src_h} = State.effective_source_dims(state)
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
        gravity: tagged_executable_gravity(operation.guide),
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

  defp crop_dimension(:full_axis), do: :auto
  defp crop_dimension({:px, value}), do: {:pixels, value}
  defp crop_dimension({:ratio, numerator, denominator}), do: {:scale, numerator, denominator}

  defp crop_coordinate({:px, value}), do: {:pixels, value}
  defp crop_coordinate({:ratio, numerator, denominator}), do: {:scale, numerator, denominator}

  defp reject_region_out_of_bounds?(%CropRegion{on_out_of_bounds: :clamp}, _state), do: false

  # Decide "wholly outside" in the ORIGINAL source frame (`effective_source_dims`),
  # against the un-rescaled request coordinates — a region entirely outside the image
  # is a property of the request vs. the reported source dimensions, independent of
  # the decoded resolution. Evaluating it after `rescale_crop_for_decode_shrink` would
  # let the coordinate rescale's rounding (`round(orig / shrink)`) push a near-edge
  # *partial* overlap up to the shrunk width and spuriously reject a serviceable
  # request. `resolve_position` clamps negatives to 0, so the only way to be wholly
  # outside is an origin at or past the far edge.
  defp reject_region_out_of_bounds?(%CropRegion{on_out_of_bounds: :reject} = operation, state) do
    {src_w, src_h} = State.effective_source_dims(state)

    Geometry.resolve_position(crop_coordinate(operation.x), src_w) >= src_w or
      Geometry.resolve_position(crop_coordinate(operation.y), src_h) >= src_h
  end

  # Rescale an executable crop's ABSOLUTE coordinates for shrink-on-load through a
  # preceding crop (#151). Shrink-on-load decoded the image smaller by the realized
  # per-axis factor, so a crop expressed in stored-source pixels must divide by that
  # factor to select the same region on the shrunk frame — imgproxy's
  # `CropWidth = max(1, Shrink(CropWidth, wpreshrink))` and the absolute-gravity-
  # offset adjustment (scale_on_load.go:136-153). Width/height and explicit
  # region coordinates rescale unconditionally when absolute; pixel gravity offsets
  # rescale only for non-focus-point gravity (imgproxy guards on `Type !=
  # GravityFocusPoint`, since focus coords are inherently relative). Relative
  # ({:scale,_}/{:percent,_}) dims, coords, and offsets, and `:auto`, are untouched
  # because they already track the shrunk frame proportionally.
  defp rescale_crop_for_decode_shrink(%Crop{} = crop, nil), do: crop

  defp rescale_crop_for_decode_shrink(%Crop{} = crop, %{w: wshrink, h: hshrink}) do
    %Crop{
      crop
      | width: shrink_abs_dimension(crop.width, wshrink),
        height: shrink_abs_dimension(crop.height, hshrink),
        crop_from: shrink_crop_from(crop.crop_from, wshrink, hshrink),
        x_offset: shrink_abs_offset(crop.x_offset, crop.gravity, wshrink),
        y_offset: shrink_abs_offset(crop.y_offset, crop.gravity, hshrink)
    }
  end

  # imgproxy: CropWidth = max(1, Round(CropWidth / preshrink)).
  defp shrink_abs_dimension({:pixels, value}, shrink),
    do: {:pixels, max(1, round(value / shrink))}

  defp shrink_abs_dimension(other, _shrink), do: other

  defp shrink_crop_from(%{left: left, top: top}, wshrink, hshrink) do
    %{left: shrink_abs_coordinate(left, wshrink), top: shrink_abs_coordinate(top, hshrink)}
  end

  defp shrink_crop_from(other, _wshrink, _hshrink), do: other

  defp shrink_abs_coordinate({:pixels, value}, shrink),
    do: {:pixels, max(0, round(value / shrink))}

  defp shrink_abs_coordinate(other, _shrink), do: other

  # Absolute pixel gravity offsets rescale by RoundToEven(offset / preshrink), but
  # NOT for focus-point gravity (imgproxy leaves GravityFocusPoint offsets alone —
  # focus coords are relative). Relative offsets ({:scale,_}/{:percent,_}/number)
  # are already proportional to the shrunk bounds and pass through.
  defp shrink_abs_offset(offset, {:fp, _x, _y}, _shrink), do: offset

  defp shrink_abs_offset({:pixels, value}, _gravity, shrink),
    do: {:pixels, round_half_to_even(value / shrink)}

  defp shrink_abs_offset(other, _gravity, _shrink), do: other

  defp canvas_dimension(:auto), do: :auto
  defp canvas_dimension({:px, value}), do: {:pixels, value}
  defp canvas_dimension({:ratio, numerator, denominator}), do: {:ratio, numerator / denominator}

  defp canvas_rule({:ratio, width}, {:ratio, height}), do: {:aspect_ratio, {width, height}}
  defp canvas_rule(width, height), do: {:dimensions, width, height}

  # imgproxy scales the fixed extend target box by the effective DPR
  # (TargetWidth = imath.Scale(width, DprScale); imath.Scale rounds half away from
  # zero, matching Erlang round/1). `:auto` (keep the image size) and `{:ratio, _}`
  # (the aspect-ratio canvas, computed from the already-dpr-scaled image) are not
  # pixel boxes and are left untouched.
  defp scale_canvas_dimension({:pixels, value}, scale), do: {:pixels, round(value * scale)}
  defp scale_canvas_dimension(dimension, _scale), do: dimension

  # imgproxy dpr-scales an absolute extend offset (|offset| >= 1.0) by
  # imath.RoundToEven (calc_position.go). A fractional (|offset| < 1.0) offset is
  # imgproxy's "fraction of the dimension" form, which ImagePipe does not implement;
  # it is passed through unchanged rather than mis-scaled.
  defp scale_extend_offset(offset, scale) when abs(offset) >= 1.0,
    do: round_half_to_even(offset * scale)

  defp scale_extend_offset(offset, _scale), do: offset

  defp executable_fill(:transparent), do: :transparent

  defp executable_fill({:solid, %Color{alpha: {:ratio, numerator, denominator}} = color})
       when numerator == denominator do
    {:color, Color.to_rgb_list(color)}
  end

  defp executable_fill({:solid, %Color{} = color}), do: {:color, Color.to_rgba_list(color)}

  defp effective_padding_scale(
         %PlanPadding{pixel_ratio: {:effective, _fallback, :resize}},
         %State{},
         %{effective_padding_scale: scale}
       )
       when is_number(scale),
       do: scale

  defp effective_padding_scale(
         %PlanPadding{pixel_ratio: {:effective, _fallback, :canvas_preserving}},
         %State{},
         %{canvas_preserving_padding_scale: scale}
       )
       when is_number(scale),
       do: scale

  defp effective_padding_scale(
         %PlanPadding{pixel_ratio: {:ratio, numerator, denominator}},
         %State{},
         _context
       ),
       do: numerator / denominator

  defp effective_padding_scale(
         %PlanPadding{pixel_ratio: {:effective, {:ratio, numerator, denominator}, _mode}},
         %State{},
         _context
       ),
       do: numerator / denominator

  defp resize_padding_scale(%PlanResize{enlargement: :allow} = operation, %State{}, _mode),
    do: tagged_dpr_float(operation.dpr)

  defp resize_padding_scale(%PlanResize{} = operation, %State{} = state, mode) do
    # imgproxy computes the no-enlarge padding/DPR cap entirely in the display
    # frame: the fitted target dims (`base.requested_*`) and the source it caps
    # them against are both ExtractGeometry-swapped under a quarter turn. Resolve
    # `base` against the display-frame source so the fitted dims match imgproxy's
    # (a fit against the storage frame fits the transposed axes and skews the cap).
    {src_w, src_h} = display_source_dims(state)
    requested_scale = tagged_dpr_float(operation.dpr)
    branch = plan_resize_branch(operation, state)
    resize = resize_from(operation, branch)

    base =
      %{resize | dpr: 1.0, enlarge: true}
      |> Resize.resolve_dimensions(
        source_width: src_w,
        source_height: src_h
      )

    max_without_enlarge = max_padding_scale_without_enlarge(base, state)
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
         %State{}
       ),
       do: 1.0

  defp max_padding_scale_without_enlarge(
         %{requested_width: width, requested_height: height},
         %State{} = state
       ) do
    # The requested box is display-frame; size it against the display-frame source
    # so the no-enlarge cap couples the same axes imgproxy does (its SrcWidth is
    # ExtractGeometry-swapped under a quarter turn). Mixing the display-frame
    # request with storage-frame source dims crosses axes under a pending quarter
    # turn (#182).
    {src_w, src_h} = display_source_dims(state)
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

  defp plan_resize_branch(%PlanResize{mode: :fit}, %State{}), do: :fit
  defp plan_resize_branch(%PlanResize{mode: :cover}, %State{}), do: :cover
  defp plan_resize_branch(%PlanResize{mode: :stretch}, %State{}), do: :stretch

  defp plan_resize_branch(%PlanResize{mode: :auto} = operation, %State{} = state) do
    # imgproxy's ResizeAuto compares srcW−srcH against dstW−dstH on the DISPLAY
    # axes — ExtractGeometry swaps the source dims for a quarter turn before the
    # comparison (prepare.go). Classify against the display-frame source so an
    # EXIF 5–8 / rot:90/270 source is not judged on transposed axes (#182).
    {src_w, src_h} = display_source_dims(state)

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
  defp display_source_dims(%State{pending_orientation: po} = state) do
    {w, h} = State.effective_source_dims(state)

    if not is_nil(po) and PendingOrientation.quarter_turn?(po), do: {h, w}, else: {w, h}
  end

  # The live image dims in the display frame: a focus operand resolves against the
  # running frame at its chain position (the live image, possibly already resized
  # — unlike display_source_dims, which uses the residual-resize source frame),
  # with the axes swapped when a quarter turn is pending.
  defp display_live_dims(%State{pending_orientation: po, image: image}) do
    w = VipsImage.width(image)
    h = VipsImage.height(image)

    if not is_nil(po) and PendingOrientation.quarter_turn?(po), do: {h, w}, else: {w, h}
  end

  defp scaled_padding_side({:px, value}, scale), do: round_half_to_even(value * scale)

  defp round_half_to_even(value) do
    floor = Float.floor(value)
    fraction = value - floor

    cond do
      fraction < 0.5 -> trunc(floor)
      fraction > 0.5 -> trunc(floor) + 1
      rem(trunc(floor), 2) == 0 -> trunc(floor)
      true -> trunc(floor) + 1
    end
  end

  defp tagged_executable_gravity(:center), do: {:anchor, :center, :center}
  defp tagged_executable_gravity(:top_left), do: {:anchor, :left, :top}
  defp tagged_executable_gravity(:top), do: {:anchor, :center, :top}
  defp tagged_executable_gravity(:top_right), do: {:anchor, :right, :top}
  defp tagged_executable_gravity(:left), do: {:anchor, :left, :center}
  defp tagged_executable_gravity(:right), do: {:anchor, :right, :center}
  defp tagged_executable_gravity(:bottom_left), do: {:anchor, :left, :bottom}
  defp tagged_executable_gravity(:bottom), do: {:anchor, :center, :bottom}
  defp tagged_executable_gravity(:bottom_right), do: {:anchor, :right, :bottom}
  defp tagged_executable_gravity({:anchor, x, y}), do: {:anchor, x, y}

  # Carried (TwicPics) gravity passes through to the executable Crop, which reads
  # State.focus and normalizes it to a focal point at the libvips boundary.
  defp tagged_executable_gravity(:carried), do: :carried

  defp tagged_executable_gravity({:focal, x, y}),
    do: {:fp, tagged_ratio_to_float(x), tagged_ratio_to_float(y)}

  defp tagged_executable_gravity(:smart), do: :smart
  defp tagged_executable_gravity({:smart, :face_assist}), do: {:smart, :face_assist}
  defp tagged_executable_gravity({:detect, {spec, weights}}), do: {:detect, {spec, weights}}

  defp tagged_logical_pixels({:px, value}), do: value
  defp tagged_logical_pixels(_dimension), do: :unknown

  defp tagged_dpr_float({:ratio, numerator, denominator}), do: numerator / denominator

  defp tagged_ratio_to_float({:ratio, numerator, denominator}), do: numerator / denominator

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
