defmodule ImagePipe.Transform.Geometry do
  @moduledoc false

  alias ImagePipe.Transform.State

  def image_height(%State{image: image}), do: Image.height(image)
  def image_width(%State{image: image}), do: Image.width(image)

  @type offset() :: number() | {:pixels, number()} | {:scale, number()}

  @spec resolve_dimension({:pixels, integer()}, pos_integer()) :: pos_integer()
  def resolve_dimension({:pixels, value}, reference), do: min(max(1, value), reference)

  @spec resolve_position({:pixels, integer()}) :: non_neg_integer()
  def resolve_position({:pixels, value}), do: max(0, value)

  # Pixel offsets arrive DPR-scaled. Percentage offsets use the live image.
  # Rounding happens when the crop composes the offset with its anchor.
  @spec resolve_offset(offset(), pos_integer()) :: float()
  def resolve_offset(value, _reference) when is_number(value), do: value * 1.0
  def resolve_offset({:pixels, value}, _reference), do: value * 1.0
  def resolve_offset({:scale, value}, reference), do: reference * value * 1.0

  # Crop positions and offsets round ties to even, matching imgproxy's RoundToEven.
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

  # Crop sizes round ties away from zero, matching imgproxy's CalcCropSize.
  # Positions and offsets use ties-to-even instead.
  def round_half_away_from_zero(value) when is_integer(value), do: value

  def round_half_away_from_zero(value) when is_float(value) and value < 0.0,
    do: -round_half_away_from_zero(-value)

  def round_half_away_from_zero(value) when is_float(value) do
    floor = Float.floor(value)
    fraction = value - floor
    floor = trunc(floor)

    if fraction < 0.5, do: floor, else: floor + 1
  end

  # Shared crop/canvas placement, matching imgproxy's ShrinkToEven(gap + 1, 2).
  # For odd gaps this places the origin one pixel farther than div(gap, 2).
  def center_origin(outer, inner), do: round_ties_to_even((outer - inner + 1) / 2)
end
