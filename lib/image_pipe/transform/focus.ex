defmodule ImagePipe.Transform.Focus do
  @moduledoc false
  # TwicPics carried focus point, transformed by each geometry op's realized
  # affine. An exact-rational continuous coordinate in the live-image frame; the
  # only float conversion is `to_fp/1`, at the libvips boundary. Every function
  # is a no-op when `state.focus == nil` (imgproxy never carries a focus), so the
  # imgproxy path is unaffected.
  #
  # The numerator is integer() (matching ImagePipe.Plan.Measure): a crop
  # translate can transiently negate it (focus left/above the crop window); a
  # later canvas embed brings it back in range. Only `to_fp/1` clamps.

  alias ImagePipe.Transform.PendingOrientation
  alias ImagePipe.Transform.State

  @type ratio :: {:ratio, integer(), pos_integer()}
  @type point :: {ratio(), ratio()}

  @spec scale(State.t(), ratio(), ratio()) :: State.t()
  def scale(%State{focus: nil} = state, _sx, _sy), do: state

  def scale(%State{focus: {x, y}} = state, sx, sy),
    do: %State{state | focus: {ratio_mul(x, sx), ratio_mul(y, sy)}}

  @spec translate(State.t(), integer(), integer()) :: State.t()
  def translate(%State{focus: nil} = state, _dx, _dy), do: state

  def translate(%State{focus: {x, y}} = state, dx, dy),
    do: %State{state | focus: {ratio_add_int(x, dx), ratio_add_int(y, dy)}}

  @spec to_fp(State.t()) :: nil | {:fp, float(), float()}
  def to_fp(%State{focus: nil}), do: nil

  def to_fp(%State{focus: {x, y}, image: image}) do
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
  def reflect_rotate(%State{focus: nil} = state, _po, _pre), do: state

  def reflect_rotate(%State{focus: {x, y}} = state, %PendingOrientation{} = po, {pre_w, pre_h}) do
    {fx2, fy2} = forward_fraction({ratio_div(x, pre_w), ratio_div(y, pre_h)}, po)
    {post_w, post_h} = if PendingOrientation.quarter_turn?(po), do: {pre_h, pre_w}, else: {pre_w, pre_h}
    %State{state | focus: {ratio_mul(fx2, {:ratio, post_w, 1}), ratio_mul(fy2, {:ratio, post_h, 1})}}
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
