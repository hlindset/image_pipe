defmodule ImagePipe.Transform.RotateRoutingTest do
  use ExUnit.Case, async: true

  alias ImagePipe.Plan
  alias ImagePipe.Plan.Operation.Rotate, as: PlanRotate
  alias ImagePipe.Plan.Pipeline
  alias ImagePipe.Plan.Response
  alias ImagePipe.Transform
  alias ImagePipe.Transform.State

  defp run(ops) do
    {:ok, image} = Image.new(40, 20, color: [10, 20, 30])
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

  test "right-angle mirrored rotation routes to the chain op" do
    result = run([%PlanRotate{angle: 90, mirror: true}])
    assert Image.width(result) == 20 and Image.height(result) == 40
  end
end
