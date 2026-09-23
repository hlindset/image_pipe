defmodule ImagePipe.Transform.Orientation do
  @moduledoc false
  # Maps display-frame crop gravity and resize dimensions to the storage frame,
  # allowing crop/resize to run before the deferred orientation flush without
  # changing the visible result.
  #
  # Follows imgproxy's gravity.go RotateAndFlip and type maps. Offset rules use
  # the already-remapped gravity type, so preserve that ordering.
  #
  # Gravity representation in the executable frame:
  #   {:anchor, :left | :center | :right, :top | :center | :bottom}
  #   {:fp, x :: float, y :: float}        (focus point, fractional coords)
  #   :smart | {:smart, :face_assist} | {:detect, term}   (never remapped)
  #
  # Focus coordinates transform as fractions (e.g. `1 - fx`). Their separate
  # crop offsets are displacement vectors, transformed by negation/axis swaps.
  # Applying fraction rules to offsets would introduce a spurious 1px shift.

  alias ImagePipe.Transform.PendingOrientation

  @type angle :: 0 | 90 | 180 | 270

  @type anchor_h :: :left | :center | :right
  @type anchor_v :: :top | :center | :bottom

  @type gravity ::
          {:anchor, anchor_h(), anchor_v()}
          | {:fp, float(), float()}
          | :smart
          | {:smart, :face_assist}
          | {:detect, term()}

  @type gravity_with_offset :: {gravity(), float(), float()}

  # ── Public API ──────────────────────────────────────────────────────────────

  @doc """
  Compensate a crop's gravity (type + X/Y offset) for a pending orientation.

  Applies `RotateAndFlip` user-first, then EXIF, so that cropping with the
  returned gravity in the storage frame and then flushing orientation matches
  cropping in the oriented frame with the original gravity.
  """
  @spec compensate_gravity_for(gravity_with_offset(), PendingOrientation.t()) ::
          gravity_with_offset()
  def compensate_gravity_for({gravity, x, y}, %PendingOrientation{} = po) do
    {gravity, x, y}
    |> rotate_and_flip(po.user_angle, po.user_flip_x, po.user_flip_y)
    |> rotate_and_flip(po.exif_angle, po.exif_flip_x, false)
  end

  @doc """
  Returns center-crop rounding sides for the storage axes under pending orientation.

  An odd extent difference requires asymmetric rounding. The default
  `ShrinkToEven` rule matches imgproxy's display-frame placement. When orientation
  reverses an axis, storage-frame cropping must reverse that rounding to preserve
  the display result.

  Returns `{x_side, y_side}`, each `:near` for default rounding or `:far` for its
  reverse. An axis uses `:far` when its near storage edge maps to a far display
  edge after EXIF orientation, user rotation, and user flips.
  """
  @spec center_discard_sides(PendingOrientation.t()) :: {:near | :far, :near | :far}
  def center_discard_sides(%PendingOrientation{} = po) do
    # Track each storage-axis near-edge midpoint through the forward (storage →
    # display) transform; if it lands on a far display edge the rounding flips.
    x_near = forward_point({0.0, 0.5}, po)
    y_near = forward_point({0.5, 0.0}, po)

    {discard_side(x_near), discard_side(y_near)}
  end

  # Forward storage → display transform on a normalized point, matching
  # OrientationFlush.apply_orientation: EXIF autorotate, then user rotate, then
  # user hflip, then user vflip. EXIF autorotate = rotate(exif_angle) then hflip
  # when exif_flip_x.
  defp forward_point(point, %PendingOrientation{} = po) do
    point
    |> rotate_point(po.exif_angle)
    |> flip_x_point(po.exif_flip_x)
    |> rotate_point(po.user_angle)
    |> flip_x_point(po.user_flip_x)
    |> flip_y_point(po.user_flip_y)
  end

  defp rotate_point(point, 0), do: point
  defp rotate_point({u, v}, 90), do: {1.0 - v, u}
  defp rotate_point({u, v}, 180), do: {1.0 - u, 1.0 - v}
  defp rotate_point({u, v}, 270), do: {v, 1.0 - u}

  defp flip_x_point(point, false), do: point
  defp flip_x_point({u, v}, true), do: {1.0 - u, v}

  defp flip_y_point(point, false), do: point
  defp flip_y_point({u, v}, true), do: {u, 1.0 - v}

  # Near (left/top) display edges keep the imgproxy rounding; far (right/bottom)
  # edges require the flipped discard side.
  defp discard_side({u, v}) do
    cond do
      u < 0.25 -> :near
      u > 0.75 -> :far
      v < 0.25 -> :near
      v > 0.75 -> :far
    end
  end

  @doc """
  Swap the requested axes of an executable resize so it operates in the storage
  frame ahead of a quarter-turn orientation flush.
  """
  @spec swap_resize(ImagePipe.Transform.Operation.Resize.t()) ::
          ImagePipe.Transform.Operation.Resize.t()
  def swap_resize(%ImagePipe.Transform.Operation.Resize{} = resize) do
    %ImagePipe.Transform.Operation.Resize{
      resize
      | width: resize.height,
        height: resize.width
    }
  end

  # ── Core port of RotateAndFlip (gravity.go:88-156) ───────────────────────────

  @spec rotate_and_flip(gravity_with_offset(), angle(), boolean(), boolean()) ::
          gravity_with_offset()
  defp rotate_and_flip({gravity, x, y}, angle, flip_x, flip_y) do
    angle = rem(angle, 360)

    {gravity, x, y}
    |> apply_flip_x(flip_x)
    |> apply_flip_y(flip_y)
    |> apply_rotate(angle)
  end

  # flipX: remap type via flipX map, then transform offset keyed on the new type
  # (gravity.go:91-102).
  defp apply_flip_x(state, false), do: state

  defp apply_flip_x({gravity, x, y}, true) do
    gravity = flip_x_type(gravity)

    case gravity do
      {:anchor, :center, v} when v in [:top, :bottom, :center] -> {gravity, -x, y}
      # Focus coordinates use `1 - fx`; the separate displacement negates.
      {:fp, fx, fy} -> {{:fp, 1.0 - fx, fy}, -x, y}
      _ -> {gravity, x, y}
    end
  end

  # flipY: remap type via flipY map, then transform offset keyed on the new type
  # (gravity.go:104-115).
  defp apply_flip_y(state, false), do: state

  defp apply_flip_y({gravity, x, y}, true) do
    gravity = flip_y_type(gravity)

    case gravity do
      {:anchor, h, :center} when h in [:left, :right, :center] -> {gravity, x, -y}
      # FP coords flip via `1 - fy`; the separate offset negates like a vector.
      {:fp, fx, fy} -> {{:fp, fx, 1.0 - fy}, x, -y}
      _ -> {gravity, x, y}
    end
  end

  # rotate: remap type via rotation map, then transform offset keyed on the new
  # type (gravity.go:117-155).
  defp apply_rotate(state, 0), do: state

  defp apply_rotate({gravity, x, y}, angle) when angle in [90, 180, 270] do
    gravity = rotate_type(gravity, angle)
    rotate_offset(gravity, angle, x, y)
  end

  # 90° (gravity.go:124-132): post-remap {Center,East,West} -> X,Y = Y,-X.
  defp rotate_offset({:anchor, :center, :center} = g, 90, x, y), do: {g, y, -x}

  defp rotate_offset({:anchor, h, :center} = g, 90, x, y) when h in [:left, :right],
    do: {g, y, -x}

  # Rotate focus fractions and displacement vectors separately.
  defp rotate_offset({:fp, fx, fy}, 90, x, y) do
    {fx2, fy2} = rotate_fp(fx, fy, 90)
    {{:fp, fx2, fy2}, y, -x}
  end

  defp rotate_offset({:anchor, _, _} = g, 90, x, y), do: {g, y, x}

  # 180° (gravity.go:133-143)
  defp rotate_offset({:anchor, :center, :center} = g, 180, x, y), do: {g, -x, -y}

  defp rotate_offset({:anchor, :center, v} = g, 180, x, y) when v in [:top, :bottom],
    do: {g, -x, y}

  defp rotate_offset({:anchor, h, :center} = g, 180, x, y) when h in [:left, :right],
    do: {g, x, -y}

  defp rotate_offset({:fp, _, _} = g, 180, x, y) do
    {fx, fy} = fp_coords(g)
    {fx2, fy2} = rotate_fp(fx, fy, 180)
    # FP offset rotates like the GravityCenter vector (180 -> {-x, -y}).
    {{:fp, fx2, fy2}, -x, -y}
  end

  defp rotate_offset({:anchor, _, _} = g, 180, x, y), do: {g, x, y}

  # 270° (gravity.go:144-152): post-remap {Center,North,South} -> X,Y = -Y,X.
  defp rotate_offset({:anchor, :center, :center} = g, 270, x, y), do: {g, -y, x}

  defp rotate_offset({:anchor, :center, v} = g, 270, x, y) when v in [:top, :bottom],
    do: {g, -y, x}

  defp rotate_offset({:fp, fx, fy}, 270, x, y) do
    {fx2, fy2} = rotate_fp(fx, fy, 270)
    # FP offset rotates like the GravityCenter vector (270 -> {-y, x}).
    {{:fp, fx2, fy2}, -y, x}
  end

  defp rotate_offset({:anchor, _, _} = g, 270, x, y), do: {g, y, x}

  # Never-remapped gravity types (smart/detect): offset is untouched
  # (gravity.go has no rotation-map entry, so the offset switch never matches).
  defp rotate_offset(gravity, angle, x, y) when angle in [90, 180, 270], do: {gravity, x, y}

  # ── Type bijection (gravity.go:8-57) ─────────────────────────────────────────

  # flipX type map (gravity.go:41-48): E↔W and the four corners swap left/right.
  defp flip_x_type({:anchor, :left, v}), do: {:anchor, :right, v}
  defp flip_x_type({:anchor, :right, v}), do: {:anchor, :left, v}
  defp flip_x_type(other), do: other

  # flipY type map (gravity.go:50-57): N↔S and the four corners swap top/bottom.
  defp flip_y_type({:anchor, h, :top}), do: {:anchor, h, :bottom}
  defp flip_y_type({:anchor, h, :bottom}), do: {:anchor, h, :top}
  defp flip_y_type(other), do: other

  # Rotation type map (gravity.go:8-39). Center and the non-anchor types
  # (smart/detect) have no entry and pass through.
  defp rotate_type({:anchor, :center, :center} = g, _angle), do: g

  defp rotate_type({:anchor, _, _} = g, 90), do: rotate_anchor_90(g)
  defp rotate_type({:anchor, _, _} = g, 180), do: rotate_anchor_180(g)
  defp rotate_type({:anchor, _, _} = g, 270), do: rotate_anchor_270(g)

  defp rotate_type(other, _angle), do: other

  # 90° (gravity.go:9-18)
  defp rotate_anchor_90({:anchor, :center, :top}), do: {:anchor, :left, :center}
  defp rotate_anchor_90({:anchor, :right, :center}), do: {:anchor, :center, :top}
  defp rotate_anchor_90({:anchor, :center, :bottom}), do: {:anchor, :right, :center}
  defp rotate_anchor_90({:anchor, :left, :center}), do: {:anchor, :center, :bottom}
  defp rotate_anchor_90({:anchor, :left, :top}), do: {:anchor, :left, :bottom}
  defp rotate_anchor_90({:anchor, :right, :top}), do: {:anchor, :left, :top}
  defp rotate_anchor_90({:anchor, :left, :bottom}), do: {:anchor, :right, :bottom}
  defp rotate_anchor_90({:anchor, :right, :bottom}), do: {:anchor, :right, :top}

  # 180° (gravity.go:19-28); corners are antipodal.
  defp rotate_anchor_180({:anchor, :center, :top}), do: {:anchor, :center, :bottom}
  defp rotate_anchor_180({:anchor, :right, :center}), do: {:anchor, :left, :center}
  defp rotate_anchor_180({:anchor, :center, :bottom}), do: {:anchor, :center, :top}
  defp rotate_anchor_180({:anchor, :left, :center}), do: {:anchor, :right, :center}
  defp rotate_anchor_180({:anchor, :left, :top}), do: {:anchor, :right, :bottom}
  defp rotate_anchor_180({:anchor, :right, :top}), do: {:anchor, :left, :bottom}
  defp rotate_anchor_180({:anchor, :left, :bottom}), do: {:anchor, :right, :top}
  defp rotate_anchor_180({:anchor, :right, :bottom}), do: {:anchor, :left, :top}

  # 270° (gravity.go:29-38)
  defp rotate_anchor_270({:anchor, :center, :top}), do: {:anchor, :right, :center}
  defp rotate_anchor_270({:anchor, :right, :center}), do: {:anchor, :center, :bottom}
  defp rotate_anchor_270({:anchor, :center, :bottom}), do: {:anchor, :left, :center}
  defp rotate_anchor_270({:anchor, :left, :center}), do: {:anchor, :center, :top}
  defp rotate_anchor_270({:anchor, :left, :top}), do: {:anchor, :right, :top}
  defp rotate_anchor_270({:anchor, :right, :top}), do: {:anchor, :right, :bottom}
  defp rotate_anchor_270({:anchor, :left, :bottom}), do: {:anchor, :left, :top}
  defp rotate_anchor_270({:anchor, :right, :bottom}), do: {:anchor, :left, :bottom}

  # Focus-point coordinate rotation (gravity.go FP offset rows, which are the
  # focus coords): 90→{y,1-x}, 180→{1-x,1-y}, 270→{1-y,x}.
  defp rotate_fp(fx, fy, 90), do: {fy, 1.0 - fx}
  defp rotate_fp(fx, fy, 180), do: {1.0 - fx, 1.0 - fy}
  defp rotate_fp(fx, fy, 270), do: {1.0 - fy, fx}

  defp fp_coords({:fp, fx, fy}), do: {fx, fy}
end
