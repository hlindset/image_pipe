defmodule ImagePipe.Transform.Focus do
  @moduledoc false
  # Neutral point-math namespace for the carried point, transformed by each
  # geometry op's realized affine. An exact-rational continuous coordinate in
  # the live-image frame; the only float conversion is `to_fp/1`, at the libvips
  # boundary. Every function is a no-op when the carried point is `nil` (a
  # strategy may not carry a point), so point-free plans are unaffected. The
  # TwicPics strategy is the current producer.
  #
  # The numerator is integer() (matching ImagePipe.Plan.Measure): a crop
  # translate can transiently negate it (focus left/above the crop window); a
  # later canvas embed brings it back in range. Only `to_fp/1` clamps.

  alias ImagePipe.Transform.PendingOrientation
  alias ImagePipe.Transform.State

  @type ratio :: {:ratio, integer(), pos_integer()}
  @type point :: {ratio(), ratio()}

  @type measure :: {:px, non_neg_integer()} | {:ratio, non_neg_integer(), pos_integer()}
  @type operand ::
          {:coord, measure(), measure()}
          | {:anchor, :left | :center | :right, :top | :center | :bottom}

  @spec scale(State.t(), ratio(), ratio()) :: State.t()
  def scale(%State{carried_point: nil} = state, _sx, _sy), do: state

  def scale(%State{carried_point: {x, y}} = state, sx, sy),
    do: %State{state | carried_point: {ratio_mul(x, sx), ratio_mul(y, sy)}}

  @spec translate(State.t(), integer(), integer()) :: State.t()
  def translate(%State{carried_point: nil} = state, _dx, _dy), do: state

  def translate(%State{carried_point: {x, y}} = state, dx, dy),
    do: %State{state | carried_point: {ratio_add_int(x, dx), ratio_add_int(y, dy)}}

  @spec to_fp(State.t()) :: nil | {:fp, float(), float()}
  def to_fp(%State{carried_point: nil}), do: nil

  def to_fp(%State{carried_point: {x, y}, image: image}) do
    {:fp, clamp01(ratio_to_float(x) / Image.width(image)),
     clamp01(ratio_to_float(y) / Image.height(image))}
  end

  @doc """
  Forward (storage -> display) transform of the carried point at the orientation
  flush, matching `OrientationFlush.apply_orientation`'s order
  (EXIF autorotate, then user rotate, then user hflip, then user vflip). `pre` is
  the pre-flush live image dims; the post-flush frame swaps axes on a quarter turn.
  """
  @spec reflect_rotate(State.t(), PendingOrientation.t(), {pos_integer(), pos_integer()}) ::
          State.t()
  def reflect_rotate(%State{carried_point: nil} = state, _po, _pre), do: state

  def reflect_rotate(
        %State{carried_point: {x, y}} = state,
        %PendingOrientation{} = po,
        {pre_w, pre_h}
      ) do
    {fx2, fy2} = forward_fraction({ratio_div(x, pre_w), ratio_div(y, pre_h)}, po)

    {post_w, post_h} =
      if PendingOrientation.quarter_turn?(po), do: {pre_h, pre_w}, else: {pre_w, pre_h}

    %State{
      state
      | carried_point: {ratio_mul(fx2, {:ratio, post_w, 1}), ratio_mul(fy2, {:ratio, post_h, 1})}
    }
  end

  @typedoc """
  Resolution context for `resolve/3`: the live display-frame dims the operand
  resolves against, the live storage-frame dims the carried point is stored in
  (equal to `display` when no orientation is pending), and the realized
  shrink-on-load factor (or `nil`).
  """
  @type resolve_ctx :: %{
          display: {pos_integer(), pos_integer()},
          storage: {pos_integer(), pos_integer()},
          decode_shrink: %{w: float(), h: float()} | nil
        }

  @doc """
  Resolve a `:set_focus` directive operand into a stored carried point.

  The operand (literal px, relative ratio, or anchor) is resolved against the
  live **display** frame, bare-pixel coordinates are rescaled by the
  shrink-on-load factor, positive out-of-bounds is clamped to the far edge
  (`dim-1`), and — when an orientation is pending — the display point is
  inverse-mapped into the live **storage** frame (so it rides the storage image
  like every other geometry value; the flush forward-maps it back). Negative
  coordinates never reach here (rejected by the parser's `Units`).
  """
  @spec resolve(operand(), resolve_ctx(), PendingOrientation.t() | nil) :: point()
  def resolve(operand, %{display: {dw, dh}, storage: {sw, sh}, decode_shrink: shrink}, po) do
    {sx, sy} = orient_shrink(shrink, po)
    x = resolve_axis(operand_x(operand), dw, sx)
    y = resolve_axis(operand_y(operand), dh, sy)

    if is_nil(po) or PendingOrientation.identity?(po) do
      {x, y}
    else
      {fx, fy} = inverse_fraction({ratio_div(x, dw), ratio_div(y, dh)}, po)
      {ratio_mul(fx, {:ratio, sw, 1}), ratio_mul(fy, {:ratio, sh, 1})}
    end
  end

  defp operand_x({:coord, x, _y}), do: x
  defp operand_x({:anchor, h, _v}), do: {:anchor_component, h}
  defp operand_y({:coord, _x, y}), do: y
  defp operand_y({:anchor, _h, v}), do: {:anchor_component, v}

  # Per-axis resolution against the display dim, then clamp to [0, dim-1].
  defp resolve_axis(axis, dim, shrink_factor) do
    axis
    |> resolve_axis_value(dim, shrink_factor)
    |> clamp_axis(dim)
  end

  defp resolve_axis_value({:px, n}, _dim, nil), do: {:ratio, n, 1}
  defp resolve_axis_value({:px, n}, _dim, shrink), do: {:ratio, max(0, round(n / shrink)), 1}
  defp resolve_axis_value({:ratio, n, d}, dim, _shrink), do: reduce(n * dim, d)

  defp resolve_axis_value({:anchor_component, near}, _dim, _shrink) when near in [:left, :top],
    do: {:ratio, 0, 1}

  defp resolve_axis_value({:anchor_component, :center}, dim, _shrink), do: reduce(dim, 2)

  defp resolve_axis_value({:anchor_component, far}, dim, _shrink) when far in [:right, :bottom],
    do: {:ratio, dim - 1, 1}

  defp clamp_axis({:ratio, n, d}, dim) do
    hi = dim - 1

    cond do
      n < 0 -> {:ratio, 0, 1}
      n > hi * d -> {:ratio, hi, 1}
      true -> reduce(n, d)
    end
  end

  # Shrink-on-load factors are storage-frame; under a pending quarter turn the
  # display axes are swapped, so swap the per-axis factors before applying them to
  # the display-frame px operand (mirrors PlanExecutor.orient_decode_shrink).
  defp orient_shrink(nil, _po), do: {nil, nil}

  defp orient_shrink(%{w: w, h: h}, po) do
    if not is_nil(po) and PendingOrientation.quarter_turn?(po), do: {h, w}, else: {w, h}
  end

  # ── orientation transforms on a normalized rational fraction ─────────────────
  # Mirrors ImagePipe.Transform.Orientation.forward_point/2 and its rotate_point/
  # flip_*_point rules, re-expressed on exact rationals (`1 - f` => {d - n, d}).

  @doc false
  @spec forward_fraction({ratio(), ratio()}, PendingOrientation.t()) :: {ratio(), ratio()}
  def forward_fraction(point, %PendingOrientation{} = po) do
    point
    |> rotate_fraction(po.exif_angle)
    |> flip_x_fraction(po.exif_flip_x)
    |> rotate_fraction(po.user_angle)
    |> flip_x_fraction(po.user_flip_x)
    |> flip_y_fraction(po.user_flip_y)
  end

  @doc false
  @spec inverse_fraction({ratio(), ratio()}, PendingOrientation.t()) :: {ratio(), ratio()}
  def inverse_fraction(point, %PendingOrientation{} = po) do
    point
    |> flip_y_fraction(po.user_flip_y)
    |> flip_x_fraction(po.user_flip_x)
    |> rotate_fraction(inverse_angle(po.user_angle))
    |> flip_x_fraction(po.exif_flip_x)
    |> rotate_fraction(inverse_angle(po.exif_angle))
  end

  defp inverse_angle(0), do: 0
  defp inverse_angle(90), do: 270
  defp inverse_angle(180), do: 180
  defp inverse_angle(270), do: 90

  defp rotate_fraction(point, 0), do: point
  defp rotate_fraction({u, v}, 90), do: {r_reflect(v), u}
  defp rotate_fraction({u, v}, 180), do: {r_reflect(u), r_reflect(v)}
  defp rotate_fraction({u, v}, 270), do: {v, r_reflect(u)}

  defp flip_x_fraction(point, false), do: point
  defp flip_x_fraction({u, v}, true), do: {r_reflect(u), v}

  defp flip_y_fraction(point, false), do: point
  defp flip_y_fraction({u, v}, true), do: {u, r_reflect(v)}

  # ── rationals ────────────────────────────────────────────────────────────────
  defp r_reflect({:ratio, n, d}), do: reduce(d - n, d)

  defp ratio_mul({:ratio, n, d}, {:ratio, n2, d2}), do: reduce(n * n2, d * d2)
  defp ratio_add_int({:ratio, n, d}, i), do: reduce(n + i * d, d)
  defp ratio_div({:ratio, n, d}, i), do: reduce(n, d * i)
  defp ratio_to_float({:ratio, n, d}), do: n / d

  defp reduce(n, d) do
    sign = if d < 0, do: -1, else: 1
    n = n * sign
    d = d * sign
    g = max(1, Integer.gcd(abs(n), d))
    {:ratio, div(n, g), div(d, g)}
  end

  defp clamp01(value), do: value |> max(0.0) |> min(1.0)
end
