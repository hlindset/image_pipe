defmodule ImagePipe.Cache.FileSystem.SketchPropertyTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias ImagePipe.Cache.FileSystem.Sketch

  property "estimate(k) is always >= true count of k" do
    check all keys <-
                list_of(string(:alphanumeric, min_length: 1, max_length: 16),
                  min_length: 0,
                  max_length: 200
                ) do
      sketch = Sketch.new(depth: 4, width: 256)
      sketch = Enum.reduce(keys, sketch, &Sketch.increment(&2, &1))
      counts = Enum.frequencies(keys)

      Enum.each(counts, fn {key, true_count} ->
        assert Sketch.estimate(sketch, key) >= true_count
      end)
    end
  end

  property "aging preserves relative ordering for keys with well-separated counts" do
    check all hot_key <- string(:alphanumeric, min_length: 1, max_length: 16),
              cold_key <- string(:alphanumeric, min_length: 1, max_length: 16),
              hot_key != cold_key do
      sketch = Sketch.new(depth: 4, width: 256)
      sketch = Enum.reduce(1..50, sketch, fn _, s -> Sketch.increment(s, hot_key) end)
      sketch = Sketch.increment(sketch, cold_key)

      hot_before = Sketch.estimate(sketch, hot_key)
      cold_before = Sketch.estimate(sketch, cold_key)
      assert hot_before > cold_before

      sketch = Sketch.age(sketch)
      hot_after = Sketch.estimate(sketch, hot_key)
      cold_after = Sketch.estimate(sketch, cold_key)
      assert hot_after >= cold_after
    end
  end
end
