defmodule ImagePipe.MaterialDigestTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

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

    test "preserves exact compound map keys" do
      first = %{[a: 1, b: 2] => :first, [b: 2, a: 1] => :second}
      second = %{[a: 1, b: 2] => :second, [b: 2, a: 1] => :first}
      refute MaterialDigest.of(first) == MaterialDigest.of(second)
    end

    test "accepts deterministic struct seeds" do
      refute MaterialDigest.of(~D[2026-09-23]) == MaterialDigest.of(~D[2026-09-24])
    end

    test "preserves improper list tails in term seeds" do
      refute MaterialDigest.of([1 | :revision]) == MaterialDigest.of([1, :revision])
      refute MaterialDigest.of([1 | :revision]) == MaterialDigest.of([1 | :other])
    end

    test "returns a 32-byte SHA-256 digest" do
      assert byte_size(MaterialDigest.of(a: 1)) == 32
    end
  end

  property "maps and lists remain distinct inside identity material" do
    check all revision <- integer(), label <- string(:alphanumeric) do
      map = %{revision: revision, label: label}
      refute MaterialDigest.of({:strong, map}) == MaterialDigest.of({:strong, Enum.sort(map)})
    end
  end

  property "nested map and keyword ordering does not affect the digest" do
    check all(
            identity <- list_of(path_segment(), min_length: 1, max_length: 4),
            width <- integer(1..10_000),
            max_runs: 100
          ) do
      one = [
        schema_version: 2,
        source_identity: [
          identity: identity,
          kind: :plain,
          nested: [map: %{b: 2, a: 1}, keyword: [b: 2, a: 1]]
        ],
        pipelines: [[[op: :contain, width: width, constraint: :max, letterbox: false]]],
        output: [mode: :explicit, format: :webp, quality: :default, format_qualities: %{}]
      ]

      two = [
        output: [format_qualities: %{}, quality: :default, format: :webp, mode: :explicit],
        pipelines: [[[letterbox: false, constraint: :max, width: width, op: :contain]]],
        source_identity: [
          nested: [keyword: [a: 1, b: 2], map: %{a: 1, b: 2}],
          kind: :plain,
          identity: identity
        ],
        schema_version: 2
      ]

      assert MaterialDigest.of(one) == MaterialDigest.of(two)
    end
  end

  defp path_segment, do: string(:alphanumeric, min_length: 1, max_length: 16)
end
