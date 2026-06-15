defmodule ImagePipe.Plan.MeasureTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias ImagePipe.Plan.Measure

  describe "from_percent/1" do
    test "integer percent reduces to a coprime ratio" do
      assert Measure.from_percent(50) == {:ok, {:ratio, 1, 2}}
      assert Measure.from_percent(100) == {:ok, {:ratio, 1, 1}}
      assert Measure.from_percent(0) == {:ok, {:ratio, 0, 1}}
    end

    test "float percent converts exactly via its decimal form" do
      assert Measure.from_percent(4.5) == {:ok, {:ratio, 9, 200}}
    end

    test "negative percent is rejected" do
      assert Measure.from_percent(-1) == {:error, :measure}
    end
  end

  describe "from_scale/1" do
    test "scale is a fraction of one" do
      assert Measure.from_scale(0.5) == {:ok, {:ratio, 1, 2}}
      assert Measure.from_scale(2) == {:ok, {:ratio, 2, 1}}
    end
  end

  describe "dimension/1 (extent: strictly positive)" do
    test "accepts positive px and ratio, rejects zero" do
      assert Measure.dimension({:px, 10}) == {:ok, {:px, 10}}
      assert Measure.dimension({:ratio, 1, 2}) == {:ok, {:ratio, 1, 2}}
      assert Measure.dimension({:px, 0}) == {:error, :dimension}
      assert Measure.dimension({:ratio, 0, 1}) == {:error, :dimension}
    end
  end

  describe "position/1 (coordinate: zero-based, non-negative)" do
    test "accepts zero and positive, rejects negative" do
      assert Measure.position({:px, 0}) == {:ok, {:px, 0}}
      assert Measure.position({:px, 10}) == {:ok, {:px, 10}}
      assert Measure.position({:ratio, 0, 1}) == {:ok, {:ratio, 0, 1}}
      assert Measure.position({:px, -1}) == {:error, :position}
    end
  end

  property "from_percent always yields a reduced, non-negative ratio" do
    check all n <- integer(0..10_000) do
      assert {:ok, {:ratio, num, den}} = Measure.from_percent(n)
      assert num >= 0 and den > 0
      assert Integer.gcd(num, den) == 1
    end
  end
end
