defmodule ImagePipe.Transform.Executor.GeometryTest do
  use ExUnit.Case, async: true

  alias ImagePipe.Transform.Executor.Geometry

  describe "crop_box/5" do
    test "shrinks the long axis to match the ratio" do
      assert Geometry.crop_box(100, 200, {:ratio, 1, 1}, false, {400, 400}) == {100, 100}
    end

    test "enlarge grows the short axis to match the ratio" do
      assert Geometry.crop_box(100, 200, {:ratio, 1, 1}, true, {400, 400}) == {200, 200}
    end

    test "an enlarged box scales into the image keeping the ratio" do
      assert Geometry.crop_box(100, 200, {:ratio, 1, 1}, true, {400, 150}) == {150, 150}
    end

    test "without a ratio the box only fits the image" do
      assert Geometry.crop_box(100, 200, nil, false, {400, 400}) == {100, 200}
      assert Geometry.crop_box(500, 0, nil, false, {400, 400}) == {400, 1}
    end

    # imgproxy resolves aspect-ratio-corrected crop sizes with imath.Scale,
    # rounding half away from zero: 201 * 0.5 = 100.5 gives 101, not 100.
    test "the corrected size rounds half away from zero" do
      assert Geometry.crop_box(300, 201, {:ratio, 1, 2}, false, {400, 300}) == {101, 201}
    end

    # Corrected 300x200 in a 300x103 image scales by 0.515: 300 * 0.515 = 154.5
    # gives 155, not 154.
    test "scaling into the image rounds half away from zero" do
      assert Geometry.crop_box(300, 100, {:ratio, 3, 2}, true, {300, 103}) == {155, 103}
    end
  end
end
