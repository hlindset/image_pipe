defmodule ImagePipe.Transform.RotateRoutingTest do
  use ExUnit.Case, async: true

  alias ImagePipe.Plan
  alias ImagePipe.Plan.Operation.Rotate, as: PlanRotate
  alias ImagePipe.Plan.Pipeline
  alias ImagePipe.Plan.Response
  alias ImagePipe.Transform
  alias ImagePipe.Transform.State
  alias Vix.Vips.Operation

  defp run(ops) do
    {:ok, image} = Image.new(40, 20, color: [10, 20, 30])
    run_on(image, ops)
  end

  defp run_on(image, ops) do
    plan = %Plan{
      source: nil,
      auto_rotate: false,
      pipelines: [%Pipeline{operations: ops}],
      output: nil,
      response: %Response{}
    }

    {:ok, %State{image: result}} =
      Transform.execute_plan(plan, %State{image: image})

    result
  end

  defp red_blue_40x20 do
    {:ok, left} = Image.new(20, 20, color: [255, 0, 0])
    {:ok, right} = Image.new(20, 20, color: [0, 0, 255])
    {:ok, joined} = Operation.join(left, right, :VIPS_DIRECTION_HORIZONTAL)
    joined
  end

  test "arbitrary angle routes to the chain op (bounding box grows, alpha added)" do
    result = run([%PlanRotate{angle: 45, mirror: false}])
    assert Image.width(result) > 40 and Image.height(result) > 20
    assert Image.has_alpha?(result)
  end

  test "right-angle non-mirrored rotation produces a lossless quarter turn" do
    result = run([%PlanRotate{angle: 90, mirror: false}])
    assert Image.width(result) == 20 and Image.height(result) == 40
    refute Image.has_alpha?(result)
  end

  test "right-angle mirrored rotation applies the mirror (differs from non-mirrored)" do
    img = red_blue_40x20()
    mirrored = run_on(img, [%PlanRotate{angle: 90, mirror: true}])
    plain = run_on(img, [%PlanRotate{angle: 90, mirror: false}])

    assert Image.width(mirrored) == 20 and Image.height(mirrored) == 40
    # Same geometry, but the horizontal flip before the turn changes pixel placement:
    # at least one sampled pixel must differ, proving the mirror was applied (not dropped).
    assert Image.get_pixel!(mirrored, 10, 5) != Image.get_pixel!(plain, 10, 5),
           "mirror not applied: mirrored and non-mirrored quarter turns are identical"
  end
end
