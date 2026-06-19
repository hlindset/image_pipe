defmodule ImagePipe.Transform.GeometryTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias ImagePipe.Transform.Geometry

  describe "resolve_dimension/3" do
    property "half-away rounding: reference * n/d" do
      check all ref <- integer(1..6000),
                n <- integer(1..ref),
                d <- integer(1..6000) do
        result = Geometry.resolve_dimension({:ratio, n, d}, ref)
        expected = max(1, Geometry.round_half_away_from_zero(ref * n / d))
        assert result == expected
      end
    end

    property "clamp?: true never exceeds reference" do
      check all ref <- integer(1..6000),
                n <- integer(1..6000),
                d <- integer(1..6000) do
        result = Geometry.resolve_dimension({:ratio, n, d}, ref, clamp?: true)
        assert result <= ref
        assert result >= 1
      end
    end

    property "clamp?: false (default) may exceed reference" do
      check all ref <- integer(1..100),
                n <- integer(201..400),
                d <- integer(1..100) do
        result = Geometry.resolve_dimension({:ratio, n, d}, ref)
        assert result >= 1
        assert result > ref
      end
    end

    test "resolves {:px, n} with min-1 floor" do
      assert Geometry.resolve_dimension({:px, 50}, 100) == 50
      assert Geometry.resolve_dimension({:px, 50}, 100, clamp?: true) == 50
      assert Geometry.resolve_dimension({:px, 0}, 100) == 1
      assert Geometry.resolve_dimension({:px, -5}, 100) == 1
    end

    test "resolves {:pixels, n} with half-away and min-1 floor" do
      assert Geometry.resolve_dimension({:pixels, 50}, 100) == 50
      assert Geometry.resolve_dimension({:pixels, 2.5}, 100) == 3
      assert Geometry.resolve_dimension({:pixels, 0}, 100) == 1
    end

    test "resolves {:scale, n, d}" do
      assert Geometry.resolve_dimension({:scale, 1, 2}, 100) == 50
      assert Geometry.resolve_dimension({:scale, 1, 2}, 5) == 3
    end

    test "resolves {:scale, n}" do
      assert Geometry.resolve_dimension({:scale, 0.5}, 100) == 50
      assert Geometry.resolve_dimension({:scale, 0.5}, 5) == 3
    end

    test "clamp?: true caps at reference" do
      assert Geometry.resolve_dimension({:scale, 2, 1}, 100, clamp?: true) == 100
      assert Geometry.resolve_dimension({:pixels, 500}, 100, clamp?: true) == 100
    end

    test "floors to 1 (dimensions are always at least 1px)" do
      assert Geometry.resolve_dimension({:scale, 1, 10_000}, 1) == 1
    end
  end

  describe "resolve_position/2" do
    property "half-away rounding: reference * n/d, non-negative" do
      check all ref <- integer(1..6000),
                n <- integer(0..ref),
                d <- integer(1..6000) do
        result = Geometry.resolve_position({:ratio, n, d}, ref)
        expected = max(0, Geometry.round_half_away_from_zero(ref * n / d))
        assert result == expected
      end
    end

    test "resolves {:px, n}" do
      assert Geometry.resolve_position({:px, 0}, 100) == 0
      assert Geometry.resolve_position({:px, 50}, 100) == 50
    end

    test "resolves {:pixels, n}" do
      assert Geometry.resolve_position({:pixels, 0}, 100) == 0
      assert Geometry.resolve_position({:pixels, 50}, 100) == 50
    end

    test "resolves {:scale, n, d}" do
      assert Geometry.resolve_position({:scale, 0, 1}, 100) == 0
      assert Geometry.resolve_position({:scale, 1, 2}, 100) == 50
      assert Geometry.resolve_position({:scale, 1, 2}, 5) == 3
    end

    test "resolves {:ratio, n, d}" do
      assert Geometry.resolve_position({:ratio, 0, 1}, 100) == 0
      assert Geometry.resolve_position({:ratio, 1, 2}, 100) == 50
    end

    test "floors to 0 (positions are non-negative)" do
      assert Geometry.resolve_position({:px, 0}, 100) == 0
      assert Geometry.resolve_position({:ratio, 0, 1}, 100) == 0
    end
  end

  describe "resolve_offset/3" do
    test "bare number passes through as float (no rounding)" do
      assert Geometry.resolve_offset(5.5, 100, 1.0) == 5.5
      assert Geometry.resolve_offset(-3.0, 100, 1.0) == -3.0
      assert Geometry.resolve_offset(0, 100, 1.0) == 0.0
    end

    test "{:pixels, n} is DPR-scaled, not rounded" do
      assert Geometry.resolve_offset({:pixels, 10}, 100, 2.0) == 20.0
      assert Geometry.resolve_offset({:pixels, 5}, 100, 1.5) == 7.5
      assert Geometry.resolve_offset({:pixels, -8}, 100, 2.0) == -16.0
    end

    test "{:scale, n} is resolved as a float fraction of reference, not rounded" do
      assert Geometry.resolve_offset({:scale, 0.1}, 100, 1.0) == 10.0
      assert Geometry.resolve_offset({:scale, 0.1}, 100, 2.0) == 10.0
    end

    test "{:scale, n, d} is resolved as a float fraction of reference, not rounded" do
      assert Geometry.resolve_offset({:scale, 1, 10}, 100, 1.0) == 10.0
      assert Geometry.resolve_offset({:scale, 1, 10}, 100, 2.0) == 10.0
    end

    property "result is always a float (unrounded)" do
      check all n <- float(min: -200.0, max: 200.0) do
        assert is_float(Geometry.resolve_offset(n, 100, 1.0))
      end
    end
  end
end
