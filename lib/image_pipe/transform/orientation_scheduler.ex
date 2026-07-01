defmodule ImagePipe.Transform.OrientationScheduler do
  @moduledoc false

  # Deferred-orientation execution policy (#146/#182/#185/#211). Owns the per-op
  # decisions that interact with a pending EXIF/user orientation: right-angle
  # rotate/flip fold into State.pending_orientation; a resize compensates then
  # flushes (Orientation.compensate_gravity_for / Orientation.swap_resize, with the
  # quarter-turn cover resolved in the display frame); padding/pixelate/gradient
  # flush first so they decide in the display frame; trim materializes without
  # orienting to trim the storage frame; region/gravity crops flush-and-compensate.
  # Pending is flushed (OrientationFlush via Materializer) at the first
  # materializing op, immediately after a resize, before a region crop, at each
  # pipeline boundary (PlanExecutor calls flush_if_pending/1 there), or the delivery
  # backstop — whichever is first. An identity pending is cleared without
  # materializing (streaming fast path).

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
  alias ImagePipe.Transform.Chain
  alias ImagePipe.Transform.Focus
  alias ImagePipe.Transform.Lowering
  alias ImagePipe.Transform.Materializer
  alias ImagePipe.Transform.Operation.Crop
  alias ImagePipe.Transform.Operation.Resize
  alias ImagePipe.Transform.Orientation
  alias ImagePipe.Transform.PendingOrientation
  alias ImagePipe.Transform.ResizePlanning
  alias ImagePipe.Transform.State
  alias Vix.Vips.Image, as: VipsImage

  @spec flush_if_pending(State.t()) :: {:ok, State.t()} | {:error, term()}
  def flush_if_pending(%State{pending_orientation: nil} = state), do: {:ok, state}

  # An identity pending orientation has no pixel work: clear it without forcing a
  # materialize so the streaming (no-rotation) fast path is preserved — the delivery
  # backstop still materializes if nothing else did.
  def flush_if_pending(%State{pending_orientation: %PendingOrientation{} = po} = state) do
    if PendingOrientation.identity?(po) do
      {:ok, %State{state | pending_orientation: nil}}
    else
      case Materializer.materialize(state) do
        {:ok, %State{} = state} -> {:ok, state}
        {:error, reason} -> {:error, {:materialize_error, reason}}
      end
    end
  end

  @spec execute_operation(struct(), State.t(), map(), keyword()) ::
          {:ok, State.t()} | {:error, term()}
  # Right-angle, non-mirrored rotation defers into pending_orientation (lossless
  # vips_rot at the flush, imgproxy parity, #211 seam avoidance). Same body as before.
  def execute_operation(%PlanRotate{angle: angle, mirror: false}, %State{} = state, _ctx, _opts)
      when angle in [0, 90, 180, 270] do
    po = state.pending_orientation || %PendingOrientation{}
    {:ok, %State{state | pending_orientation: PendingOrientation.fold_rotate(po, angle)}}
  end

  # Arbitrary angle or mirror: run as a materializing chain op. Chain's pre-op
  # materialize flushes any pending EXIF orientation first, so the rotation lands
  # in the display frame (EXIF auto-orient -> then user rotation).
  def execute_operation(%PlanRotate{} = operation, %State{} = state, ctx, opts) do
    run_executable(operation, state, ctx, opts)
  end

  def execute_operation(%PlanFlip{axis: axis}, %State{} = state, _ctx, _opts) do
    po = state.pending_orientation || %PendingOrientation{}
    {:ok, %State{state | pending_orientation: PendingOrientation.fold_flip(po, axis)}}
  end

  # Positional focus: resolve the operand against the live frame at this chain
  # position and store the carried point. No pixel work, no flush — a following
  # cover resize still sizes against the (possibly shrunk) source frame. The user
  # authors focus in the display frame; Focus.resolve maps it into the live
  # storage frame when an orientation is pending.
  def execute_operation(%SetFocus{point: operand}, %State{} = state, _ctx, _opts) do
    ctx = %{
      display: ResizePlanning.display_live_dims(state),
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
  def execute_operation(%CropRegion{} = operation, %State{} = state, ctx, opts) do
    with {:ok, %State{} = state} <- do_execute_crop(operation, state, ctx, opts) do
      {:ok, clear_source_frame(state)}
    end
  end

  def execute_operation(%CropGuided{} = operation, %State{} = state, ctx, opts) do
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
  def execute_operation(
        %PlanResize{} = operation,
        %State{pending_orientation: po} = state,
        ctx,
        opts
      )
      when not is_nil(po) do
    cond do
      PendingOrientation.identity?(po) ->
        run_executable(operation, state, ctx, opts)

      PendingOrientation.quarter_turn?(po) and ResizePlanning.cover_resize?(operation, state) ->
        # The display-frame resolver already emits a storage-frame (forcing)
        # resize and a display-frame result-crop; only the crop needs the gravity/
        # offset remap and dim swap (compensate_crop), not the resize.
        executable =
          operation
          |> ResizePlanning.cover_resize_and_crop_display_frame(
            state,
            Lowering.tagged_executable_gravity(operation.guide)
          )
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
          |> Lowering.executable_operations(state, ctx)
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
  def execute_operation(
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

  def execute_operation(
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

  def execute_operation(
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
  def execute_operation(
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

  defp run_executable(operation, %State{} = state, context, opts) do
    operation
    |> Lowering.executable_operations(state, context)
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
          |> Lowering.executable_operations(%State{state | decode_shrink: oriented_shrink}, ctx)
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
end
