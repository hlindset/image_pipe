defmodule ImagePipe.Transform.Geometry do
  @moduledoc false

  alias ImagePipe.Transform.State

  def image_height(%State{image: image}), do: Image.height(image)
  def image_width(%State{image: image}), do: Image.width(image)

  @type scalar() :: integer() | float()
  @type length_unit() ::
          scalar()
          | {:pixels, scalar()}
          | {:percent, scalar()}
          | {:scale, scalar()}
          | {:scale, scalar(), scalar()}
          | {:ratio, integer(), pos_integer()}

  @spec to_pixels(integer(), length_unit()) :: integer()
  def to_pixels(length, size_unit)
  def to_pixels(_length, num) when is_integer(num), do: num
  def to_pixels(_length, num) when is_float(num), do: round(num)
  def to_pixels(_length, {:pixels, num}), do: round(num)
  def to_pixels(length, {:scale, factor}), do: round(length * factor)

  def to_pixels(length, {:scale, numerator, denominator}),
    do: round(length * numerator / denominator)

  def to_pixels(length, {:ratio, numerator, denominator}),
    do: round(length * numerator / denominator)

  def to_pixels(length, {:percent, percent}), do: round(percent / 100 * length)

  def anchor_to_scale_units(focus, width, height) do
    x_scale =
      case focus do
        {:anchor, :left, _} -> {:scale, 0}
        {:anchor, :center, _} -> {:scale, 0.5}
        {:anchor, :right, _} -> {:scale, 1}
        {:coordinate, left, _top} -> {:scale, to_pixels(width, left) / width}
      end

    y_scale =
      case focus do
        {:anchor, _, :top} -> {:scale, 0}
        {:anchor, _, :center} -> {:scale, 0.5}
        {:anchor, _, :bottom} -> {:scale, 1}
        {:coordinate, _left, top} -> {:scale, to_pixels(height, top) / height}
      end

    {x_scale, y_scale}
  end

  def anchor_to_pixels(focus, width, height) do
    case anchor_to_scale_units(focus, width, height) do
      {x_scale, y_scale} ->
        {to_pixels(width, x_scale), to_pixels(height, y_scale)}
    end
  end

  # imgproxy `imath.RoundToEven`: round half to even (banker's rounding). imgproxy
  # composes integer origins with even-rounded offsets, so positions stay
  # integer-faithful only when ties round the same way.
  def round_ties_to_even(value) when is_integer(value), do: value

  def round_ties_to_even(value) when is_float(value) do
    floor = Float.floor(value)
    fraction = value - floor
    floor = trunc(floor)

    cond do
      fraction < 0.5 -> floor
      fraction > 0.5 -> floor + 1
      rem(floor, 2) == 0 -> floor
      true -> floor + 1
    end
  end

  # Centered placement of an `inner`-sized box in an `outer`-sized frame, mirroring
  # imgproxy calc_position.go: `ShrinkToEven(outer - inner + 1, 2)`. Shared by the
  # result crop and the canvas embed so the two place a centered rectangle
  # identically; the `+1` then round-half-to-even biases an odd gap toward the far
  # edge, where a plain `div(gap, 2)` floors toward the near edge.
  def center_origin(outer, inner), do: round_ties_to_even((outer - inner + 1) / 2)
end
