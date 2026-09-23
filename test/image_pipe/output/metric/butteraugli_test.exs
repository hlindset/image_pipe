defmodule ImagePipe.Output.Metric.ButteraugliTest do
  use ExUnit.Case, async: true
  alias ImagePipe.Output.Metric.Butteraugli

  test "distance is lower-better" do
    assert Butteraugli.direction() == :lower_better
  end

  test "identical images score near zero distance" do
    {:ok, img} = Image.new(64, 64, color: [120, 130, 140])
    {:ok, ref} = Butteraugli.reference(img)
    assert {:ok, score} = Butteraugli.score(ref, img)
    assert score < 0.5
  end
end
