defmodule ImagePipe.Plan.Output.QualitySearch.MetricTest do
  use ExUnit.Case, async: true

  alias ImagePipe.Plan.Output.QualitySearch.Metric

  describe "target_range/1" do
    test "ssimulacra2 is the 0-100 score range" do
      assert Metric.target_range(:ssimulacra2) == {0, 100}
    end

    test "butteraugli is the jxlsave distance bound 0.0-25.0" do
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

  describe "single source of truth" do
    # The neutral spec is the *only* definition of each metric's range/direction:
    # the Output runtime modules derive from it rather than re-stating literals, so
    # the two cannot silently drift (the duplication issue #413 closes).
    test "Output.Metric runtime modules derive their range and direction from the spec" do
      pairs = [
        {ImagePipe.Output.Metric.Ssimulacra2, :ssimulacra2},
        {ImagePipe.Output.Metric.Butteraugli, :butteraugli}
      ]

      for {runtime, id} <- pairs do
        assert runtime.target_range() == Metric.target_range(id)
        assert runtime.direction() == Metric.direction(id)
      end
    end
  end
end
