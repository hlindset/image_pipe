defmodule ImagePipe.Transform.GeometryTest do
  use ExUnit.Case, async: true

  alias ImagePipe.Transform.Geometry

  describe "to_pixels/2" do
    test "resolves supported internal length units to pixels" do
      assert Geometry.to_pixels(100, {:scale, 1, 2}) == 50
      assert Geometry.to_pixels(100, {:percent, 25}) == 25
      assert Geometry.to_pixels(100, {:pixels, 12}) == 12
    end
  end

  describe "to_pixels/2 with {:ratio, n, d}" do
    test "resolves a ratio against a reference (half-away rounding, same as :scale)" do
      assert Geometry.to_pixels(200, {:ratio, 1, 2}) == 100
      assert Geometry.to_pixels(5, {:ratio, 1, 2}) == 3
      assert Geometry.to_pixels(300, {:ratio, 1, 3}) == 100
    end
  end
end
