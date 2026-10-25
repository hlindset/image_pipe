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
  alias ImagePipe.Transform.Alpha
  alias ImagePipe.Transform.DecodePlanner
  alias ImagePipe.Transform.Detector
  alias ImagePipe.Transform.Executor.Geometry
  alias ImagePipe.Transform.Executor.Step
  alias ImagePipe.Transform.Geometry, as: TransformGeometry
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
  alias ImagePipe.Transform.Operation.Pixelate
  alias ImagePipe.Transform.Operation.ProgressiveBlur
  alias ImagePipe.Transform.Operation.Resize
  alias ImagePipe.Transform.Operation.Rotate
  alias ImagePipe.Transform.Operation.Saturation
  alias ImagePipe.Transform.Operation.Sharpen
  alias ImagePipe.Transform.Operation.Trim
  alias ImagePipe.Transform.Operation.Watermark
  alias ImagePipe.Transform.PendingOrientation
  alias ImagePipe.Transform.SourceGeometry
  alias ImagePipe.Transform.State
  alias ImagePipe.Transform.WorkingColor
  alias ImagePipe.Transform.WorkLimits
  alias ImagePipe.VipsHeader
  alias Vix.Vips.Image, as: VipsImage
  alias Vix.Vips.Operation, as: VipsOperation

  @default_trim_threshold 10.0
  @placeholder_terminal_reduction {32, 32}
  # The long edge of the frame a detection crop detects on: the input size of
  # the bundled detection models.
  @detection_floor 640
  @working_spaces [
    :VIPS_INTERPRETATION_sRGB,
    :VIPS_INTERPRETATION_RGB,
    :VIPS_INTERPRETATION_B_W,
    :VIPS_INTERPRETATION_RGB16,
    :VIPS_INTERPRETATION_GREY16
  ]

  @doc """
  The open options for decoding the source: sequential access, and a load
  shrink sized from the first group's geometry.

  The shrink compares the extent the first group's resize sees (its crop, or
  the frame after its rotate) with its resize target, or without a resize with
  the terminal's reduction target. A trim in the first group decodes at full
  size, since the trimmed extent isn't known yet.

  With a `:detector` available for the classes a first group detects, that
  group keeps enough pixels for the detector however small the output is: a
  detect crop keeps the decoded frame's long edge at the detection floor, and
  a cover resize's crop that can move keeps the decoded extent's. With
  `:detector_required`, a smart-face crop keeps no floor until the detector
  is ready, since it uses attention cropping until then.
  """
  @spec decode_options(Spec.t(), SourceGeometry.t(), keyword()) :: keyword()
  def decode_options(
        %Spec{groups: [%Group{} = group | _]} = request,
        %SourceGeometry{} = geometry,
        opts \\ []
      ) do
    vector? = geometry.source_format == :svg
    group = if vector?, do: vector_group(group), else: group
    {crop_frame, headroom} = decode_frame(group.rotate, geometry.display_dimensions)
    crop_extent = decode_crop_extent(group, crop_frame)
    extent = crop_extent || crop_frame
    target = decode_target(request, group, extent, headroom)
    target = if vector?, do: target || render_target(group, extent, headroom), else: target

    floor =
      if detection_runs?(
           Keyword.get(opts, :detector),
           Keyword.get(opts, :detector_required, false),
           group.guide
         ),
         do: detection_floor(group, extent, crop_frame)

    # A decoded axis can't fall under one pixel, which an arbitrary rotation's
    # bounding box doesn't bound, so the source's short side caps the shrink
    # as well as the extent's.
    {width, height} = geometry.display_dimensions
    max_shrink = Enum.min([width, height | Tuple.to_list(extent)])
    max_shrink = min(max_shrink, crop_shrink_limit(crop_extent))

    DecodePlanner.open_options(geometry.source_format, extent, target, floor, max_shrink)
  end

  # A load shrink by n averages pixels in blocks of n from the source's edge,
  # so a crop whose edges miss the blocks takes in up to n - 1 pixels from
  # outside it on each side. Capping n at an eighth of the crop's short side
  # keeps that under an eighth of the crop, and a crop a few pixels thick
  # decodes at full size.
  defp crop_shrink_limit(nil), do: :infinity
  defp crop_shrink_limit({width, height}), do: max(div(min(width, height), 8), 1)

  # The larger of the floors for the group's two detecting steps. A detect
  # crop searches the whole frame, so its floor holds on the frame's long
  # edge, scaled to the extent the planner sizes, and a crop box that covers
  # the frame can't move. A cover resize's crop searches the extent.
  defp detection_floor(%Group{} = group, extent, frame) do
    [crop_floor(group, extent, frame), cover_floor(group, extent)]
    |> Enum.reject(&is_nil/1)
    |> Enum.max(fn -> nil end)
  end

  # Detection runs when the detector can find any class the guide asks for. A
  # required detector loads no models during a request, so a smart-face crop
  # uses attention until its face model is ready. The crop checks readiness
  # again, so a request that starts as warmup finishes can detect faces on
  # the smaller frame.
  defp detection_runs?(nil, _required?, _guide), do: false

  defp detection_runs?(detector, true, {:smart, :face_assist} = guide),
    do: Detector.ready?(detector, classes: ["face"]) and finds_guide_class?(detector, guide)

  defp detection_runs?(detector, _required?, guide), do: finds_guide_class?(detector, guide)

  defp finds_guide_class?(detector, guide) do
    case guide_classes(guide, detector) do
      nil -> false
      classes -> Enum.any?(classes, &detector.available?(classes: [&1]))
    end
  end

  defp guide_classes({:detect, {:all, _weights}}, detector), do: detector.supported_classes([])
  defp guide_classes({:detect, {classes, _weights}}, _detector), do: classes
  defp guide_classes({:smart, :face_assist}, _detector), do: ["face"]
  defp guide_classes(_guide, _detector), do: nil

  defp crop_floor(%Group{crop: nil}, _extent, _frame), do: nil
  defp crop_floor(_group, extent, extent), do: nil

  defp crop_floor(_group, extent, frame),
    do: ceil(@detection_floor * long_edge(extent) / long_edge(frame))

  defp cover_floor(group, extent), do: if(cover_resize?(group, extent), do: @detection_floor)

  defp long_edge({width, height}), do: max(width, height)

  defp cover_resize?(%Group{resize: nil}, _extent), do: false

  # A cover whose resize already has the target's shape crops nothing.
  defp cover_resize?(%Group{resize: resize, dpr: dpr}, extent) do
    {mode, target} = Geometry.resize_target(resize, dpr, extent)

    mode in [:cover, :auto_cover] and
      Geometry.resize_dimensions(mode, target, extent) != {target.width, target.height}
  end

  # A vector source renders at its first group's resize even where a raster
  # decode couldn't shrink, as for a one-axis stretch or a minimum alone, so
  # that resize isn't clamped to the intrinsic size.
  defp render_target(%Group{resize: nil}, _extent, _headroom), do: nil
  defp render_target(%Group{trim: trim}, _extent, _headroom) when trim != nil, do: nil

  defp render_target(%Group{} = group, extent, headroom) do
    {mode, target} = Geometry.resize_target(group.resize, group.dpr, extent)
    scale_target(Geometry.resize_dimensions(mode, target, extent), headroom)
  end

  # A resize without target axes normalizes to nil, so the terminal's reduction
  # applies (see decode_resize_target/3).
  defp decode_target(_request, %Group{trim: trim}, _extent, _headroom) when trim != nil, do: nil

  # The JPEG and WebP load shrinks average source pixels, which a
  # nearest-neighbour resize must keep apart.
  defp decode_target(_request, %Group{resize: %{kernel: :nearest}}, _extent, _headroom),
    do: nil

  defp decode_target(request, group, extent, headroom) do
    target =
      decode_resize_target(group.resize, group.dpr, extent) ||
        decode_terminal_reduction(request, extent)

    scale_target(target, headroom)
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

  defp scale_target(nil, _headroom), do: nil
  defp scale_target(target, 1), do: target

  defp scale_target({width, height}, headroom),
    do: {scale_axis(width, headroom), scale_axis(height, headroom)}

  defp scale_axis(nil, _headroom), do: nil
  defp scale_axis(value, headroom), do: value * headroom

  @spec execute(State.t(), Spec.t(), keyword()) ::
          {:ok, State.t()}
          | {:error, {:transform, term()} | {:decode, term()} | {:input_limit, term()}}
  def execute(%State{} = state, %Spec{} = request, opts) do
    state = %State{
      state
      | detector: Keyword.get(opts, :detector),
        detector_required: Keyword.get(opts, :detector_required, false),
        max_intermediate_pixels:
          Keyword.get(opts, :max_intermediate_pixels, state.max_intermediate_pixels),
        max_blur_work: Keyword.get(opts, :max_blur_work, state.max_blur_work)
    }

    with {:ok, state} <- condition_color(state, opts),
         {:ok, state} <- execute_groups(state, groups(state, request), opts),
         {:ok, state} <- flush_display(state, false) do
      normalize_output_orientation(state, request.output, opts)
    end
  end

  defp groups(%State{vector?: true}, %Spec{groups: [first | rest]}),
    do: [vector_group(first) | rest]

  defp groups(%State{}, %Spec{groups: groups}), do: groups

  # A vector source renders at the first group's resize, so that resize can
  # enlarge past the source's intrinsic size without blurring. Later groups
  # resize the rendered raster and keep the enlargement clamp.
  defp vector_group(%Group{resize: nil} = group), do: group

  defp vector_group(%Group{resize: resize} = group),
    do: %Group{group | resize: %{resize | enlarge: true}}

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
          enlarge: true,
          kernel: :lanczos3
        },
        1.0,
        Geometry.display_effective_dims(state)
      )

    # The encoder converts the tiny frame's color and drops its profile, so
    # buffer it as LQIP CSS does.
    with {:ok, state} <-
           Step.run(state, %Resize{width: target.width, height: target.height}, opts),
         do: Materializer.materialize(state)
  end

  def reduce_terminal(%State{} = state, %Output{terminal: :lqip_css}, opts) do
    # The encoder samples pixels separately, so buffer only its tiny working frame.
    with {:ok, state} <- Step.run(state, %Resize{width: 3, height: 3}, opts),
         do: Materializer.materialize(state)
  end

  @doc """
  The kernel for scaling the request's result down to the result limits: the
  kernel of the last group that resizes, or lanczos3.
  """
  @spec result_kernel(Spec.t()) :: Group.kernel()
  def result_kernel(%Spec{groups: groups}) do
    groups
    |> Enum.reverse()
    |> Enum.find_value(:lanczos3, fn group -> group.resize && group.resize.kernel end)
  end

  @doc "The fixed-order operation names represented by a request."
  @spec operation_names(Spec.t()) :: [atom()]
  def operation_names(%Spec{groups: groups}),
    do: Enum.flat_map(groups, &group_operation_names/1)

  @doc """
  Counts the groups that rotate by an angle other than a quarter turn. A
  quarter turn folds into the deferred orientation and costs next to
  nothing.
  """
  @spec arbitrary_rotations(Spec.t()) :: non_neg_integer()
  def arbitrary_rotations(%Spec{groups: groups}),
    do: Enum.count(groups, &(&1.rotate != nil and &1.rotate not in [0, 90, 180, 270]))

  defp execute_groups(state, groups, opts) do
    last = length(groups) - 1

    groups
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, state}, fn {group, index}, {:ok, state} ->
      case execute_group(state, group, canvas_fill(group, index == last, opts), opts) do
        {:ok, state} -> {:cont, {:ok, state}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  # For an output format without alpha, a canvas or padding that nothing
  # later in the request draws over or reads fills with the encoder's white,
  # instead of transparency the encoder would flatten onto white. A
  # result-limit downscale then resizes the white directly, which can change
  # the pixels next to it.
  defp canvas_fill(%Group{bg: nil, watermark: nil}, true = _last?, opts) do
    if Keyword.get(opts, :opaque_output?, false), do: :white, else: :transparent
  end

  defp canvas_fill(%Group{}, _last?, _opts), do: :transparent

  defp execute_group(state, %Group{} = group, fill, opts) do
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
         {:ok, state} <-
           run_color_optional(state, monochrome_op(group.monochrome), opts, :monochrome),
         {:ok, state} <- run_color_optional(state, duotone_op(group.duotone), opts),
         {:ok, state} <- run_optional(state, brightness_op(group.brightness), opts),
         {:ok, state} <- run_optional(state, contrast_op(group.contrast), opts),
         {:ok, state} <- run_optional(state, saturation_op(group.saturation), opts),
         {:ok, state} <- run_color_optional(state, colorize_op(group.colorize), opts),
         {:ok, state} <- run_display_color_optional(state, gradient_op(group.gradient), opts),
         {:ok, state} <- execute_canvas(state, group, dpr, fill, opts),
         {:ok, state} <- execute_padding(state, group.pad, dpr, fill, opts),
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
         {:ok, state} <- Step.run(state, %Rotate{angle: angle}, opts) do
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
         {:ok, state} <- Step.run(state, trim_op(group.trim, group.trim_symmetry), opts) do
      {:ok, Geometry.clear_source_frame(state)}
    end
  end

  # A region reads the display frame. A guided crop that streams runs before
  # pending orientation, compensated into the storage frame; one that needs
  # random access runs on the display frame. Flushing quarter-turns the decode
  # shrink, so crops rescale after it.
  defp execute_crop(state, %Group{region: nil, crop: nil}, _opts), do: {:ok, state}

  defp execute_crop(%State{} = state, %Group{region: region}, opts) when region != nil do
    display = Geometry.display_effective_dims(state)
    crop = region_crop(region, display)

    with {:ok, state} <- flush_display(state),
         do: run_crop(state, rescale(crop, state), crop_extent(crop, display), opts)
  end

  defp execute_crop(%State{} = state, %Group{} = group, opts) do
    display = Geometry.display_effective_dims(state)
    crop = group |> guided_crop(display) |> place_before_shrink(state, display)
    extent = crop_extent(crop, display)

    case {Geometry.pending_class(state), Step.random_access?(crop)} do
      {:pending, false} ->
        pending = state.pending_orientation

        crop
        |> Geometry.rescale_crop(Geometry.orient_decode_shrink(state.decode_shrink, pending))
        |> Geometry.compensate_crop(pending)
        |> then(&run_crop(state, &1, PendingOrientation.display_dims(extent, pending), opts))

      {_class, true} ->
        with {:ok, state} <- flush_display(state),
             do: run_crop(state, rescale(crop, state), extent, opts)

      {_class, false} ->
        run_crop(state, rescale(crop, state), extent, opts)
    end
  end

  defp rescale(crop, state), do: Geometry.rescale_crop(crop, state.decode_shrink)

  # The crop's full-resolution size, in the frame it runs in.
  defp crop_extent(%Crop{width: width, height: height}, {display_width, display_height}),
    do:
      {TransformGeometry.resolve_dimension(width, display_width),
       TransformGeometry.resolve_dimension(height, display_height)}

  # `extent` is the crop's full-resolution size. On a shrunk decode the frame
  # becomes that size, so a later resize doesn't multiply the crop's rounding
  # by the shrink and sizes don't depend on whether the format shrinks on load.
  defp run_crop(%State{decode_shrink: nil} = state, crop, _extent, opts) do
    with {:ok, state} <- Step.run(state, crop, opts),
         do: {:ok, Geometry.clear_source_frame(state)}
  end

  defp run_crop(%State{} = state, crop, {width, height}, opts) do
    with {:ok, %State{} = state} <- Step.run(state, crop, opts) do
      {live_width, live_height} = Geometry.live_dims(state)

      {:ok,
       %State{
         state
         | source_dimensions: {width, height},
           decode_shrink: %{w: width / live_width, h: height / live_height}
       }}
    end
  end

  defp execute_resize(state, %Group{resize: nil, dpr: dpr}, _opts), do: {:ok, state, dpr}

  defp execute_resize(%State{} = state, %Group{} = group, opts) do
    {mode, target} =
      Geometry.resize_target(group.resize, group.dpr, Geometry.display_effective_dims(state))

    {width, height} =
      Geometry.resize_dimensions(mode, target, Geometry.display_effective_dims(state))

    resize = %Resize{width: width, height: height, kernel: group.resize.kernel}
    tail = resize_tail(mode, target, group.guide, group.anchor_offset)

    with {:ok, state} <- prepare_detection_frame(state, resize, tail, opts),
         {:ok, %State{} = state} <- run_resize(state, resize, tail, opts) do
      {:ok, %State{state | detection_frame: nil}, target.dpr}
    end
  end

  defp run_resize(%State{} = state, resize, tail, opts) do
    case Geometry.pending_class(state) do
      :pending ->
        stored = compensate_resize(resize, tail, state.pending_orientation)
        run_stored_resize(state, stored, {resize, tail}, opts)

      _none_or_identity ->
        with {:ok, state} <- Step.run(state, resize, opts),
             do: run_optional(state, tail, opts)
    end
  end

  # A detection crop after a resize below the detection floor would detect on
  # only a few pixels. It detects on the frame before the resize instead, at
  # most twice the floor on the long edge. Detection and the resize both read
  # that frame, so it's buffered; a display-frame copy is cheap at that size.
  # A crop that covers the resized frame can't move, and runs no detection.
  defp prepare_detection_frame(
         %State{} = state,
         %Resize{width: width, height: height, kernel: kernel},
         %Crop{gravity: gravity, width: {:pixels, crop_width}, height: {:pixels, crop_height}},
         opts
       )
       when max(width, height) < @detection_floor and
              {crop_width, crop_height} != {width, height} do
    if detection_runs?(state.detector, state.detector_required, gravity),
      do: buffer_detection_frame(state, kernel, opts),
      else: {:ok, state}
  end

  defp prepare_detection_frame(%State{} = state, _resize, _tail, _opts), do: {:ok, state}

  defp buffer_detection_frame(state, kernel, opts) do
    with {:ok, state} <- flush_before_nearest(state, kernel),
         {:ok, state} <- shrink_to_detection_floor(state, kernel, opts),
         {:ok, %State{} = state} <- Materializer.materialize(state),
         {:ok, display} <- flush_display(state) do
      {:ok, %State{state | detection_frame: display.image}}
    end
  end

  # A nearest shrink picks other pixels in a mirrored or turned stored frame
  # (see run_stored_resize/4), so it runs after the orientation flush.
  defp flush_before_nearest(state, :nearest), do: flush_display(state)
  defp flush_before_nearest(state, _kernel), do: {:ok, state}

  defp shrink_to_detection_floor(%State{} = state, kernel, opts) do
    {width, height} = Geometry.live_dims(state)
    long_edge = max(width, height)

    case long_edge > 2 * @detection_floor do
      true ->
        scale = @detection_floor / long_edge

        resize = %Resize{
          width: max(round(width * scale), 1),
          height: max(round(height * scale), 1),
          kernel: kernel
        }

        Step.run(state, resize, opts)

      false ->
        {:ok, state}
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

  # An enlarge samples with an affine that isn't centred, and a nearest resize
  # picks one pixel at a fixed offset from the top-left edge, so either gives a
  # different result in the stored frame than in the display frame.
  defp run_stored_resize(state, {stored, stored_tail}, {resize, tail}, opts) do
    case stored.kernel == :nearest or enlarges?(state, stored) do
      true ->
        with {:ok, state} <- flush_display(state),
             do: run_resize(state, resize, tail, opts)

      false ->
        with {:ok, state} <- Step.run(state, stored, opts),
             {:ok, state} <- run_pending_tail(state, stored_tail, opts),
             do: flush_display(state)
    end
  end

  defp enlarges?(state, %Resize{width: width, height: height}) do
    {live_width, live_height} = Geometry.live_dims(state)
    width > live_width or height > live_height
  end

  defp compensate_resize(%Resize{} = resize, tail, pending) do
    resize =
      case PendingOrientation.quarter_turn?(pending) do
        true -> %Resize{resize | width: resize.height, height: resize.width}
        false -> resize
      end

    tail = if tail, do: Geometry.compensate_crop(tail, pending), else: nil
    {resize, tail}
  end

  # `Geometry.compensate_crop/2` leaves a materializing result crop (smart or
  # detected) in display coordinates, so it runs after the orientation flush.
  defp run_pending_tail(state, %Crop{} = tail, opts) do
    case Step.random_access?(tail) do
      true -> run_display_optional(state, tail, opts)
      false -> Step.run(state, tail, opts)
    end
  end

  defp run_pending_tail(state, nil, _opts), do: {:ok, state}

  defp run_display_optional(state, nil, _opts), do: {:ok, state}

  defp run_display_optional(state, operation, opts) do
    with {:ok, state} <- flush_display(state),
         do: Step.run(state, operation, opts)
  end

  defp execute_canvas(state, %Group{canvas: nil}, _dpr, _fill, _opts), do: {:ok, state}

  defp execute_canvas(state, %Group{canvas: canvas, resize: resize}, dpr, fill, opts) do
    with {:ok, state} <- flush_display(state) do
      {canvas_width, canvas_height} =
        Geometry.canvas_dims(canvas.mode, resize, dpr, Geometry.live_dims(state))

      {x, y} = canvas.offset
      {anchor_x, anchor_y} = anchor_pair(canvas.at)

      operation = %ExtendCanvas{
        width: canvas_width,
        height: canvas_height,
        gravity: {:anchor, anchor_x, anchor_y},
        x_offset: canvas_offset(x, canvas_width, dpr),
        y_offset: canvas_offset(y, canvas_height, dpr),
        fill: fill
      }

      with {:ok, state} <- Step.run(state, operation, opts) do
        {:ok, Geometry.clear_source_frame(state)}
      end
    end
  end

  defp execute_padding(state, nil, _dpr, _fill, _opts), do: {:ok, state}

  defp execute_padding(state, sides, dpr, fill, opts) do
    [top, right, bottom, left] =
      sides |> Tuple.to_list() |> Enum.map(&round_ties_to_even(&1 * dpr))

    with {:ok, state} <- flush_display(state) do
      {width, height} = Geometry.live_dims(state)

      operation = %ExtendCanvas{
        width: width + left + right,
        height: height + top + bottom,
        gravity: {:anchor, :left, :top},
        x_offset: left,
        y_offset: top,
        fill: fill
      }

      with {:ok, state} <- Step.run(state, operation, opts, :padding) do
        {:ok, Geometry.clear_source_frame(state)}
      end
    end
  end

  defp execute_watermark(state, nil, _dpr, _opts), do: {:ok, state}

  defp execute_watermark(state, watermark, dpr, opts) do
    %{opacity: base_opacity} =
      entry = opts |> Keyword.fetch!(:watermark_images) |> Map.fetch!(watermark.asset)

    with {:ok, state} <- flush_display(state),
         {:ok, state} <- srgb_frame(state, opts),
         {frame_width, frame_height} = Geometry.live_dims(state),
         {width, height} =
           watermark_size(watermark.scale, asset_dims(entry), {frame_width, frame_height}, dpr),
         {:ok, asset} <- drawn_asset(entry, width, height, state, opts),
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

      Step.run(state, operation, opts)
    end
  end

  defp asset_dims(%{image: image}), do: {Image.width(image), Image.height(image)}
  defp asset_dims(%{dims: dims}), do: dims

  # A raster asset is conditioned, then resampled to its drawn size. A vector
  # asset renders straight at its drawn size, so it stays sharp.
  defp drawn_asset(%{image: image}, width, height, state, opts) do
    with {:ok, asset} <- conditioned_asset(image, state, opts),
         do: sized_asset(asset, width, height, state)
  end

  defp drawn_asset(%{render: render}, width, height, %State{} = state, opts) do
    with :ok <- render_limits(width, height, state) |> transform_error(),
         {:ok, image} <- render.(width, height),
         do: conditioned_asset(image, state, opts)
  end

  defp render_limits(width, height, %State{max_intermediate_pixels: limit}) do
    with :ok <- WorkLimits.axes(width, height),
         do: WorkLimits.dimensions({width, height}, limit)
  end

  defp transform_error(:ok), do: :ok
  defp transform_error({:error, reason}), do: {:error, {:transform, reason}}

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
      Materializer.materialize(asset_state)
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

  # When the output is sRGB anyway, a tagged color frame converts to sRGB before
  # compositing. That is one profile conversion, instead of one taking the asset
  # into the frame's profile and another taking the result to sRGB on output.
  defp srgb_frame(%State{image: frame} = state, opts) do
    if Keyword.get(opts, :srgb_output?, false) and not GrayFrame.gray?(frame) do
      with {:ok, state} <- materialize_tagged_frame(state), do: to_srgb_frame(state)
    else
      {:ok, state}
    end
  end

  defp to_srgb_frame(state) do
    case WorkingColor.to_srgb_frame(state) do
      {:ok, state} -> {:ok, state}
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
  defp watermark_size(nil, dims, _frame, dpr),
    do: scaled_dims(dims, dpr)

  defp watermark_size(scale, {width, height} = dims, {frame_width, frame_height}, _dpr) do
    factor = min(frame_width * scale / width, frame_height * scale / height)
    scaled_dims(dims, factor)
  end

  defp scaled_dims({width, height}, factor) do
    {max(1, round_ties_to_even(width * factor)), max(1, round_ties_to_even(height * factor))}
  end

  defp placement_length({:px, value}, _dimension, dpr), do: round_ties_to_even(value * dpr)

  defp placement_length({:pct, value}, dimension, _dpr),
    do: round_ties_to_even(dimension * value / 100)

  # Only the last flush, after every group, passes `buffer_result?` false.
  defp flush_display(%State{} = state, buffer_result? \\ true) do
    case Geometry.pending_class(state) do
      :none ->
        {:ok, state}

      :identity ->
        {:ok, %State{state | pending_orientation: nil}}

      :pending ->
        pending = state.pending_orientation

        with {:ok, state} <- Materializer.flush(state, buffer_result?),
             do: {:ok, orient_source_frame(state, pending)}
    end
  end

  defp orient_source_frame(%State{source_dimensions: nil} = state, pending),
    do: %State{state | decode_shrink: Geometry.orient_decode_shrink(state.decode_shrink, pending)}

  defp orient_source_frame(%State{} = state, %PendingOrientation{} = pending) do
    %State{
      state
      | source_dimensions: PendingOrientation.display_dims(state.source_dimensions, pending),
        decode_shrink: Geometry.orient_decode_shrink(state.decode_shrink, pending)
    }
  end

  defp run_optional(state, nil, _opts), do: {:ok, state}
  defp run_optional(state, operation, opts), do: Step.run(state, operation, opts)

  # Gray and bitonal convert a tagged frame through its profile and remove it.
  defp run_profile_optional(state, nil, _opts), do: {:ok, state}

  defp run_profile_optional(state, operation, opts) do
    with {:ok, state} <- materialize_tagged_frame(state),
         do: Step.run(state, operation, opts)
  end

  # A color effect converts a tagged gray frame to RGB through its profile.
  defp run_color_optional(state, operation, opts, name \\ nil)
  defp run_color_optional(state, nil, _opts, _name), do: {:ok, state}

  defp run_color_optional(%State{image: image} = state, operation, opts, name) do
    with {:ok, state} <-
           if(GrayFrame.gray?(image), do: materialize_tagged_frame(state), else: {:ok, state}),
         do: Step.run(state, operation, opts, name)
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

  # Only a region that starts at or beyond the edge is outside the image. One
  # that starts inside the last pixel keeps it, even when its origin rounds up.
  defp region_crop({x, y, width, height}, {display_width, display_height}) do
    x = resolve_length(x, display_width)
    y = resolve_length(y, display_height)
    left = min(round(x), display_width - 1)
    top = min(round(y), display_height - 1)

    %Crop{
      width: {:pixels, region_extent(width, display_width)},
      height: {:pixels, region_extent(height, display_height)},
      crop_from: %{
        left: {:pixels, left},
        top: {:pixels, top}
      },
      reject_out_of_bounds: x >= display_width or y >= display_height
    }
  end

  # A region under half a pixel still keeps one pixel.
  defp region_extent(length, dimension), do: max(round(resolve_length(length, dimension)), 1)

  # On a shrunk decode, an anchored or focus-point crop placed in the decoded
  # frame would round its box and then centre it there, which can move it by
  # a whole decoded pixel, about one output pixel. It's placed at full
  # resolution instead and kept there as an offset from the top left, which
  # the rescale rounds once.
  defp place_before_shrink(%Crop{} = crop, %State{decode_shrink: nil}, _display), do: crop

  defp place_before_shrink(%Crop{gravity: gravity} = crop, %State{}, display)
       when is_tuple(gravity) and elem(gravity, 0) in [:anchor, :fp] do
    %{left: left, top: top} = Crop.resolve_rect(crop, display)

    %Crop{
      crop
      | gravity: {:anchor, :left, :top},
        x_offset: {:pixels, left},
        y_offset: {:pixels, top}
    }
  end

  defp place_before_shrink(%Crop{} = crop, %State{}, _display), do: crop

  defp guided_crop(%Group{} = group, display_dims) do
    {crop_width, crop_height} = guided_box(group, display_dims)
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

  defp guided_box(%Group{crop: {width, height}} = group, {display_width, display_height}) do
    Geometry.crop_box(
      round(resolve_length(width, display_width)),
      round(resolve_length(height, display_height)),
      group.crop_ratio,
      group.crop_ratio_enlarge,
      {display_width, display_height}
    )
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
    do: %Duotone{intensity: intensity, shadow: [0, 0, 0], highlight: Tuple.to_list(color)}

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
      min(region_extent(width, display_width), display_width),
      min(region_extent(height, display_height), display_height)
    }
  end

  defp decode_crop_extent(%Group{crop: {_width, _height}} = group, display_dims),
    do: guided_box(group, display_dims)

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
      {:error, {tag, _reason}} = error when tag in [:decode, :transform] -> error
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
    with {:ok, image} <- VipsHeader.edit(state.image, [{:remove, "orientation"}]),
         do: {:ok, %State{state | image: image}}
  end

  defp materialize_for_metadata(%State{materialized?: true} = state), do: {:ok, state}

  defp materialize_for_metadata(%State{} = state), do: Materializer.materialize(state)

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
          {group.pad, :padding},
          {group.bg, :background},
          {group.watermark, :watermark}
        ],
        value not in [nil, false],
        do: name
  end

  defp crop_name(%Group{region: region}) when region != nil, do: :crop_region
  defp crop_name(%Group{crop: crop}) when crop != nil, do: :crop_guided
  defp crop_name(%Group{}), do: nil
end
