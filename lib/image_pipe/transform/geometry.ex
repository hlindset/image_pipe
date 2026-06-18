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

  # resolve_dimension: "how big?" — half-away rounding, always >= 1.
  # clamp?: true adds min(result, reference) to keep within source bounds.
  # Callers: crop.ex (clamp?: true), resize.ex (clamp?: false), extend_canvas.ex.
  @spec resolve_dimension(term(), pos_integer(), keyword()) :: pos_integer()
  def resolve_dimension(measure, reference, opts \\ [])

  def resolve_dimension({:px, n}, reference, opts) when is_integer(n),
    do: apply_dimension_clamp(n, reference, opts)

  def resolve_dimension({:pixels, n}, reference, opts) when is_integer(n),
    do: apply_dimension_clamp(n, reference, opts)

  def resolve_dimension({:pixels, n}, reference, opts) when is_float(n),
    do: apply_dimension_clamp(max(1, round_half_away_from_zero(n)), reference, opts)

  def resolve_dimension({:scale, n, d}, reference, opts)
      when is_number(n) and is_number(d) and d != 0,
      do: apply_dimension_clamp(max(1, round_half_away_from_zero(reference * n / d)), reference, opts)

  def resolve_dimension({:scale, n}, reference, opts) when is_number(n) and n > 0,
    do: apply_dimension_clamp(max(1, round_half_away_from_zero(reference * n)), reference, opts)

  def resolve_dimension({:ratio, n, d}, reference, opts)
      when is_integer(n) and is_integer(d) and d > 0,
      do: apply_dimension_clamp(max(1, round_half_away_from_zero(reference * n / d)), reference, opts)

  def resolve_dimension(n, reference, opts) when is_integer(n) and n > 0,
    do: apply_dimension_clamp(n, reference, opts)

  def resolve_dimension(n, reference, opts) when is_float(n) and n > 0.0,
    do: apply_dimension_clamp(max(1, round_half_away_from_zero(n)), reference, opts)

  defp apply_dimension_clamp(value, reference, opts) do
    if Keyword.get(opts, :clamp?, false), do: min(value, reference), else: value
  end

  # resolve_position: "where?" — half-away rounding, always >= 0.
  # Positions are zero-based coordinates (top-left of image = 0).
  # Caller: crop.ex coordinate-crop origin.
  @spec resolve_position(term(), pos_integer()) :: non_neg_integer()
  def resolve_position({:px, n}, _reference) when is_integer(n), do: max(0, n)
  def resolve_position({:pixels, n}, _reference) when is_integer(n), do: max(0, n)

  def resolve_position({:pixels, n}, _reference) when is_float(n),
    do: max(0, round_half_away_from_zero(n))

  def resolve_position({:scale, n, d}, reference)
      when is_number(n) and is_number(d) and d != 0,
      do: max(0, round_half_away_from_zero(reference * n / d))

  def resolve_position({:ratio, n, d}, reference)
      when is_integer(n) and is_integer(d) and d > 0,
      do: max(0, round_half_away_from_zero(reference * n / d))

  def resolve_position(n, _reference) when is_integer(n), do: max(0, n)
  def resolve_position(n, _reference) when is_float(n), do: max(0, round_half_away_from_zero(n))

  # resolve_offset: "by how much?" — returns an unrounded float.
  # Rounding to even happens at composition time in crop.ex round_offset_to_even.
  # {:pixels} offsets are DPR-scaled; {:scale} offsets are resolved as a float
  # fraction of reference (no DPR — imgproxy's ScaleToEven path).
  @spec resolve_offset(term(), pos_integer(), float()) :: float()
  def resolve_offset(value, _reference, _dpr) when is_number(value), do: value * 1.0

  def resolve_offset({:pixels, value}, _reference, dpr) when is_number(value),
    do: value * dpr * 1.0

  def resolve_offset({:scale, value}, reference, _dpr) when is_number(value),
    do: reference * value * 1.0

  def resolve_offset({:scale, n, d}, reference, _dpr)
      when is_number(n) and is_number(d) and d != 0,
      do: reference * n / d * 1.0

  # resolve_focal: ratio -> normalized float clamped to 0.0..1.0.
  # Used to convert a {:ratio, n, d} focal-guide coordinate to a fraction.
  @spec resolve_focal({:ratio, non_neg_integer(), pos_integer()}, pos_integer()) :: float()
  def resolve_focal({:ratio, n, d}, _reference) when is_integer(n) and is_integer(d) and d > 0,
    do: (n / d) |> max(0.0) |> min(1.0)

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

  # imgproxy `imath.Scale` -> `imath.Round` -> Go `math.Round`: round half away
  # from zero. imgproxy resolves crop *sizes* (CalcCropSize, prepare.go) this way,
  # distinct from the ties-to-even rounding it uses for crop positions/offsets.
  def round_half_away_from_zero(value) when is_integer(value), do: value

  def round_half_away_from_zero(value) when is_float(value) and value < 0.0,
    do: -round_half_away_from_zero(-value)

  def round_half_away_from_zero(value) when is_float(value) do
    floor = Float.floor(value)
    fraction = value - floor
    floor = trunc(floor)

    if fraction < 0.5, do: floor, else: floor + 1
  end

  # Centered placement of an `inner`-sized box in an `outer`-sized frame, mirroring
  # imgproxy calc_position.go: `ShrinkToEven(outer - inner + 1, 2)`. Shared by the
  # result crop and the canvas embed so the two place a centered rectangle
  # identically; the `+1` then round-half-to-even biases an odd gap toward the far
  # edge, where a plain `div(gap, 2)` floors toward the near edge.
  def center_origin(outer, inner), do: round_ties_to_even((outer - inner + 1) / 2)
end
