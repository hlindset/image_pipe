defmodule ImagePipe.Plan.KeyDataTest do
  use ExUnit.Case, async: true

  alias ImagePipe.Plan.KeyData
  alias ImagePipe.Plan.Operation
  alias ImagePipe.Plan.Operation.Resize

  test "encodes percent and scale resize dimensions as exact ratios" do
    {:ok, %Resize{} = op} = Operation.resize(:fit, {:percent, 50}, {:scale, 0.5})
    data = KeyData.data(op)

    assert data[:width] == [unit: :ratio, numerator: 1, denominator: 2]
    assert data[:height] == [unit: :ratio, numerator: 1, denominator: 2]
  end

  test "whole-valued floats canonicalize to integers (50p and 50.0p share a key)" do
    {:ok, int_op} = Operation.resize(:fit, {:percent, 50}, {:scale, 2})
    {:ok, float_op} = Operation.resize(:fit, {:percent, 50.0}, {:scale, 2.0})

    assert KeyData.data(int_op) == KeyData.data(float_op)
    assert KeyData.data(int_op)[:width] == [unit: :ratio, numerator: 1, denominator: 2]

    # Genuinely fractional values keep their exact ratio form.
    {:ok, frac_op} = Operation.resize(:fit, {:percent, 50.5}, :auto)
    assert KeyData.data(frac_op)[:width] == [unit: :ratio, numerator: 101, denominator: 200]
  end

  test "percent and scale resize dimensions collapse to the same ratio key" do
    {:ok, percent_op} = Operation.resize(:fit, {:percent, 50}, :auto)
    {:ok, scale_op} = Operation.resize(:fit, {:scale, 0.5}, :auto)
    assert KeyData.data(percent_op) == KeyData.data(scale_op)
  end

  test "distinct relative magnitudes produce distinct key data" do
    {:ok, op50} = Operation.resize(:fit, {:percent, 50}, :auto)
    {:ok, op60} = Operation.resize(:fit, {:percent, 60}, :auto)

    refute KeyData.data(op50) == KeyData.data(op60)
  end

  test "directive key data hashes name and payload generically" do
    {:ok, op} = Operation.directive(:set_focus, {:coord, {:px, 1}, {:px, 2}})

    assert KeyData.data(op) ==
             [op: :directive, name: :set_focus, payload: {:coord, {:px, 1}, {:px, 2}}]
  end

  test "Resize key data includes max bounds and distinguishes them" do
    {:ok, bounded} =
      Operation.resize(:fit, :auto, :auto, max_width: 2000, max_area: 3_000_000)

    {:ok, unbounded} = Operation.resize(:fit, :auto, :auto)

    bounded_data = KeyData.data(bounded)
    unbounded_data = KeyData.data(unbounded)

    assert Keyword.get(bounded_data, :max_width) == 2000
    assert Keyword.get(bounded_data, :max_area) == 3_000_000
    assert Keyword.get(bounded_data, :max_height) == nil
    refute bounded_data == unbounded_data
  end
end
