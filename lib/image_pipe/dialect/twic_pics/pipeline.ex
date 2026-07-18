defmodule ImagePipe.Dialect.TwicPics.Pipeline do
  @moduledoc false

  alias ImagePipe.Dialect.TwicPics.PointFlow
  alias ImagePipe.Dialect.TwicPics.Request
  alias ImagePipe.Plan.Operation.CropGuided
  alias ImagePipe.Plan.Operation.CropRegion
  alias ImagePipe.Plan.Operation.Resize, as: PlanResize
  alias ImagePipe.Transform
  alias ImagePipe.Transform.Chain
  alias ImagePipe.Transform.DecodePlanner
  alias ImagePipe.Transform.InputColorManagement
  alias ImagePipe.Transform.Operation.Flush
  alias ImagePipe.Transform.PendingOrientation
  alias ImagePipe.Transform.SourceGeometry
  alias ImagePipe.Transform.SourceShape
  alias ImagePipe.Transform.State

  @max_continuation_depth 4

  @spec decode_request(Request.t(), SourceGeometry.t()) :: DecodePlanner.Request.t()
  def decode_request(%Request{} = request, %SourceGeometry{} = geometry) do
    planning_dims = SourceGeometry.planning_frame(geometry, request.auto_rotate)
    {resize, crop_extent} = first_resize(request.steps, planning_dims)

    %DecodePlanner.Request{
      resize_target: resize_target(resize),
      crop_extent: crop_extent,
      trim?: false,
      terminal_reduction: nil,
      required_extent: nil,
      user_quarter_turn?: false
    }
  end

  @spec run(State.t(), SourceGeometry.t(), Request.t(), keyword()) ::
          {:ok, State.t()} | {:error, {:transform, term()} | {:decode, term()}}
  def run(%State{} = state, %SourceGeometry{}, %Request{} = request, opts) do
    state = seed_detector(state, opts)

    with {:ok, %State{} = state} <- condition_color(state, opts),
         {:ok, %State{} = state} <- run_steps(state, request.steps, opts) do
      {:ok, InputColorManagement.stamp_carry(state)}
    end
  end

  # ex_dna:disable-for-next-line
  defp seed_detector(%State{} = state, opts) do
    %State{
      state
      | detector: Transform.resolve_detector(Keyword.get(opts, :detector, :default)),
        detector_required: Keyword.get(opts, :detector_required, false)
    }
  end

  # ex_dna:disable-for-next-line
  defp condition_color(%State{} = state, opts) do
    supports_hdr? = Keyword.get(opts, :supports_hdr?, false)

    case InputColorManagement.condition(state, supports_hdr?: supports_hdr?) do
      {:ok, %State{} = state} -> {:ok, state}
      {:error, {InputColorManagement, reason}} -> {:error, {:decode, reason}}
    end
  end

  defp run_steps(%State{} = state, steps, opts) do
    ctx = build_ctx(opts)
    {width, height} = State.effective_source_dims(state)

    shape =
      SourceShape.seed(%{
        width: width,
        height: height,
        pending_orientation: state.pending_orientation,
        decode_shrink: state.decode_shrink
      })

    steps
    |> Enum.reduce_while({:ok, state, shape, PointFlow.init()}, fn step, acc ->
      case run_step(step, acc, ctx) do
        {:ok, _state, _shape, _flow} = ok -> {:cont, ok}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, state, shape, _flow} -> flush_boundary(state, shape, ctx)
      {:error, _reason} = error -> error
    end
  end

  defp run_step(
         {:set_focus, operand},
         {:ok, %State{} = state, %SourceShape{} = shape, %PointFlow{} = flow},
         _ctx
       ) do
    {:ok, state, shape, PointFlow.set_focus(shape, flow, operand)}
  end

  defp run_step(
         :set_auto_focus,
         {:ok, %State{} = state, %SourceShape{} = shape, %PointFlow{} = flow},
         _ctx
       ) do
    {:ok, state, shape, PointFlow.set_auto(flow)}
  end

  defp run_step(
         {kind, _operation} = step,
         {:ok, %State{} = state, %SourceShape{} = shape, %PointFlow{} = flow},
         ctx
       )
       when kind in [:operation, :focused] do
    state = overlay(state, shape)
    {ops, continuation} = PointFlow.resolve(shape, flow, step)

    with {:ok, state} <- run_chain(ctx, state, ops) do
      follow(state, shape, continuation, ctx, 0)
    end
  end

  defp build_ctx(opts) do
    %{
      chain: Keyword.get(opts, :chain, &Chain.execute/3),
      measure_dims: Keyword.get(opts, :measure_dims, &default_measure_dims/1),
      continue: Keyword.get(opts, :continue, &PointFlow.continue/4),
      opts: opts
    }
  end

  defp default_measure_dims(image), do: {Image.width(image), Image.height(image)}

  # ex_dna:disable-for-next-line
  defp overlay(%State{} = state, %SourceShape{} = shape) do
    %State{
      state
      | pending_orientation: shape.pending_orientation,
        decode_shrink: shape.decode_shrink,
        source_dimensions: {shape.width, shape.height}
    }
  end

  defp follow(
         %State{} = state,
         _pre_shape,
         {:advance, %SourceShape{} = shape, %PointFlow{} = flow},
         _ctx,
         _depth
       ) do
    {:ok, state, shape, flow}
  end

  defp follow(
         %State{} = state,
         %SourceShape{} = pre_shape,
         {:measure, tag, seam},
         ctx,
         depth
       )
       when depth < @max_continuation_depth do
    measured = ctx.measure_dims.(state.image)

    case ctx.continue.(tag, measured, pre_shape, seam) do
      {%SourceShape{} = shape, %PointFlow{} = flow} ->
        {:ok, state, shape, flow}

      {tail_ops, continuation} when is_list(tail_ops) ->
        with {:ok, state} <- run_chain(ctx, state, tail_ops) do
          follow(state, pre_shape, continuation, ctx, depth + 1)
        end
    end
  end

  defp run_chain(ctx, %State{} = state, ops) do
    case ctx.chain.(state, ops, ctx.opts) do
      {:ok, %State{}} = ok -> ok
      {:error, reason} -> {:error, {:transform, reason}}
    end
  end

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

      %PendingOrientation{} = pending ->
        if PendingOrientation.identity?(pending) do
          {:ok, %State{state | pending_orientation: nil}}
        else
          run_chain(ctx, state, [%Flush{}])
        end
    end
  end

  # ex_dna:disable-for-next-line
  defp boundary_source_dimensions(%SourceShape{decode_shrink: nil}), do: nil
  defp boundary_source_dimensions(%SourceShape{width: width, height: height}), do: {width, height}

  defp first_resize(steps, display_dims) do
    Enum.reduce_while(steps, {nil, nil}, fn
      {:operation, %PlanResize{} = resize}, {_resize, crop_extent} ->
        {:halt, {resize, crop_extent}}

      {:focused, %PlanResize{} = resize}, {_resize, crop_extent} ->
        {:halt, {resize, crop_extent}}

      {kind, %CropGuided{} = crop}, {nil, nil} when kind in [:operation, :focused] ->
        {:cont, {nil, crop_extent(crop, display_dims)}}

      {kind, %CropRegion{} = crop}, {nil, nil} when kind in [:operation, :focused] ->
        {:cont, {nil, crop_extent(crop, display_dims)}}

      _step, acc ->
        {:cont, acc}
    end)
  end

  defp crop_extent(%{width: width, height: height}, {display_w, display_h}) do
    {crop_axis_extent(width, display_w), crop_axis_extent(height, display_h)}
  end

  defp crop_axis_extent(:full_axis, source), do: source
  defp crop_axis_extent({:px, value}, source), do: min(value, source)

  defp crop_axis_extent({:ratio, numerator, denominator}, source),
    do: min(source, max(1, round(source * numerator / denominator)))

  defp resize_target(nil), do: nil

  defp resize_target(%PlanResize{min_width: min_width, min_height: min_height})
       when not is_nil(min_width) or not is_nil(min_height),
       do: nil

  defp resize_target(%PlanResize{} = resize) do
    dpr = ratio_float(resize.dpr)

    case {
      target_axis(resize.width, dpr, resize.zoom_x),
      target_axis(resize.height, dpr, resize.zoom_y)
    } do
      {nil, nil} -> nil
      target -> target
    end
  end

  defp target_axis({:px, value}, dpr, zoom), do: value * dpr * zoom_float(zoom)
  defp target_axis(_dimension, _dpr, _zoom), do: nil

  defp ratio_float({:ratio, numerator, denominator}), do: numerator / denominator
  defp zoom_float({:ratio, numerator, denominator}), do: numerator / denominator
  defp zoom_float(value), do: value
end
