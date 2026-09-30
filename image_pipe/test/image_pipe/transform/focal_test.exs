defmodule ImagePipe.Transform.FocalTest do
  use ExUnit.Case, async: true

  alias ImagePipe.Transform.Focal

  # Scene in a 100×100 image: a tall "person" box and a small "face" box high
  # inside it, sharing center x = 50. Vertical centroid is the discriminating axis.
  defp scene do
    [
      %{label: "person", score: 0.9, box: {30, 20, 40, 70}},
      %{label: "face", score: 0.9, box: {40, 20, 20, 20}}
    ]
  end

  test "uniform √area-weighted centroid (empty weights)" do
    assert {:ok, {:fp, fx, fy}} = Focal.weighted_centroid(scene(), 100, 100, %{})
    assert_in_delta fx, 0.5, 0.0001
    # √area: (52.915·55 + 20·30) / 72.915 ≈ 48.14
    assert_in_delta fy, 0.4814, 0.0005
  end

  test "a uniform default scalar does not move the centroid (cancels)" do
    {:ok, {:fp, ax, ay}} = Focal.weighted_centroid(scene(), 100, 100, %{})
    # A uniform global scalar cancels in the centroid for *any* value, not just
    # powers of two, so use a non-power-of-two default and compare per-coordinate
    # within a small epsilon rather than asserting bit-exact equality.
    {:ok, {:fp, bx, by}} = Focal.weighted_centroid(scene(), 100, 100, %{default: 3.0})
    assert_in_delta ax, bx, 1.0e-9
    assert_in_delta ay, by, 1.0e-9
  end

  test "returns :none when no box falls fully inside the image" do
    assert Focal.weighted_centroid([%{label: "x", box: {200, 200, 10, 10}}], 100, 100, %{}) ==
             :none
  end

  test "a missing label resolves to the default/1.0 weight" do
    regions = [%{box: {0, 0, 10, 10}}, %{box: {90, 90, 10, 10}}]
    assert {:ok, {:fp, fx, fy}} = Focal.weighted_centroid(regions, 100, 100, %{})
    assert_in_delta fx, 0.5, 0.0001
    assert_in_delta fy, 0.5, 0.0001
  end

  test "a class weight pulls the centroid toward that class" do
    {:ok, {:fp, _, fy_uniform}} = Focal.weighted_centroid(scene(), 100, 100, %{})
    {:ok, {:fp, _, fy_boost}} = Focal.weighted_centroid(scene(), 100, 100, %{"face" => 3.0})

    # face center y = 30 (above the person centroid), so a face boost lowers fy.
    assert fy_boost < fy_uniform
    # √area: (52.915·55 + 3·20·30) / (52.915 + 60) ≈ 41.72
    assert_in_delta fy_boost, 0.4172, 0.0005
  end
end
