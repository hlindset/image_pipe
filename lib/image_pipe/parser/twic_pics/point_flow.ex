defmodule ImagePipe.Parser.TwicPics.PointFlow do
  @moduledoc false
  # Advances the TwicPics carried point through a neutral emission at resolve
  # time, using the executables' own pure geometry helpers so the trajectory
  # matches execution exactly:
  #
  #   * %Resize{} — the point scales by the realized per-axis factor. A resize
  #     is always the TERMINAL op of its stage (the neutral staging invariant),
  #     so the factor is acquired-stage-dims / dims-entering-the-resize,
  #     applied at the stage seam.
  #   * %Crop{} — a `:deferred` gravity substitutes first: a set point becomes
  #     the concrete {:fp, x, y} (Focus.to_fp against the live dims at the
  #     crop), a nil point becomes the centred anchor (byte-identical to the
  #     old Crop.execute fallback; compensate_crop has already set center_bias,
  #     which the fp path ignores). Substitution happens AFTER the neutral
  #     resolver's orientation compensation, so a storage-frame point is never
  #     gravity-remapped. The point then translates by the realized crop origin
  #     (Crop.resolved_rect/3). Smart/detect crops choose their window from
  #     pixels and do not carry the point — it passes through unchanged, and is
  #     only ever consumed again after a new set_focus directive overwrites it.
  #   * %ExtendCanvas{} — the point translates by the realized embed offset.
  #   * %Flush{} — the point rotates/reflects with the pixels
  #     (Focus.reflect_rotate on the pre-flush dims); the dims swap on a
  #     quarter turn.
  #   * anything else — point- and dims-neutral, matching the execute-time
  #     mechanics (streaming effects; no other dims-changing op is
  #     TwicPics-reachable).

  alias ImagePipe.Resolver
  alias ImagePipe.Transform.Focus
  alias ImagePipe.Transform.Operation.Crop
  alias ImagePipe.Transform.Operation.ExtendCanvas
  alias ImagePipe.Transform.Operation.Flush
  alias ImagePipe.Transform.Operation.Resize
  alias ImagePipe.Transform.PendingOrientation
  alias ImagePipe.Transform.SourceShape

  @spec advance([struct()], Resolver.continuation(), Focus.point() | nil, SourceShape.t()) ::
          {[struct()], Resolver.continuation()}
  def advance(ops, continuation, point, %SourceShape{} = shape) do
    walk_stage(ops, continuation, point, SourceShape.live_dims(shape), shape.pending_orientation)
  end

  defp walk_stage(ops, continuation, point, entry_dims, po) do
    {ops, {point, dims}} = Enum.map_reduce(ops, {point, entry_dims}, &step(&1, &2, po))
    {ops, rewrap(continuation, point, dims, po)}
  end

  defp rewrap({:advance, %SourceShape{} = shape, nil}, point, _dims, _po),
    do: {:advance, shape, point}

  defp rewrap({:acquire, then_fn}, point, pre_dims, po) do
    {:acquire,
     fn acquired ->
       point = scale_at_seam(point, pre_dims, acquired)

       case then_fn.(acquired) do
         {%SourceShape{} = shape, nil} ->
           {shape, point}

         {ops, continuation} when is_list(ops) ->
           walk_stage(ops, continuation, point, acquired, po)
       end
     end}
  end

  # Every TwicPics-reachable :acquire seam follows a %Resize{} (the terminal-op
  # invariant), so the realized per-axis factor is acquired/pre — the same
  # integers Resize.execute used to read off the live image.
  defp scale_at_seam(point, {pre_w, pre_h}, {w, h}),
    do: Focus.scale(point, {:ratio, w, pre_w}, {:ratio, h, pre_h})

  defp step(%Crop{gravity: :deferred} = crop, {point, {w, h}}, po),
    do: step(%Crop{crop | gravity: substituted_gravity(point, w, h)}, {point, {w, h}}, po)

  defp step(%Crop{gravity: gravity} = crop, {point, {w, h}}, _po)
       when gravity == :smart
       when is_tuple(gravity) and elem(gravity, 0) in [:smart, :detect] do
    {crop, {point, Crop.resolved_box_dims(crop, w, h)}}
  end

  defp step(%Crop{} = crop, {point, {w, h}}, _po) do
    {:ok, %{left: left, top: top, width: box_w, height: box_h}} = Crop.resolved_rect(crop, w, h)
    {crop, {Focus.translate(point, -left, -top), {box_w, box_h}}}
  end

  defp step(%ExtendCanvas{rule: rule} = op, {point, {w, h}}, _po) do
    {:ok, {canvas_w, canvas_h}} = ExtendCanvas.resolved_canvas_dims(rule, w, h)
    {x, y} = ExtendCanvas.resolved_embed_offset(op, w, h, canvas_w, canvas_h)
    {op, {Focus.translate(point, x, y), {canvas_w, canvas_h}}}
  end

  defp step(%Flush{} = op, {point, dims}, %PendingOrientation{} = po) do
    {op, {Focus.reflect_rotate(point, po, dims), PendingOrientation.display_dims(dims, po)}}
  end

  defp step(%Resize{} = op, acc, _po), do: {op, acc}

  defp step(op, acc, _po), do: {op, acc}

  defp substituted_gravity(nil, _w, _h), do: {:anchor, :center, :center}
  defp substituted_gravity(point, w, h), do: Focus.to_fp(point, w, h)
end
