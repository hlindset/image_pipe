defmodule ImagePipe.Transform.Orientation do
  @moduledoc false
  # Pure orientation-compensation helpers for the deferred-orientation pipeline
  # (issue #146).
  #
  # By design, EXIF auto-orient and user rotate/flip are applied AFTER cropping
  # and resizing in the canonical model. For performance, ImagePipe performs
  # crop/resize before that orientation flush. To keep the observable result
  # identical, the pre-flush crop's gravity (type + X/Y offset) and the pre-flush
  # resize's requested dimensions must be expressed in the *storage* frame.
  #
  # This module is a verbatim port of imgproxy's gravity compensation:
  # `local/imgproxy-master/processing/gravity.go` — `RotateAndFlip` (lines
  # 88-156) plus the rotation/flip type maps (lines 8-57). The offset switches
  # in `RotateAndFlip` key on the *already-remapped* gravity type, and this port
  # preserves that ordering.
  #
  # Gravity representation (executable frame, see Transform.Executor):
  #   {:anchor, :left | :center | :right, :top | :center | :bottom}
  #   {:fp, x :: float, y :: float}        (focus point, fractional coords)
  #   :smart | {:smart, :face_assist} | {:detect, term}   (never remapped)
  #
  # For a focus point the tuple coords carry imgproxy's GravityFocusPoint X/Y
  # (where the focus coords *are* the gravity X/Y), so they rotate/flip via the
  # FP fraction rules (rotate_fp, `1 - fx`). ImagePipe additionally supports a
  # SEPARATE crop offset that imgproxy's FP path has no analog for
  # (calc_position.go uses only the focus coords for GravityFocusPoint). That
  # separate offset is a plain displacement, so it transforms like the
  # GravityCenter vector (negate/axis-swap), NOT via the `1 - x` fraction rule —
  # applying the fraction rule to it injected a spurious 1px shift at 90/270.

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
  Type-only (plus focus-point coordinate) gravity remap for a single
  flipX → flipY → rotate step. Offsets are not considered; this is the directional
  bijection used to validate the type table independently.
  """
  @spec compensate_gravity(gravity(), angle(), boolean(), boolean()) :: gravity()
  def compensate_gravity(gravity, angle, flip_x, flip_y) do
    {gravity, _x, _y} = rotate_and_flip({gravity, 0.0, 0.0}, angle, flip_x, flip_y)
    gravity
  end

  @doc "True when the rotation is a quarter turn, which swaps the width/height axes."
  @spec swap_dims?(angle()) :: boolean()
  def swap_dims?(angle), do: rem(angle, 180) == 90

  @doc """
  Per-storage-axis center-crop discard side under a pending orientation.

  A centered crop with an odd extent difference must discard one extra pixel from
  one side. imgproxy crops in the *display* frame and always rounds the discard so
  the extra kept pixel sits toward the near (top/left) display edge
  (`ShrinkToEven`, calc_position.go:37-38). ImagePipe crops in the *storage* frame
  and flushes orientation after, so a storage-frame near-side bias lands on the
  wrong display side whenever the flush reverses that storage axis's direction.

  Returns `{x_side, y_side}` for the storage X and Y axes, each `:near` (default
  `ShrinkToEven` rounding) or `:far` (round the other way) so that, after the
  flush, the kept pixel lands on imgproxy's near display edge. The flip is needed
  exactly when a storage axis's near (origin) edge maps to a far (right/bottom)
  display edge under the composed orientation (autorotate ∘ user rotate ∘ user
  hflip ∘ user vflip — OrientationFlush.apply_orientation order).
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
  frame ahead of a quarter-turn orientation flush. Width/height, min-width/
  min-height, and zoom_x/zoom_y swap; `dpr` is axis-agnostic and unchanged.
  """
  @spec swap_resize(ImagePipe.Transform.Operation.Resize.t()) ::
          ImagePipe.Transform.Operation.Resize.t()
  def swap_resize(%ImagePipe.Transform.Operation.Resize{} = resize) do
    %ImagePipe.Transform.Operation.Resize{
      resize
      | width: resize.height,
        height: resize.width,
        min_width: resize.min_height,
        min_height: resize.min_width,
        zoom_x: resize.zoom_y,
        zoom_y: resize.zoom_x
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
      # The FP tuple coords flip via `1 - fx` (imgproxy's GravityFocusPoint X/Y
      # ARE the focus coords). The SEPARATE crop offset is a plain displacement,
      # not a focus coord, so it negates like a vector (the Center X-rule) — the
      # `1 - x` fraction rule must NOT touch it.
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

  # FP tuple coords rotate via rotate_fp (the imgproxy GravityFocusPoint coord
  # rule); the SEPARATE crop offset is a plain displacement and rotates like the
  # GravityCenter vector (90 -> {y, -x}), NOT via the `1 - x` fraction rule.
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
