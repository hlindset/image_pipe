defmodule ImagePipe.Transform.Executor do
  @moduledoc """
  Executes canonical request intent over a decoded transform state.

  The executor owns the fixed per-group stage order and resolves geometry from
  the current image plus the decode state. Right-angle orientation remains
  deferred until a stage needs display-frame pixels or the request boundary.
  """

  alias ImagePipe.Plan.Color
  alias ImagePipe.Plan.Request
  alias ImagePipe.Plan.Request.Group
  alias ImagePipe.Plan.Request.Output
  alias ImagePipe.Transform
  alias ImagePipe.Transform.DecodePlanner
  alias ImagePipe.Transform.Executor.Geometry
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
  alias ImagePipe.Transform.Operation.Flush
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
  alias ImagePipe.Transform.SourceGeometry
  alias ImagePipe.Transform.State
  alias Vix.Vips.Image, as: VipsImage
  alias Vix.Vips.MutableImage, as: VipsMutableImage

  @default_trim_threshold 10.0
  @blurhash_terminal_reduction {32, 32}

  @spec decode_request(Request.t(), SourceGeometry.t()) :: DecodePlanner.Request.t()
  def decode_request(%Request{groups: [%Group{rotate: angle} | _]}, _geometry)
      when angle != nil and angle not in [90, 180, 270] do
    %DecodePlanner.Request{}
  end

  def decode_request(
        %Request{groups: [%Group{} = group | _]} = request,
        %SourceGeometry{} = geometry
      ) do
    {display_width, display_height} = geometry.display_dimensions
    quarter_turn? = group.rotate in [90, 270]

    crop_frame =
      if quarter_turn?, do: {display_height, display_width}, else: {display_width, display_height}

    %DecodePlanner.Request{
      resize_target: decode_resize_target(group.resize, group.dpr),
      crop_extent: decode_crop_extent(group, crop_frame),
      user_quarter_turn?: quarter_turn?,
      trim?: group.trim != nil,
      terminal_reduction: decode_terminal_reduction(request)
    }
  end

  @spec execute(State.t(), Request.t(), keyword()) ::
          {:ok, State.t()} | {:error, {:transform, term()} | {:decode, term()}}
  def execute(%State{} = state, %Request{} = request, opts) do
    state = %State{
      state
      | detector: Transform.resolve_detector(Keyword.get(opts, :detector, :default))
    }

    with {:ok, state} <- condition_color(state, opts),
         {:ok, state} <- execute_groups(state, request.groups, opts),
         {:ok, state} <- flush_display(state, opts) do
      normalize_output_orientation(state, request.output, opts)
    end
  end

  @spec reduce_terminal(State.t(), Output.t(), keyword()) ::
          {:ok, State.t()} | {:error, {:transform, term()} | {:decode, term()}}
  def reduce_terminal(%State{} = state, %Output{terminal: terminal}, _opts)
      when terminal in [:image, :info],
      do: {:ok, state}

  def reduce_terminal(%State{} = state, %Output{terminal: :blurhash}, opts) do
    {width, height} = @blurhash_terminal_reduction

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

    Transform.run(
      state,
      %Resize{width: target.width, height: target.height},
      opts
    )
  end

  @doc "The fixed-order operation names represented by a request."
  @spec operation_names(Request.t()) :: [atom()]
  def operation_names(%Request{groups: groups}),
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
         {:ok, state} <- run_optional(state, blur_op(group.blur), opts),
         {:ok, state} <- run_optional(state, sharpen_op(group.sharpen), opts),
         {:ok, state} <- run_display_optional(state, pixelate_op(group.pixelate), opts),
         {:ok, state} <- run_optional(state, if(group.gray, do: %Gray{}), opts),
         {:ok, state} <- run_optional(state, if(group.bitonal, do: %Bitonal{}), opts),
         {:ok, state} <- run_optional(state, monochrome_op(group.monochrome), opts),
         {:ok, state} <- run_optional(state, duotone_op(group.duotone), opts),
         {:ok, state} <- run_optional(state, brightness_op(group.brightness), opts),
         {:ok, state} <- run_optional(state, contrast_op(group.contrast), opts),
         {:ok, state} <- run_optional(state, saturation_op(group.saturation), opts),
         {:ok, state} <- run_optional(state, colorize_op(group.colorize), opts),
         {:ok, state} <- run_display_optional(state, gradient_op(group.gradient), opts),
         {:ok, state} <- execute_canvas(state, group, dpr, opts),
         {:ok, state} <- execute_padding(state, group.pad, dpr, opts) do
      run_optional(state, background_op(group.bg), opts)
    end
  end

  defp execute_rotate(state, nil, _opts), do: {:ok, state}

  defp execute_rotate(%State{} = state, angle, _opts) when angle in [0, 90, 180, 270] do
    pending = state.pending_orientation || %PendingOrientation{}
    {:ok, %State{state | pending_orientation: PendingOrientation.fold_rotate(pending, angle)}}
  end

  defp execute_rotate(%State{} = state, angle, opts) do
    with {:ok, state} <- flush_display(state, opts),
         {:ok, state} <- Transform.run(state, %Rotate{angle: angle}, opts) do
      {:ok, Geometry.clear_source_frame(state)}
    end
  end

  defp execute_flip(state, nil), do: {:ok, state}

  defp execute_flip(%State{} = state, axis) do
    pending = state.pending_orientation || %PendingOrientation{}
    {:ok, %State{state | pending_orientation: PendingOrientation.fold_flip(pending, axis)}}
  end

  defp execute_trim(state, %Group{trim: nil}, _opts), do: {:ok, state}

  defp execute_trim(state, %Group{} = group, opts) do
    with {:ok, state} <- flush_display(state, opts),
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

    with {:ok, state} <- maybe_flush_tagged(state, opts),
         {:ok, state} <- Transform.run(state, crop, opts) do
      {:ok, Geometry.clear_source_frame(state)}
    end
  end

  defp execute_crop(%State{} = state, %Group{} = group, opts) do
    crop_dpr = crop_offset_dpr(group, state)
    crop = guided_crop(group, Geometry.display_effective_dims(state), crop_dpr)
    materializing? = materializing_gravity?(crop.gravity)

    case {Geometry.pending_class(state), materializing?} do
      {:pending, true} ->
        pending = state.pending_orientation

        crop =
          Geometry.rescale_crop(
            crop,
            Geometry.orient_decode_shrink(state.decode_shrink, pending)
          )

        with {:ok, state} <- flush_display(state, opts),
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

  defp maybe_flush_tagged({:flush, state}, opts), do: flush_display(state, opts)
  defp maybe_flush_tagged(%State{} = state, _opts), do: {:ok, state}

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
             {:ok, state} <- run_optional(state, tail, opts),
             {:ok, state} <- flush_display(state, opts) do
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
       when mode in [:cover, :cover_down, :auto_cover] do
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

  defp run_display_optional(state, nil, _opts), do: {:ok, state}

  defp run_display_optional(state, operation, opts) do
    with {:ok, state} <- flush_display(state, opts),
         do: Transform.run(state, operation, opts)
  end

  defp execute_canvas(state, %Group{canvas: nil}, _dpr, _opts), do: {:ok, state}

  defp execute_canvas(state, %Group{canvas: canvas, resize: resize}, dpr, opts) do
    with {:ok, state} <- flush_display(state, opts) do
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
        y_offset: canvas_offset(y, canvas_height, dpr),
        background: :transparent
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
      top: Geometry.round_half_to_even(top * dpr),
      right: Geometry.round_half_to_even(right * dpr),
      bottom: Geometry.round_half_to_even(bottom * dpr),
      left: Geometry.round_half_to_even(left * dpr),
      fill: :transparent
    }

    with {:ok, state} <- flush_display(state, opts),
         {:ok, state} <- Transform.run(state, operation, opts) do
      {:ok, Geometry.clear_source_frame(state)}
    end
  end

  defp flush_display(%State{} = state, opts) do
    case Geometry.pending_class(state) do
      :none ->
        {:ok, state}

      :identity ->
        {:ok, %State{state | pending_orientation: nil}}

      :pending ->
        pending = state.pending_orientation

        with {:ok, state} <- Transform.run(state, %Flush{}, opts) do
          {:ok, orient_source_frame(state, pending)}
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

  defp crop_offset_dpr(%Group{anchor_offset: nil, dpr: dpr}, _state), do: dpr
  defp crop_offset_dpr(%Group{resize: nil, dpr: dpr}, _state), do: dpr

  defp crop_offset_dpr(%Group{} = group, state) do
    crop = guided_crop(group, Geometry.display_effective_dims(state), 1.0)

    {width, height} =
      Crop.resolved_box_dims(
        crop,
        elem(Geometry.display_effective_dims(state), 0),
        elem(Geometry.display_effective_dims(state), 1)
      )

    {_mode, target} = Geometry.resize_target(group.resize, group.dpr, {width, height})
    target.dpr
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

  defp guided_crop(%Group{crop: {width, height}} = group, {display_width, display_height}, dpr) do
    requested = %Crop{
      width: {:pixels, round(resolve_length(width, display_width))},
      height: {:pixels, round(resolve_length(height, display_height))},
      crop_from: :gravity,
      aspect_ratio: group.crop_ratio,
      enlarge: group.crop_ratio_enlarge
    }

    {crop_width, crop_height} =
      Crop.resolved_box_dims(requested, display_width, display_height)

    {x_offset, y_offset} = crop_offsets(group.anchor_offset, dpr)

    %Crop{
      width: {:pixels, crop_width},
      height: {:pixels, crop_height},
      crop_from: :gravity,
      gravity: guide_gravity(group.guide),
      x_offset: x_offset,
      y_offset: y_offset
    }
  end

  defp crop_offsets(nil, _dpr), do: {{:pixels, 0.0}, {:pixels, 0.0}}

  defp crop_offsets({x, y}, dpr),
    do: {scaled_offset(x, dpr), scaled_offset(y, dpr)}

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

  defp materializing_gravity?(:smart), do: true
  defp materializing_gravity?({:smart, _}), do: true
  defp materializing_gravity?({:detect, _}), do: true
  defp materializing_gravity?(_gravity), do: false

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

  defp decode_resize_target(nil, _dpr), do: nil

  defp decode_resize_target(%{min_w: min_width, min_h: min_height}, _dpr)
       when min_width != nil or min_height != nil,
       do: nil

  defp decode_resize_target(%{w: width, h: height, zoom: {zoom_x, zoom_y}}, dpr) do
    case {decode_axis(width, zoom_x * dpr), decode_axis(height, zoom_y * dpr)} do
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
    crop = guided_crop(group, display_dims, 1.0)
    Crop.resolved_box_dims(crop, elem(display_dims, 0), elem(display_dims, 1))
  end

  defp decode_crop_extent(%Group{}, _display_dims), do: nil

  defp decode_terminal_reduction(%Request{
         groups: [_group],
         output: %Output{terminal: :blurhash}
       }),
       do: @blurhash_terminal_reduction

  defp decode_terminal_reduction(%Request{}), do: nil

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

  defp materialize_for_orientation_metadata(%State{materialized?: true} = state), do: {:ok, state}

  defp materialize_for_orientation_metadata(%State{} = state) do
    case Materializer.materialize(state) do
      {:ok, state} -> {:ok, state}
      {:error, reason} -> {:error, {:decode, reason}}
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
          {group.bg, :background}
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
