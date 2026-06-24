defmodule ImagePipe.Plan.Output.QualitySearchTest do
  use ExUnit.Case, async: true
  alias ImagePipe.Plan.Output.QualitySearch

  test "builds a size search with defaults for optional fields" do
    s = %QualitySearch.Size{target: 10_240, min_quality: 10, max_quality: 80}
    assert s.format_min == %{}
    assert s.format_max == %{}
    assert s.max_resolution == 0
  end

  test "builds an ssimulacra2 search" do
    s = %QualitySearch.Ssimulacra2{
      target: 90.0,
      min_quality: 70,
      max_quality: 80,
      allowed_error: 1.0,
      format_min: %{avif: 60},
      format_max: %{avif: 65}
    }

    assert s.allowed_error == 1.0
    assert s.format_min == %{avif: 60}
  end

  test "builds a butteraugli search" do
    s = %QualitySearch.Butteraugli{
      target: 1.0,
      min_quality: 1,
      max_quality: 100,
      allowed_error: 0.1
    }

    assert s.allowed_error == 0.1
    assert s.format_min == %{}
    assert s.max_resolution == 0
  end

  test "enforces required keys" do
    assert_raise ArgumentError, fn -> struct!(QualitySearch.Size, target: 1) end
    assert_raise ArgumentError, fn -> struct!(QualitySearch.Ssimulacra2, target: 1.0) end
    assert_raise ArgumentError, fn -> struct!(QualitySearch.Butteraugli, target: 1.0) end
  end
end
