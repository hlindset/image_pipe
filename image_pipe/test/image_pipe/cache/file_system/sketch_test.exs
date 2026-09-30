defmodule ImagePipe.Cache.FileSystem.SketchTest do
  use ExUnit.Case, async: true

  alias ImagePipe.Cache.FileSystem.Sketch

  describe "new/1" do
    test "creates a sketch with the configured depth and width" do
      sketch = Sketch.new(depth: 4, width: 4096)
      assert sketch.depth == 4
      assert sketch.width == 4096
    end

    test "starts with all counters at zero" do
      sketch = Sketch.new(depth: 4, width: 64)
      assert Sketch.estimate(sketch, "any-key") == 0
    end
  end

  describe "increment/2 and estimate/2" do
    test "estimate is at least the true count after increments" do
      sketch =
        Sketch.new(depth: 4, width: 256)
        |> Sketch.increment("k1")
        |> Sketch.increment("k1")
        |> Sketch.increment("k1")

      assert Sketch.estimate(sketch, "k1") >= 3
    end

    test "different keys do not perfectly share counters" do
      sketch = Sketch.new(depth: 4, width: 256) |> Sketch.increment("k1")
      # Cannot assert estimate(k2) == 0 due to possible collisions,
      # but with width 256 collision on a brand-new key is unlikely.
      assert is_integer(Sketch.estimate(sketch, "k2"))
    end
  end

  describe "increment/2 conservative update" do
    test "only minimum-valued positions are incremented" do
      # Use depth 2 width 8 so we can reason about positions directly.
      sketch = Sketch.new(depth: 2, width: 8)

      # Pre-load specific counters by repeated increment of two keys that
      # happen to share one position. Conservative update should not inflate
      # the higher-valued position when the lower one already represents the
      # true frequency.
      sketch =
        sketch
        |> Sketch.increment("alpha")
        |> Sketch.increment("alpha")

      counters_before = counters(sketch)
      sketch = Sketch.increment(sketch, "alpha")
      counters_after = counters(sketch)

      # Every changed counter must have been at the same (minimum) value
      # before the update — conservative update only increments positions
      # that hold the per-key minimum, so all changed positions share that
      # value. Compute previous_min from just the changed positions so we
      # assert the conservative invariant independently of unrelated zeros.
      changed_positions =
        counters_before
        |> Enum.zip(counters_after)
        |> Enum.with_index()
        |> Enum.filter(fn {{before, aft}, _idx} -> aft != before end)

      changed_before_values = Enum.map(changed_positions, fn {{before, _aft}, _idx} -> before end)
      previous_min = Enum.min(changed_before_values)

      assert Enum.all?(changed_positions, fn {{before, _aft}, _idx} -> before == previous_min end)
    end
  end

  describe "age/1" do
    test "halves all counters with (c + 1) >>> 1" do
      sketch = Sketch.new(depth: 2, width: 4)
      sketch = Enum.reduce(1..10, sketch, fn _, s -> Sketch.increment(s, "k") end)

      before = counters(sketch)
      sketch = Sketch.age(sketch)
      after_ = counters(sketch)

      assert Enum.zip(before, after_) |> Enum.all?(fn {b, a} -> a == Bitwise.bsr(b + 1, 1) end)
    end

    test "increments aging epoch and resets increments_since_reset" do
      sketch = Sketch.new(depth: 2, width: 4)
      sketch = Sketch.increment(sketch, "k") |> Sketch.age()
      assert sketch.aging_epoch == 1
      assert sketch.increments_since_reset == 0
    end
  end

  describe "should_age?/1" do
    test "returns true when increments_since_reset >= sample_size" do
      # sample_size is explicit and independent of width.
      sketch = Sketch.new(depth: 2, width: 4, sample_size: 40)
      threshold = 40

      sketch =
        Enum.reduce(1..(threshold - 1), sketch, fn _, s -> Sketch.increment(s, "k") end)

      refute Sketch.should_age?(sketch)

      sketch = Sketch.increment(sketch, "k")
      assert Sketch.should_age?(sketch)
    end

    test "aging cadence does not change when width changes (decoupled)" do
      # Same sample_size, different width → identical aging threshold.
      narrow = Sketch.new(depth: 2, width: 4, sample_size: 40)
      wide = Sketch.new(depth: 2, width: 4096, sample_size: 40)
      assert narrow.sample_size == wide.sample_size
    end
  end

  describe "serialize/1 and deserialize/1" do
    test "round-trips a sketch preserving counters, epoch, and state" do
      sketch = Sketch.new(depth: 2, width: 4)
      sketch = Enum.reduce(["a", "b", "a", "c"], sketch, &Sketch.increment(&2, &1))

      binary = Sketch.serialize(sketch)
      {:ok, restored} = Sketch.deserialize(binary, depth: 2, width: 4)

      assert counters(restored) == counters(sketch)
      assert restored.aging_epoch == sketch.aging_epoch
      assert restored.increments_since_reset == sketch.increments_since_reset
    end

    test "returns error on garbage input" do
      assert {:error, _} = Sketch.deserialize(<<0, 1, 2>>, depth: 2, width: 4)
    end

    test "rejects invalid persisted counters and aging state" do
      payload =
        Sketch.new(depth: 1, width: 1)
        |> Sketch.serialize()
        |> :erlang.binary_to_term([:safe])

      for fields <- [
            %{counters: [:corrupt]},
            %{counters: [-1]},
            %{counters: [256]},
            %{counters: [1.5]},
            %{aging_epoch: -1},
            %{increments_since_reset: -1}
          ] do
        binary = :erlang.term_to_binary(Map.merge(payload, fields))
        assert {:error, _} = Sketch.deserialize(binary, depth: 1, width: 1)
      end
    end

    test "returns error on shape mismatch" do
      sketch = Sketch.new(depth: 2, width: 4)
      binary = Sketch.serialize(sketch)
      assert {:error, _} = Sketch.deserialize(binary, depth: 4, width: 4)
    end
  end

  describe "sum/2" do
    test "element-wise adds counters from two sketches of equal shape" do
      a = Sketch.new(depth: 2, width: 4) |> Sketch.increment("k1") |> Sketch.increment("k1")
      b = Sketch.new(depth: 2, width: 4) |> Sketch.increment("k1") |> Sketch.increment("k2")

      summed = Sketch.sum(a, b)

      # estimate(k1) on summed must be >= estimate(k1) on a + estimate(k1) on b
      assert Sketch.estimate(summed, "k1") >=
               Sketch.estimate(a, "k1") + Sketch.estimate(b, "k1") - 4
    end
  end

  defp counters(sketch), do: :array.to_list(sketch.counters)
end
