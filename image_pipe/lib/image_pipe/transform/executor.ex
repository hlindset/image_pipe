defmodule ImagePipe.Transform.Executor do
  # Executes canonical request intent over a decoded transform state.
  #
  # The executor owns the fixed per-group stage order and resolves geometry from
  # the current image plus the decode state. Right-angle orientation remains
  # deferred until a stage needs display-frame pixels or the request boundary.
  @moduledoc false

  import ImagePipe.Transform.Geometry, only: [round_ties_to_even: 1]

  alias ImagePipe.Plan.Color
  alias ImagePipe.Plan.Spec
  alias ImagePipe.Plan.Spec.Group
  alias ImagePipe.Plan.Spec.Output
  alias ImagePipe.Transform
  alias ImagePipe.Transform.Alpha
  alias ImagePipe.Transform.DecodePlanner
  alias ImagePipe.Transform.Executor.Geometry
  alias ImagePipe.Transform.GrayFrame
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
  alias ImagePipe.Transform.Operation.ProgressiveBlur
  alias ImagePipe.Transform.Operation.Resize
  alias ImagePipe.Transform.Operation.Rotate
  alias ImagePipe.Transform.Operation.Saturation
  alias ImagePipe.Transform.Operation.Sharpen
  alias ImagePipe.Transform.Operation.Trim
  alias ImagePipe.Transform.Operation.Watermark
  alias ImagePipe.Transform.Orientation
  alias ImagePipe.Transform.PendingOrientation
  alias ImagePipe.Transform.SourceGeometry
  alias ImagePipe.Transform.State
  alias ImagePipe.Transform.WorkingColor
  alias ImagePipe.Transform.WorkLimits
  alias Vix.Vips.Image, as: VipsImage
  alias Vix.Vips.Operation, as: VipsOperation

  @default_trim_threshold 10.0
  @placeholder_terminal_reduction {32, 32}
  @working_spaces [
    :VIPS_INTERPRETATION_sRGB,
    :VIPS_INTERPRETATION_RGB,
    :VIPS_INTERPRETATION_B_W,
    :VIPS_INTERPRETATION_RGB16,
    :VIPS_INTERPRETATION_GREY16
  ]

  @spec decode_request(Spec.t(), SourceGeometry.t()) :: DecodePlanner.Request.t()
  def decode_request(
        %Spec{groups: [%Group{} = group | _]} = request,
        %SourceGeometry{} = geometry
      ) do
    {crop_frame, headroom} = decode_frame(group.rotate, geometry.display_dimensions)
    crop_extent = decode_crop_extent(group, crop_frame)
    resize_frame = crop_extent || crop_frame

    %DecodePlanner.Request{
      resize_target:
        scale_target(decode_resize_target(group.resize, group.dpr, resize_frame), headroom),
      crop_extent: crop_extent || rotated_extent(headroom, crop_frame),
      user_quarter_turn?: group.rotate in [90, 270],
      trim?: group.trim != nil,
      terminal_reduction: scale_target(decode_terminal_reduction(request, resize_frame), headroom)
    }
  end

  # The frame the group's crop and resize see after its rotate, and how much
  # larger than the target to decode. An arbitrary-angle rotate sees the rotated
  # bounding box. Rotation and uniform scaling commute, so the decode can shrink
  # before it, but the rotate then resamples near the output size: decoding at
  # twice the target keeps its interpolation from showing.
  defp decode_frame(angle, {width, height}) when angle in [90, 270], do: {{height, width}, 1}
  defp decode_frame(angle, dims) when angle in [nil, 180], do: {dims, 1}

  defp decode_frame(angle, {width, height}) do
    radians = angle * :math.pi() / 180
    cos = abs(:math.cos(radians))
    sin = abs(:math.sin(radians))
    {{round(width * cos + height * sin), round(width * sin + height * cos)}, 2}
  end

  # Without a crop the planner sizes against the source; a rotate's bounding
  # box replaces it.
  defp rotated_extent(1, _frame), do: nil
  defp rotated_extent(_headroom, frame), do: frame

  defp scale_target(nil, _headroom), do: nil
  defp scale_target(target, 1), do: target

  defp scale_target({width, height}, headroom),
    do: {scale_axis(width, headroom), scale_axis(height, headroom)}

  defp scale_axis(nil, _headroom), do: nil
  defp scale_axis(value, headroom), do: value * headroom

  @spec execute(State.t(), Spec.t(), keyword()) ::
          {:ok, State.t()} | {:error, {:transform, term()} | {:decode, term()}}
  def execute(%State{} = state, %Spec{} = request, opts) do
    state = %State{
      state
      | detector: Transform.resolve_detector(Keyword.get(opts, :detector, :default)),
        detector_required: Keyword.get(opts, :detector_required, false),
        max_intermediate_pixels:
          Keyword.get(opts, :max_intermediate_pixels, state.max_intermediate_pixels)
    }

    with {:ok, state} <- condition_color(state, opts),
         {:ok, state} <- execute_groups(state, request.groups, opts),
         {:ok, state} <- flush_display(state) do
      normalize_output_orientation(state, request.output, opts)
    end
  end

  @doc """
  Buffers the current frame so it can be read more than once, as when several
  placeholders reduce the same executed state.
  """
  @spec materialize(State.t()) ::
          {:ok, State.t()} | {:error, {:decode | :transform, term()}}
  def materialize(%State{} = state) do
    case Materializer.materialize(state) do
      {:ok, state} -> {:ok, state}
      {:error, reason} -> {:error, Materializer.error(reason)}
    end
  end

  @doc false
  def check_evaluation(%State{} = state) do
    case WorkLimits.check(state) do
      :ok -> :ok
      {:error, reason} -> {:error, {:transform, reason}}
    end
  end

  @spec reduce_terminal(State.t(), Output.t(), keyword()) ::
          {:ok, State.t()} | {:error, {:transform, term()} | {:decode, term()}}
  def reduce_terminal(%State{} = state, %Output{terminal: terminal}, _opts)
      when terminal in [:image, :info],
      do: {:ok, state}

  def reduce_terminal(%State{} = state, %Output{terminal: :blurhash}, opts) do
    {width, height} = @placeholder_terminal_reduction

    {_mode, target} =
      Geometry.resize_target(
        %{
          fit: :contain,
          w: width,
          h: height,
          min_w: nil,
          min_h: nil,
          zoom: {1.0, 1.0},
          enlarge: true
        },
        1.0,
        Geometry.display_effective_dims(state)
      )

    # The encoder converts the tiny frame's color and drops its profile, so
    # buffer it as LQIP CSS does.
    with {:ok, state} <-
           Transform.run(state, %Resize{width: target.width, height: target.height}, opts) do
      case Materializer.materialize(state) do
        {:ok, state} -> {:ok, state}
        {:error, reason} -> {:error, Materializer.error(reason)}
      end
    end
  end

  def reduce_terminal(%State{} = state, %Output{terminal: :lqip_css}, opts) do
    with {:ok, state} <- Transform.run(state, %Resize{width: 3, height: 3}, opts) do
      # The encoder samples pixels separately, so buffer only its tiny working frame.
      case Materializer.materialize(state) do
        {:ok, state} -> {:ok, state}
        {:error, reason} -> {:error, Materializer.error(reason)}
      end
    end
  end

  @doc "The fixed-order operation names represented by a request."
  @spec operation_names(Spec.t()) :: [atom()]
  def operation_names(%Spec{groups: groups}),
    do: Enum.flat_map(groups, &group_operation_names/1)

  defp execute_groups(state, groups, opts) do
    Enum.reduce_while(groups, {:ok, state}, fn group, {:ok, state} ->
      case execute_group(state, group, opts) do
        {:ok, state} -> {:cont, {:ok, state}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  defp execute_group(state, %Group{} = group, opts) do
    with {:ok, state} <- execute_rotate(state, group.rotate, opts),
         {:ok, state} <- execute_flip(state, group.flip),
         {:ok, state} <- execute_trim(state, group, opts),
         {:ok, state} <- execute_crop(state, group, opts),
         {:ok, state, dpr} <- execute_resize(state, group, opts),
         state = %{state | dpr: dpr},
         {:ok, state} <- run_optional(state, blur_op(group.blur), opts),
         {:ok, state} <-
           run_display_optional(state, progressive_blur_op(group.progressive_blur), opts),
         {:ok, state} <- run_optional(state, sharpen_op(group.sharpen), opts),
         {:ok, state} <- run_display_optional(state, pixelate_op(group.pixelate), opts),
         {:ok, state} <- run_profile_optional(state, if(group.gray, do: %Gray{}), opts),
         {:ok, state} <- run_profile_optional(state, if(group.bitonal, do: %Bitonal{}), opts),
         {:ok, state} <- run_color_optional(state, monochrome_op(group.monochrome), opts),
         {:ok, state} <- run_color_optional(state, duotone_op(group.duotone), opts),
         {:ok, state} <- run_optional(state, brightness_op(group.brightness), opts),
         {:ok, state} <- run_optional(state, contrast_op(group.contrast), opts),
         {:ok, state} <- run_optional(state, saturation_op(group.saturation), opts),
         {:ok, state} <- run_color_optional(state, colorize_op(group.colorize), opts),
         {:ok, state} <- run_display_color_optional(state, gradient_op(group.gradient), opts),
         {:ok, state} <- execute_canvas(state, group, dpr, opts),
         {:ok, state} <- execute_padding(state, group.pad, dpr, opts),
         {:ok, state} <- run_color_optional(state, background_op(group.bg), opts) do
      execute_watermark(state, group.watermark, dpr, opts)
    end
  end

  defp execute_rotate(state, nil, _opts), do: {:ok, state}

  defp execute_rotate(%State{} = state, angle, _opts) when angle in [0, 90, 180, 270] do
    pending = state.pending_orientation || %PendingOrientation{}
    {:ok, %State{state | pending_orientation: PendingOrientation.fold_rotate(pending, angle)}}
  end

  defp execute_rotate(%State{} = state, angle, opts) do
    with {:ok, state} <- flush_display(state),
         frame = state.source_dimensions,
         {:ok, state} <- Transform.run(state, %Rotate{angle: angle}, opts) do
      {:ok, rotated_source_frame(state, frame, angle)}
    end
  end

  # After a shrunk decode, later crops still resolve in full-resolution units.
  # The frame becomes the bounding box of the rotated full-resolution frame,
  # computed as libvips does. Scaling the shrunk image's box back up would
  # multiply its rounding by the shrink, so sizes would depend on whether the
  # format shrinks on load.
  defp rotated_source_frame(%State{decode_shrink: nil} = state, _frame, _angle),
    do: Geometry.clear_source_frame(state)

  defp rotated_source_frame(%State{} = state, frame, angle) do
    {{width, height}, _headroom} = decode_frame(angle, frame)
    {live_width, live_height} = Geometry.live_dims(state)

    %State{
      state
      | source_dimensions: {width, height},
        decode_shrink: %{w: width / live_width, h: height / live_height}
    }
  end

  defp execute_flip(state, nil), do: {:ok, state}

  defp execute_flip(%State{} = state, axis) do
    pending = state.pending_orientation || %PendingOrientation{}
    {:ok, %State{state | pending_orientation: PendingOrientation.fold_flip(pending, axis)}}
  end

  defp execute_trim(state, %Group{trim: nil}, _opts), do: {:ok, state}

  defp execute_trim(state, %Group{} = group, opts) do
    with {:ok, state} <- flush_display(state),
         {:ok, state} <- Transform.run(state, trim_op(group.trim, group.trim_symmetry), opts) do
      {:ok, Geometry.clear_source_frame(state)}
    end
  end

  defp execute_crop(state, %Group{region: nil, crop: nil}, _opts), do: {:ok, state}

  defp execute_crop(%State{} = state, %Group{region: region}, opts) when region != nil do
    display_dims = Geometry.display_effective_dims(state)
    crop = region_crop(region, display_dims)

    {state, crop} =
      case Geometry.pending_class(state) do
        :pending ->
          pending = state.pending_orientation

          crop =
            Geometry.rescale_crop(
              crop,
              Geometry.orient_decode_shrink(state.decode_shrink, pending)
            )

          {{:flush, state}, crop}

        _none_or_identity ->
          {state, Geometry.rescale_crop(crop, state.decode_shrink)}
      end

    with {:ok, state} <- maybe_flush_tagged(state),
         {:ok, state} <- Transform.run(state, crop, opts) do
      {:ok, Geometry.clear_source_frame(state)}
    end
  end

  defp execute_crop(%State{} = state, %Group{} = group, opts) do
    crop = guided_crop(group, Geometry.display_effective_dims(state))
    materializing? = Crop.requires_materialization?(crop)

    case {Geometry.pending_class(state), materializing?} do
      {:pending, true} ->
        pending = state.pending_orientation

        crop =
          Geometry.rescale_crop(
            crop,
            Geometry.orient_decode_shrink(state.decode_shrink, pending)
          )

        with {:ok, state} <- flush_display(state),
             {:ok, state} <- Transform.run(state, crop, opts) do
          {:ok, Geometry.clear_source_frame(state)}
        end

      {:pending, false} ->
        pending = state.pending_orientation

        crop =
          crop
          |> Geometry.rescale_crop(Geometry.orient_decode_shrink(state.decode_shrink, pending))
          |> Geometry.compensate_crop(pending)

        with {:ok, state} <- Transform.run(state, crop, opts) do
          {:ok, Geometry.clear_source_frame(state)}
        end

      {:identity, true} ->
        state = %State{state | pending_orientation: nil}

        with {:ok, state} <-
               Transform.run(state, Geometry.rescale_crop(crop, state.decode_shrink), opts) do
          {:ok, Geometry.clear_source_frame(state)}
        end

      {:none, true} ->
        with {:ok, state} <-
               Transform.run(state, Geometry.rescale_crop(crop, state.decode_shrink), opts) do
          {:ok, Geometry.clear_source_frame(state)}
        end

      {_none_or_identity, false} ->
        with {:ok, state} <-
               Transform.run(state, Geometry.rescale_crop(crop, state.decode_shrink), opts) do
          {:ok, Geometry.clear_source_frame(state)}
        end
    end
  end

  defp maybe_flush_tagged({:flush, state}), do: flush_display(state)
  defp maybe_flush_tagged(%State{} = state), do: {:ok, state}

  defp execute_resize(state, %Group{resize: nil, dpr: dpr}, _opts), do: {:ok, state, dpr}

  defp execute_resize(%State{} = state, %Group{} = group, opts) do
    {mode, target} =
      Geometry.resize_target(group.resize, group.dpr, Geometry.display_effective_dims(state))

    {width, height} =
      Geometry.resize_dimensions(mode, target, Geometry.display_effective_dims(state))

    resize = %Resize{width: width, height: height}
    tail = resize_tail(mode, target, group.guide, group.anchor_offset)

    case Geometry.pending_class(state) do
      :pending ->
        pending = state.pending_orientation

        {resize, tail} =
          compensate_resize(resize, tail, pending)

        with {:ok, state} <- Transform.run(state, resize, opts),
             {:ok, state} <- run_pending_tail(state, tail, opts),
             {:ok, state} <- flush_display(state) do
          {:ok, state, target.dpr}
        end

      _none_or_identity ->
        with {:ok, state} <- Transform.run(state, resize, opts),
             {:ok, state} <- run_optional(state, tail, opts) do
          {:ok, state, target.dpr}
        end
    end
  end

  defp resize_tail(mode, target, guide, offset)
       when mode in [:cover, :auto_cover] do
    {x_offset, y_offset} = resize_offsets(offset, target.dpr)

    %Crop{
      width: {:pixels, target.width},
      height: {:pixels, target.height},
      crop_from: :gravity,
      gravity: guide_gravity(guide),
      x_offset: x_offset,
      y_offset: y_offset
    }
  end

  defp resize_tail(_mode, _target, _guide, _offset), do: nil

  defp compensate_resize(resize, tail, pending) do
    resize =
      case PendingOrientation.quarter_turn?(pending) do
        true -> Orientation.swap_resize(resize)
        false -> resize
      end

    tail = if tail, do: Geometry.compensate_crop(tail, pending), else: nil
    {resize, tail}
  end

  # `Geometry.compensate_crop/2` leaves a materializing result crop (smart or
  # detected) in display coordinates, so it runs after the orientation flush.
  defp run_pending_tail(state, %Crop{} = tail, opts) do
    case Crop.requires_materialization?(tail) do
      true -> run_display_optional(state, tail, opts)
      false -> Transform.run(state, tail, opts)
    end
  end

  defp run_pending_tail(state, nil, _opts), do: {:ok, state}

  defp run_display_optional(state, nil, _opts), do: {:ok, state}

  defp run_display_optional(state, operation, opts) do
    with {:ok, state} <- flush_display(state),
         do: Transform.run(state, operation, opts)
  end

  defp execute_canvas(state, %Group{canvas: nil}, _dpr, _opts), do: {:ok, state}

  defp execute_canvas(state, %Group{canvas: canvas, resize: resize}, dpr, opts) do
    with {:ok, state} <- flush_display(state) do
      {width, height} = Geometry.live_dims(state)
      rule = canvas_rule(canvas.mode, resize, dpr)

      {:ok, {canvas_width, canvas_height}} =
        ExtendCanvas.resolved_canvas_dims(rule, width, height)

      {x, y} = canvas.offset
      {anchor_x, anchor_y} = anchor_pair(canvas.at)

      operation = %ExtendCanvas{
        rule: rule,
        gravity: {:anchor, anchor_x, anchor_y},
        x_offset: canvas_offset(x, canvas_width, dpr),
        y_offset: canvas_offset(y, canvas_height, dpr)
      }

      with {:ok, state} <- Transform.run(state, operation, opts) do
        {:ok, Geometry.clear_source_frame(state)}
      end
    end
  end

  defp execute_padding(state, nil, _dpr, _opts), do: {:ok, state}
  defp execute_padding(state, {0, 0, 0, 0}, _dpr, _opts), do: {:ok, state}

  defp execute_padding(state, {top, right, bottom, left}, dpr, opts) do
    operation = %Padding{
      top: round_ties_to_even(top * dpr),
      right: round_ties_to_even(right * dpr),
      bottom: round_ties_to_even(bottom * dpr),
      left: round_ties_to_even(left * dpr)
    }

    with {:ok, state} <- flush_display(state),
         {:ok, state} <- Transform.run(state, operation, opts) do
      {:ok, Geometry.clear_source_frame(state)}
    end
  end

  defp execute_watermark(state, nil, _dpr, _opts), do: {:ok, state}

  defp execute_watermark(state, watermark, dpr, opts) do
    %{image: asset, opacity: base_opacity} =
      opts |> Keyword.fetch!(:watermarks) |> Map.fetch!(watermark.asset)

    with {:ok, state} <- flush_display(state),
         {:ok, asset} <- conditioned_asset(asset, state, opts),
         {frame_width, frame_height} = Geometry.live_dims(state),
         {width, height} =
           watermark_size(watermark.scale, asset, {frame_width, frame_height}, dpr),
         {:ok, asset} <- sized_asset(asset, width, height, state),
         {:ok, state} <- promote_gray_frame(state, asset),
         {:ok, asset} <- into_frame_profile(asset, state),
         {:ok, asset} <- watermark_asset(asset, state) do
      {x, y} = watermark.offset
      {gap_x, gap_y} = watermark.gap
      {anchor_x, anchor_y} = anchor_pair(watermark.at)

      operation = %Watermark{
        image: asset,
        width: width,
        height: height,
        opacity: watermark.opacity * base_opacity,
        gravity: {:anchor, anchor_x, anchor_y},
        x_offset: placement_length(x, frame_width, dpr),
        y_offset: placement_length(y, frame_height, dpr),
        tile: watermark.tile,
        gap:
          {placement_length(gap_x, frame_width, dpr), placement_length(gap_y, frame_height, dpr)}
      }

      Transform.run(state, operation, opts)
    end
  end

  # The asset is resized to its drawn size before color management, which
  # then converts only the pixels that are drawn.
  defp sized_asset(asset, width, height, %State{} = state) do
    asset_state = %State{image: asset, max_intermediate_pixels: state.max_intermediate_pixels}

    case WorkLimits.resize(asset_state, width, height) do
      :ok -> resize_asset(asset, width, height)
      {:error, reason} -> {:error, {:transform, reason}}
    end
  end

  defp resize_asset(asset, width, height) do
    case Watermark.resize(asset, width, height) do
      {:ok, sized} -> {:ok, sized}
      {:error, reason} -> {:error, {:transform, {Watermark, reason}}}
    end
  end

  # Assets get the source's input conditioning, then the frame's color space,
  # an alpha band, and the frame's band format.
  defp conditioned_asset(asset, %State{} = state, opts) do
    asset_state = %State{
      image: asset,
      telemetry_opts: state.telemetry_opts,
      max_intermediate_pixels: state.max_intermediate_pixels
    }

    with {:ok, asset_state} <- materialize_profiled_asset(asset_state, state.image),
         {:ok, %State{image: asset}} <- condition_color(asset_state, opts),
         do: {:ok, asset}
  end

  # Workaround for `image`: removing or setting an ICC profile goes through
  # Vix's mutable image, which copies the image to memory in a linked process.
  # A corrupt asset then crashes the request instead of failing as a decode
  # error, so buffer the asset first when color management changes a profile:
  # the asset has one, or a color frame does.
  defp materialize_profiled_asset(%State{image: asset} = asset_state, frame) do
    if WorkingColor.tagged?(asset) or (not GrayFrame.gray?(frame) and WorkingColor.tagged?(frame)) do
      case Materializer.materialize(asset_state) do
        {:ok, asset_state} -> {:ok, asset_state}
        {:error, reason} -> {:error, Materializer.error(reason)}
      end
    else
      {:ok, asset_state}
    end
  end

  # A color asset promotes a gray frame to RGB rather than being reduced to gray.
  # A tagged frame converts through its profile, which also clears the backup.
  defp promote_gray_frame(%State{image: frame} = state, asset) do
    if GrayFrame.gray?(frame) and not GrayFrame.gray?(asset) do
      with {:ok, state} <- materialize_tagged_frame(state), do: promote_frame(state)
    else
      {:ok, state}
    end
  end

  defp promote_frame(state) do
    with {:ok, %State{} = state} <- WorkingColor.to_srgb_frame(state),
         {:ok, frame} <- GrayFrame.promote(state.image) do
      {:ok, %State{state | image: frame}}
    else
      {:error, reason} -> {:error, {:transform, {Watermark, reason}}}
    end
  end

  # A color frame takes the asset through color management: an untagged asset
  # is sRGB, and both land in the frame's profile, or sRGB without one.
  defp into_frame_profile(asset, %State{image: frame}) do
    if GrayFrame.gray?(frame) do
      {:ok, asset}
    else
      with {:ok, asset} <- GrayFrame.promote(asset),
           {:ok, asset} <- WorkingColor.into_space_of(asset, frame) do
        {:ok, asset}
      else
        {:error, reason} -> {:error, {:transform, {Watermark, reason}}}
      end
    end
  end

  defp watermark_asset(asset, %State{image: frame}) do
    with {:ok, asset} <- to_frame_space(asset, VipsImage.interpretation(frame)),
         {:ok, asset} <- with_alpha(asset) do
      case VipsOperation.cast(asset, VipsImage.format(frame)) do
        {:ok, asset} -> {:ok, asset}
        {:error, reason} -> {:error, {:transform, {Watermark, reason}}}
      end
    end
  end

  defp to_frame_space(asset, interpretation) when interpretation in @working_spaces do
    case VipsImage.interpretation(asset) do
      ^interpretation ->
        {:ok, asset}

      _other ->
        case WorkingColor.to_space(asset, interpretation) do
          {:ok, asset} -> {:ok, asset}
          {:error, reason} -> {:error, {:transform, {Watermark, reason}}}
        end
    end
  end

  defp to_frame_space(asset, _interpretation), do: {:ok, asset}

  defp with_alpha(asset) do
    case Alpha.ensure(asset) do
      {:ok, asset} -> {:ok, asset}
      {:error, reason} -> {:error, {:transform, {Watermark, reason}}}
    end
  end

  # A scale fits the asset in that fraction of the frame; otherwise it keeps
  # its natural size at the group's effective DPR.
  defp watermark_size(nil, asset, _frame, dpr),
    do: scaled_dims(asset, dpr)

  defp watermark_size(scale, asset, {frame_width, frame_height}, _dpr) do
    factor =
      min(
        frame_width * scale / Image.width(asset),
        frame_height * scale / Image.height(asset)
      )

    scaled_dims(asset, factor)
  end

  defp scaled_dims(asset, factor) do
    {max(1, round_ties_to_even(Image.width(asset) * factor)),
     max(1, round_ties_to_even(Image.height(asset) * factor))}
  end

  defp placement_length({:px, value}, _dimension, dpr), do: round_ties_to_even(value * dpr)

  defp placement_length({:pct, value}, dimension, _dpr),
    do: round_ties_to_even(dimension * value / 100)

  defp flush_display(%State{} = state) do
    case Geometry.pending_class(state) do
      :none ->
        {:ok, state}

      :identity ->
        {:ok, %State{state | pending_orientation: nil}}

      :pending ->
        pending = state.pending_orientation

        case Materializer.flush(state) do
          {:ok, state} -> {:ok, orient_source_frame(state, pending)}
          {:error, reason} -> {:error, Materializer.error(reason)}
        end
    end
  end

  defp orient_source_frame(%State{} = state, %PendingOrientation{} = pending) do
    if PendingOrientation.quarter_turn?(pending) do
      source_dimensions =
        case state.source_dimensions do
          {width, height} -> {height, width}
          nil -> nil
        end

      decode_shrink =
        case state.decode_shrink do
          %{w: width, h: height} = shrink -> %{shrink | w: height, h: width}
          nil -> nil
        end

      %State{state | source_dimensions: source_dimensions, decode_shrink: decode_shrink}
    else
      state
    end
  end

  defp run_optional(state, nil, _opts), do: {:ok, state}
  defp run_optional(state, operation, opts), do: Transform.run(state, operation, opts)

  # Gray and bitonal convert a tagged frame through its profile and remove it.
  defp run_profile_optional(state, nil, _opts), do: {:ok, state}

  defp run_profile_optional(state, operation, opts) do
    with {:ok, state} <- materialize_tagged_frame(state),
         do: Transform.run(state, operation, opts)
  end

  # A color effect converts a tagged gray frame to RGB through its profile.
  defp run_color_optional(state, nil, _opts), do: {:ok, state}

  defp run_color_optional(%State{image: image} = state, operation, opts) do
    with {:ok, state} <-
           if(GrayFrame.gray?(image), do: materialize_tagged_frame(state), else: {:ok, state}),
         do: Transform.run(state, operation, opts)
  end

  defp run_display_color_optional(state, nil, _opts), do: {:ok, state}

  defp run_display_color_optional(state, operation, opts) do
    with {:ok, state} <- flush_display(state), do: run_color_optional(state, operation, opts)
  end

  # Workaround for `image`: removing a frame's profile goes through Vix's
  # mutable image, which copies the frame to memory in a linked process, so a
  # corrupt lazy source crashes the request there. Buffer a tagged frame first,
  # so the failure is a decode error.
  defp materialize_tagged_frame(%State{image: image} = state) do
    case WorkingColor.tagged?(image) do
      true -> materialize_for_metadata(state)
      false -> {:ok, state}
    end
  end

  defp region_crop({x, y, width, height}, {display_width, display_height}) do
    left = round(resolve_length(x, display_width))
    top = round(resolve_length(y, display_height))

    %Crop{
      width: {:pixels, round(resolve_length(width, display_width))},
      height: {:pixels, round(resolve_length(height, display_height))},
      crop_from: %{
        left: {:pixels, left},
        top: {:pixels, top}
      },
      reject_out_of_bounds: left >= display_width or top >= display_height
    }
  end

  defp guided_crop(%Group{crop: {width, height}} = group, {display_width, display_height}) do
    requested = %Crop{
      width: {:pixels, round(resolve_length(width, display_width))},
      height: {:pixels, round(resolve_length(height, display_height))},
      crop_from: :gravity,
      aspect_ratio: group.crop_ratio,
      enlarge: group.crop_ratio_enlarge
    }

    {crop_width, crop_height} =
      Crop.resolved_box_dims(requested, display_width, display_height)

    {x_offset, y_offset} = crop_offsets(group.anchor_offset)

    %Crop{
      width: {:pixels, crop_width},
      height: {:pixels, crop_height},
      crop_from: :gravity,
      gravity: guide_gravity(group.guide),
      x_offset: x_offset,
      y_offset: y_offset
    }
  end

  # Source crops run before resize, in physical source pixels like the crop
  # size itself, so DPR doesn't move them.
  defp crop_offsets(nil), do: {{:pixels, 0.0}, {:pixels, 0.0}}
  defp crop_offsets({x, y}), do: {scaled_offset(x, 1.0), scaled_offset(y, 1.0)}

  defp resize_offsets(nil, _dpr), do: {{:pixels, 0.0}, {:pixels, 0.0}}
  defp resize_offsets({x, y}, dpr), do: {scaled_offset(x, dpr), scaled_offset(y, dpr)}

  defp scaled_offset({:px, value}, dpr), do: {:pixels, value * dpr}
  defp scaled_offset({:pct, value}, _dpr), do: {:scale, value / 100}

  defp guide_gravity(nil), do: {:anchor, :center, :center}

  defp guide_gravity({:anchor, name}) do
    {x, y} = anchor_pair(name)
    {:anchor, x, y}
  end

  defp guide_gravity({:anchor_smart}), do: :smart
  defp guide_gravity({:smart, :face_assist} = guide), do: guide
  defp guide_gravity({:detect, {_classes, _weights}} = guide), do: guide
  defp guide_gravity({:focus, x, y}), do: {:fp, x, y}

  defp trim_op(:auto, symmetry), do: build_trim(@default_trim_threshold, :auto, symmetry)

  defp trim_op({{red, green, blue}, tolerance}, symmetry) do
    {:ok, color} = Color.rgb(red, green, blue)
    build_trim(tolerance * 1.0, color, symmetry)
  end

  defp build_trim(threshold, background, symmetry) do
    %Trim{
      threshold: threshold,
      background: background,
      equal_hor: symmetry in [:horizontal, :both],
      equal_ver: symmetry in [:vertical, :both]
    }
  end

  defp blur_op(nil), do: nil
  defp blur_op(sigma), do: %Blur{sigma: sigma}

  defp progressive_blur_op(nil), do: nil
  defp progressive_blur_op(effect), do: struct!(ProgressiveBlur, effect)
  defp sharpen_op(nil), do: nil
  defp sharpen_op(sigma), do: %Sharpen{sigma: sigma}
  defp pixelate_op(nil), do: nil
  defp pixelate_op(size), do: %Pixelate{size: size}
  defp monochrome_op(nil), do: nil

  defp monochrome_op(%{intensity: intensity, color: color}),
    do: %Monochrome{intensity: intensity, color: Tuple.to_list(color)}

  defp duotone_op(nil), do: nil

  defp duotone_op(%{intensity: intensity, shadow: shadow, highlight: highlight}) do
    %Duotone{
      intensity: intensity,
      shadow: Tuple.to_list(shadow),
      highlight: Tuple.to_list(highlight)
    }
  end

  defp brightness_op(nil), do: nil
  defp brightness_op(value), do: %Brightness{value: value}
  defp contrast_op(nil), do: nil
  defp contrast_op(value), do: %Contrast{value: value}
  defp saturation_op(nil), do: nil
  defp saturation_op(value), do: %Saturation{value: value}
  defp colorize_op(nil), do: nil

  defp colorize_op(%{opacity: opacity, color: color, keep_alpha: keep_alpha}),
    do: %Colorize{opacity: opacity, color: Tuple.to_list(color), keep_alpha: keep_alpha}

  defp gradient_op(nil), do: nil

  defp gradient_op(%{opacity: opacity, color: color, angle: angle, start: start, stop: stop}) do
    %Gradient{
      opacity: opacity,
      color: Tuple.to_list(color),
      angle: angle,
      start: start,
      stop: stop
    }
  end

  defp background_op(nil), do: nil

  defp background_op({red, green, blue, alpha}),
    do: %Background{color: [red, green, blue, round(alpha * 255)]}

  defp canvas_rule(:box, %{w: width, h: height}, dpr),
    do: {:dimensions, width * dpr, height * dpr}

  defp canvas_rule(:ratio, %{w: width, h: height}, _dpr),
    do: {:aspect_ratio, {width, height}}

  defp canvas_offset({:px, value}, _dimension, dpr), do: value * dpr
  defp canvas_offset({:pct, value}, dimension, _dpr), do: dimension * value / 100

  defp resolve_length({:px, value}, _dimension), do: value
  defp resolve_length({:pct, value}, dimension), do: dimension * value / 100

  defp anchor_pair(:center), do: {:center, :center}
  defp anchor_pair(:top), do: {:center, :top}
  defp anchor_pair(:bottom), do: {:center, :bottom}
  defp anchor_pair(:left), do: {:left, :center}
  defp anchor_pair(:right), do: {:right, :center}
  defp anchor_pair(:top_left), do: {:left, :top}
  defp anchor_pair(:top_right), do: {:right, :top}
  defp anchor_pair(:bottom_left), do: {:left, :bottom}
  defp anchor_pair(:bottom_right), do: {:right, :bottom}

  defp decode_resize_target(nil, _dpr, _frame), do: nil

  # Stretch keeps an :auto axis at the source size, and shrink-on-load shrinks
  # both axes, so the decode can't shrink.
  defp decode_resize_target(%{fit: :stretch, w: width, h: height}, _dpr, _frame)
       when width == :auto or height == :auto,
       do: nil

  # A contained image fills the box on one axis only, so the decode is sized
  # from the image the resize produces, not from the box.
  defp decode_resize_target(%{w: width, h: height} = resize, dpr, frame)
       when is_number(width) and is_number(height) do
    case Geometry.resize_target(resize, dpr, frame) do
      {mode, target} when mode in [:contain, :auto_contain] -> {target.width, target.height}
      _cover_or_stretch -> decode_box(resize, dpr, frame)
    end
  end

  defp decode_resize_target(resize, dpr, frame), do: decode_box(resize, dpr, frame)

  # A minimum scales the whole resize up, so the decode keeps that much more.
  defp decode_box(%{w: width, h: height, zoom: {zoom_x, zoom_y}} = resize, dpr, frame) do
    scale = dpr * Geometry.minimum_scale(resize, frame)

    case {decode_axis(width, zoom_x * scale), decode_axis(height, zoom_y * scale)} do
      {nil, nil} -> nil
      target -> target
    end
  end

  defp decode_axis(:auto, _scale), do: nil
  defp decode_axis(value, scale), do: value * scale

  defp decode_crop_extent(
         %Group{region: {_x, _y, width, height}},
         {display_width, display_height}
       ) do
    {
      min(round(resolve_length(width, display_width)), display_width),
      min(round(resolve_length(height, display_height)), display_height)
    }
  end

  defp decode_crop_extent(%Group{crop: {_width, _height}} = group, display_dims) do
    crop = guided_crop(group, display_dims)
    Crop.resolved_box_dims(crop, elem(display_dims, 0), elem(display_dims, 1))
  end

  defp decode_crop_extent(%Group{}, _display_dims), do: nil

  # A placeholder needs only a tiny frame, so a single group can decode
  # smaller. Not when it has effects sized in pixels: on a smaller decode they
  # would cover a larger share of the frame. A resize target or a trim decides
  # the decode size on its own, so the reduction is left out there.
  defp decode_terminal_reduction(
         %Spec{groups: [group], output: %Output{terminal: terminal}},
         resize_frame
       )
       when terminal in [:blurhash, :lqip_css] do
    if pixel_sized_effects?(group) or group.trim != nil or
         decode_resize_target(group.resize, group.dpr, resize_frame) != nil,
       do: nil,
       else: @placeholder_terminal_reduction
  end

  defp decode_terminal_reduction(%Spec{}, _resize_frame), do: nil

  defp pixel_sized_effects?(%Group{} = group) do
    Enum.any?(
      [group.blur, group.progressive_blur, group.sharpen, group.pixelate, group.pad] ++
        [group.canvas, group.watermark],
      &(&1 != nil)
    )
  end

  defp condition_color(%State{} = state, opts) do
    case InputColorManagement.condition(state,
           supports_hdr?: Keyword.get(opts, :supports_hdr?, false)
         ) do
      {:ok, state} -> {:ok, state}
      {:error, {InputColorManagement, reason}} -> {:error, {:decode, reason}}
    end
  end

  defp normalize_output_orientation(state, %Output{terminal: :image} = output, opts) do
    if retains_source_metadata?(output, opts),
      do: remove_non_normal_orientation(state),
      else: {:ok, state}
  end

  defp normalize_output_orientation(state, %Output{}, _opts), do: {:ok, state}

  defp retains_source_metadata?(%Output{metadata: :keep}, _opts), do: true

  defp retains_source_metadata?(%Output{metadata: nil}, opts),
    do: not Keyword.get(opts, :strip_metadata, true)

  defp retains_source_metadata?(%Output{}, _opts), do: false

  defp remove_non_normal_orientation(%State{} = state) do
    case VipsImage.header_value(state.image, "orientation") do
      {:ok, 1} -> {:ok, state}
      {:ok, _orientation} -> remove_output_orientation(state)
      {:error, _reason} -> {:ok, state}
    end
  end

  defp remove_output_orientation(%State{} = state) do
    with {:ok, %State{} = state} <- materialize_for_metadata(state),
         {:ok, image} <-
           Image.remove_metadata(state.image, ["orientation"]) do
      {:ok, %State{state | image: image}}
    else
      {:error, {:decode, _reason}} = error -> error
      {:error, reason} -> {:error, {:transform, reason}}
    end
  end

  defp materialize_for_metadata(%State{materialized?: true} = state), do: {:ok, state}

  defp materialize_for_metadata(%State{} = state) do
    case Materializer.materialize(state) do
      {:ok, state} -> {:ok, state}
      {:error, reason} -> {:error, Materializer.error(reason)}
    end
  end

  defp group_operation_names(%Group{} = group) do
    for {value, name} <- [
          {group.rotate, :rotate},
          {group.flip, :flip},
          {group.trim, :trim},
          {group.region || group.crop, crop_name(group)},
          {group.resize, :resize},
          {group.blur, :blur},
          {group.progressive_blur, :progressive_blur},
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
          {padding_name(group.pad), :padding},
          {group.bg, :background},
          {group.watermark, :watermark}
        ],
        value not in [nil, false],
        do: name
  end

  defp crop_name(%Group{region: region}) when region != nil, do: :crop_region
  defp crop_name(%Group{crop: crop}) when crop != nil, do: :crop_guided
  defp crop_name(%Group{}), do: nil
  defp padding_name(nil), do: nil
  defp padding_name({0, 0, 0, 0}), do: nil
  defp padding_name({_top, _right, _bottom, _left}), do: :padding
end
