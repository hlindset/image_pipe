defmodule ImagePipe.Cache.FileSystem.DoorkeeperUsageTest do
  @moduledoc """
  Smoke tests for our usage of `Talan.BloomFilter`. We don't re-test
  talan's correctness — we verify the specific API slice we depend on
  behaves as expected for our usage pattern.
  """
  use ExUnit.Case, async: true

  test "new + put + member? round-trip" do
    bf = Talan.BloomFilter.new(8192, false_positive_probability: 0.01)
    :ok = Talan.BloomFilter.put(bf, "key-1")
    assert Talan.BloomFilter.member?(bf, "key-1")
    refute Talan.BloomFilter.member?(bf, "key-not-present-yet")
  end

  test "reset via discard-and-allocate produces an empty filter" do
    bf = Talan.BloomFilter.new(8192, false_positive_probability: 0.01)
    :ok = Talan.BloomFilter.put(bf, "key-1")
    assert Talan.BloomFilter.member?(bf, "key-1")

    # Reset = create a new filter; old atomics ref becomes garbage.
    fresh = Talan.BloomFilter.new(8192, false_positive_probability: 0.01)
    refute Talan.BloomFilter.member?(fresh, "key-1")
  end

  test "put is mutative: same ref carries state forward" do
    # This documents (and guards) our reliance on the in-place semantics:
    # we hold one Talan.BloomFilter struct in Admission state and rely on
    # put mutating the underlying atomics ref.
    bf = Talan.BloomFilter.new(8192, false_positive_probability: 0.01)
    :ok = Talan.BloomFilter.put(bf, "alpha")
    :ok = Talan.BloomFilter.put(bf, "beta")
    assert Talan.BloomFilter.member?(bf, "alpha")
    assert Talan.BloomFilter.member?(bf, "beta")
  end
end
