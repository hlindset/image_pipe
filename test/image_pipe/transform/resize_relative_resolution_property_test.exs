defmodule ImagePipe.Transform.ResizeRelativeResolutionPropertyTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias ImagePipe.Plan.Measure
  alias ImagePipe.Plan.Operation, as: PlanOperation
  alias ImagePipe.Transform.Operation.Resize

  property "ratio width resolves proportionally against the running width" do
    check all running <- integer(1..6000),
              percent <- integer(1..400) do
      {:ok, {:ratio, num, den}} = Measure.from_percent(percent)
      op = %Resize{mode: :fit, width: {:ratio, num, den}, height: :auto, enlarge: true}
      result = Resize.resolve_dimensions(op, source_width: running, source_height: running)

      # Exact: mirror the production computation order (Geometry.resolve_dimension
      # computes `round(length * num / den)` for a ratio), then the sub-pixel floor to 1.
      # Writing the operands in the SAME order avoids float-associativity drift
      # while keeping the assertion tight (delta 0).
      assert result.intermediate_width == max(1, round(running * num / den))
    end
  end

  property "scale height resolves proportionally against the running height" do
    check all running <- integer(1..6000),
              scale <- float(min: 0.01, max: 4.0) do
      {:ok, {:ratio, num, den}} = Measure.from_scale(scale)
      op = %Resize{mode: :fit, width: :auto, height: {:ratio, num, den}, enlarge: true}
      result = Resize.resolve_dimensions(op, source_width: running, source_height: running)

      assert result.intermediate_height == max(1, round(running * num / den))
    end
  end

  test "Plan constructor normalizes percent and scale sugar to an exact ratio" do
    assert {:ok, op} = PlanOperation.resize(:fit, {:percent, 50}, :auto)
    assert op.width == {:ratio, 1, 2}

    assert {:ok, op} = PlanOperation.resize(:fit, {:scale, 0.5}, :auto)
    assert op.width == {:ratio, 1, 2}
  end

  test "transform resolves a ratio dimension with Erlang half-away rounding" do
    op = %Resize{mode: :fit, width: {:ratio, 1, 2}, height: :auto, enlarge: true}
    result = Resize.resolve_dimensions(op, source_width: 5, source_height: 5)

    # round(5 * 1/2) = round(2.5) = 3 (half-away-from-zero)
    assert result.intermediate_width == 3
  end
end
