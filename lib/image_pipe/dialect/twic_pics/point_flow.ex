defmodule ImagePipe.Dialect.TwicPics.PointFlow do
  @moduledoc false

  alias ImagePipe.Plan.Operation.CropGuided
  alias ImagePipe.Plan.Operation.Resize, as: PlanResize
  alias ImagePipe.Transform.Focus
  alias ImagePipe.Transform.NeutralResolver
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
  alias ImagePipe.Transform.Operation.Pixelate
  alias ImagePipe.Transform.Operation.Resize
  alias ImagePipe.Transform.Operation.Saturation
  alias ImagePipe.Transform.Operation.Sharpen
  alias ImagePipe.Transform.PendingOrientation
  alias ImagePipe.Transform.SourceShape

  @point_dims_neutral_ops [
    Background,
    Bitonal,
    Blur,
    Brightness,
    Colorize,
    Contrast,
    Duotone,
    Gradient,
    Gray,
    Monochrome,
    Pixelate,
    Saturation,
    Sharpen
  ]

  defstruct guide: :point, point: nil

  @type t :: %__MODULE__{
          guide: :point | {:smart, :face_assist},
          point: Focus.point() | nil
        }

  @type step :: {:operation | :focused, struct()}
  @type continuation ::
          {:advance, SourceShape.t(), t()}
          | {:measure, term(), seam_state()}
  @type seam_state :: {:seam, t(), {pos_integer(), pos_integer()}, boolean()}

  @spec init() :: t()
  def init, do: %__MODULE__{}

  @spec set_focus(SourceShape.t(), t(), Focus.operand()) :: t()
  def set_focus(%SourceShape{} = shape, %__MODULE__{} = flow, operand) do
    point =
      Focus.resolve(
        operand,
        %{storage: SourceShape.live_dims(shape), decode_shrink: shape.decode_shrink},
        shape.pending_orientation
      )

    %__MODULE__{flow | guide: :point, point: point}
  end

  @spec set_auto(t()) :: t()
  def set_auto(%__MODULE__{} = flow),
    do: %__MODULE__{flow | guide: {:smart, :face_assist}}

  @spec resolve(SourceShape.t(), t(), step()) :: {[struct()], continuation()}
  def resolve(%SourceShape{} = shape, %__MODULE__{} = flow, {:operation, operation}) do
    {ops, continuation} = NeutralResolver.resolve(shape, nil, operation)

    walk_stage(
      ops,
      continuation,
      flow,
      SourceShape.live_dims(shape),
      shape.pending_orientation,
      false
    )
  end

  def resolve(
        %SourceShape{} = shape,
        %__MODULE__{guide: :point} = flow,
        {:focused, operation}
      ) do
    {ops, continuation} = NeutralResolver.resolve_late_bound_guide(shape, operation)

    walk_stage(
      ops,
      continuation,
      flow,
      SourceShape.live_dims(shape),
      shape.pending_orientation,
      true
    )
  end

  def resolve(
        %SourceShape{} = shape,
        %__MODULE__{guide: {:smart, :face_assist}} = flow,
        {:focused, operation}
      ) do
    operation = put_guide(operation, {:smart, :face_assist})
    {ops, continuation} = NeutralResolver.resolve(shape, nil, operation)

    walk_stage(
      ops,
      continuation,
      flow,
      SourceShape.live_dims(shape),
      shape.pending_orientation,
      false
    )
  end

  @spec continue(term(), {pos_integer(), pos_integer()}, SourceShape.t(), seam_state()) ::
          {SourceShape.t(), t()} | {[struct()], continuation()}
  def continue(
        tag,
        measured,
        %SourceShape{} = shape,
        {:seam, %__MODULE__{} = flow, entry_dims, bind?}
      ) do
    flow = %__MODULE__{flow | point: scale_at_seam(flow.point, entry_dims, measured)}

    case NeutralResolver.continue(tag, measured, shape, nil) do
      {%SourceShape{} = final, nil} ->
        {final, flow}

      {ops, continuation} when is_list(ops) ->
        walk_stage(ops, continuation, flow, measured, shape.pending_orientation, bind?)
    end
  end

  defp walk_stage(ops, continuation, flow, entry_dims, pending_orientation, bind?) do
    {ops, {flow, dims}} =
      Enum.map_reduce(ops, {flow, entry_dims}, &step(&1, &2, pending_orientation, bind?))

    {ops, rewrap(continuation, flow, dims, bind?)}
  end

  defp rewrap({:advance, %SourceShape{} = shape, nil}, flow, _dims, _bind?),
    do: {:advance, shape, flow}

  defp rewrap({:measure, tag, nil}, flow, dims, bind?),
    do: {:measure, tag, {:seam, flow, dims, bind?}}

  defp scale_at_seam(point, {pre_w, pre_h}, {width, height}),
    do: Focus.scale(point, {:ratio, width, pre_w}, {:ratio, height, pre_h})

  defp step(%Crop{} = crop, acc, pending_orientation, true) do
    {flow, {width, height}} = acc
    gravity = substituted_gravity(flow.point, width, height)
    step(%Crop{crop | gravity: gravity}, acc, pending_orientation, false)
  end

  defp step(%Crop{gravity: gravity} = crop, {flow, {width, height}}, _pending, _bind?)
       when gravity == :smart
       when is_tuple(gravity) and elem(gravity, 0) in [:smart, :detect] do
    {crop, {flow, Crop.resolved_box_dims(crop, width, height)}}
  end

  defp step(
         %Crop{} = crop,
         {%__MODULE__{} = flow, {width, height}},
         _pending,
         _bind?
       ) do
    {:ok, %{left: left, top: top, width: box_w, height: box_h}} =
      Crop.resolved_rect(crop, width, height)

    flow = %__MODULE__{flow | point: Focus.translate(flow.point, -left, -top)}
    {crop, {flow, {box_w, box_h}}}
  end

  defp step(
         %ExtendCanvas{rule: rule} = operation,
         {%__MODULE__{} = flow, {width, height}},
         _pending,
         _bind?
       ) do
    {:ok, {canvas_w, canvas_h}} =
      ExtendCanvas.resolved_canvas_dims(rule, width, height)

    {x, y} =
      ExtendCanvas.resolved_embed_offset(operation, width, height, canvas_w, canvas_h)

    flow = %__MODULE__{flow | point: Focus.translate(flow.point, x, y)}
    {operation, {flow, {canvas_w, canvas_h}}}
  end

  defp step(
         %Flush{} = operation,
         {%__MODULE__{} = flow, dims},
         %PendingOrientation{} = pending,
         _bind?
       ) do
    flow = %__MODULE__{flow | point: Focus.reflect_rotate(flow.point, pending, dims)}
    {operation, {flow, PendingOrientation.display_dims(dims, pending)}}
  end

  defp step(%Resize{} = operation, acc, _pending, _bind?), do: {operation, acc}

  defp step(%module{} = operation, acc, _pending, _bind?)
       when module in @point_dims_neutral_ops,
       do: {operation, acc}

  defp step(operation, _acc, _pending, _bind?) do
    raise "ImagePipe.Dialect.TwicPics.PointFlow has no rule for advancing the carried " <>
            "focus point through #{inspect(operation.__struct__)} — add an explicit step/4 " <>
            "clause (or list it in @point_dims_neutral_ops if it never affects the point " <>
            "or dims)"
  end

  defp put_guide(%CropGuided{} = operation, guide), do: %CropGuided{operation | guide: guide}
  defp put_guide(%PlanResize{} = operation, guide), do: %PlanResize{operation | guide: guide}

  defp substituted_gravity(nil, _width, _height), do: {:anchor, :center, :center}
  defp substituted_gravity(point, width, height), do: Focus.to_fp(point, width, height)
end
