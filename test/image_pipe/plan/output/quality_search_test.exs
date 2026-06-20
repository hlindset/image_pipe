defmodule ImagePipe.Plan.Output.QualitySearchTest do
  use ExUnit.Case, async: true
  alias ImagePipe.Plan.Output.QualitySearch

  test "builds a size objective with defaults for optional fields" do
    s = %QualitySearch{objective: :size, target: 10_240, min_quality: 10, max_quality: 80}
    assert s.allowed_error == 0
    assert s.format_min == %{}
    assert s.format_max == %{}
    assert s.max_resolution == 0
  end

  test "builds an ssim2 objective" do
    s = %QualitySearch{
      objective: :ssim2,
      target: 90.0,
      min_quality: 70,
      max_quality: 80,
      allowed_error: 1.0,
      format_min: %{avif: 60},
      format_max: %{avif: 65}
    }

    assert s.objective == :ssim2
    assert s.format_min == %{avif: 60}
  end

  test "enforces required keys" do
    assert_raise ArgumentError, fn -> struct!(QualitySearch, objective: :size, target: 1) end
  end
end
