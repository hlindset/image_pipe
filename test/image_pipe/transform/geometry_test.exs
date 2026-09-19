defmodule ImagePipe.Transform.GeometryTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias ImagePipe.Transform.Geometry

  property "resolved crop dimensions stay inside the source" do
    check all reference <- integer(1..6000),
              pixels <- integer(0..12_000) do
      dimension = Geometry.resolve_dimension({:pixels, pixels}, reference)
      assert dimension in 1..reference
    end
  end

  test "pixel offsets retain their fractional displacement until composition" do
    assert Geometry.resolve_offset({:pixels, 5.5}, 100) == 5.5
    assert Geometry.resolve_offset({:pixels, -3.0}, 100) == -3.0
  end

  test "percentage offsets use the current image extent" do
    assert Geometry.resolve_offset({:scale, 0.1}, 100) == 10.0
    assert Geometry.resolve_offset({:scale, -0.25}, 100) == -25.0
  end

  property "fractional sizes round half away from zero" do
    check all integer <- integer(-6000..6000) do
      positive = abs(integer) + 0.5
      assert Geometry.round_half_away_from_zero(positive) == abs(integer) + 1
      assert Geometry.round_half_away_from_zero(-positive) == -abs(integer) - 1
    end
  end

  property "offset half ties round to an even integer" do
    check all integer <- integer(-6000..6000) do
      rounded = Geometry.round_ties_to_even(integer + 0.5)
      assert rem(rounded, 2) == 0
      assert abs(rounded - (integer + 0.5)) == 0.5
    end
  end
end
