defmodule ImagePipe.Plan.Output.QualitySearch.MetricTest do
  use ExUnit.Case, async: true

  alias ImagePipe.Plan.Output.QualitySearch.Metric

  describe "target_range/1" do
    test "ssimulacra2 is the 0-100 score range" do
      assert Metric.target_range(:ssimulacra2) == {0, 100}
    end

    test "butteraugli accepts target distances from 0.0 to 25.0" do
      assert Metric.target_range(:butteraugli) == {0.0, 25.0}
    end
  end

  describe "direction/1" do
    test "ssimulacra2 scores are higher-better" do
      assert Metric.direction(:ssimulacra2) == :higher_better
    end

    test "butteraugli distance is lower-better" do
      assert Metric.direction(:butteraugli) == :lower_better
    end
  end
end
