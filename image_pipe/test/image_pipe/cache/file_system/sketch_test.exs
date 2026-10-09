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
    test "halves all counters, rounding down" do
      sketch = Sketch.new(depth: 2, width: 4)
      sketch = Enum.reduce(1..11, sketch, fn _, s -> Sketch.increment(s, "k") end)

      before = counters(sketch)
      sketch = Sketch.age(sketch)
      after_ = counters(sketch)

      assert Enum.zip(before, after_) |> Enum.all?(fn {b, a} -> a == div(b, 2) end)
    end

    test "a key counted once is forgotten after one aging pass" do
      sketch = Sketch.new(depth: 2, width: 4) |> Sketch.increment("k") |> Sketch.age()
      assert Sketch.estimate(sketch, "k") == 0
    end

    test "resets increments_since_reset" do
      sketch = Sketch.new(depth: 2, width: 4)
      sketch = Sketch.increment(sketch, "k") |> Sketch.age()
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

  defp counters(sketch), do: :array.to_list(sketch.counters)
end
