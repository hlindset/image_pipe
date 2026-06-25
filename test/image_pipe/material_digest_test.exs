defmodule ImagePipe.MaterialDigestTest do
  use ExUnit.Case, async: true

  alias ImagePipe.MaterialDigest

  describe "of/1" do
    test "is order-independent for maps" do
      assert MaterialDigest.of(%{a: 1, b: 2}) == MaterialDigest.of(%{b: 2, a: 1})
    end

    test "is order-independent for keyword lists" do
      assert MaterialDigest.of(a: 1, b: 2) == MaterialDigest.of(b: 2, a: 1)
    end

    test "is order-independent for nested maps/keywords" do
      one = [outer: %{x: [a: 1, b: 2], y: 3}]
      two = [outer: %{y: 3, x: [b: 2, a: 1]}]
      assert MaterialDigest.of(one) == MaterialDigest.of(two)
    end

    test "preserves order of plain (non-keyword) lists" do
      refute MaterialDigest.of([3, 1, 2]) == MaterialDigest.of([1, 2, 3])
    end

    test "distinguishes different terms" do
      refute MaterialDigest.of(a: 1) == MaterialDigest.of(a: 2)
    end

    test "returns a 32-byte SHA-256 digest" do
      assert byte_size(MaterialDigest.of(a: 1)) == 32
    end
  end
end
