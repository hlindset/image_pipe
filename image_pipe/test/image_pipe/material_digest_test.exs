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

  # The canonical form digests were defined by when this property was
  # written. A faster canonicalization must give byte-identical digests, or
  # every stored cache key and issued ETag would change.
  property "digests match the reference canonicalization" do
    check all material <- identity_term(), max_runs: 500 do
      assert MaterialDigest.of(material) ==
               :crypto.hash(
                 :sha256,
                 :erlang.term_to_binary(reference(material), [:deterministic])
               )
    end
  end

  defp reference(value) when is_list(value) do
    if Keyword.keyword?(value) do
      value
      |> Enum.map(fn {key, item} -> {reference(key), reference(item)} end)
      |> Enum.sort_by(fn {key, _item} -> key end)
    else
      reference_list(value)
    end
  end

  defp reference(value) when is_map(value),
    do: :maps.map(fn _key, item -> reference(item) end, value)

  defp reference(value) when is_tuple(value),
    do: value |> Tuple.to_list() |> Enum.map(&reference/1) |> List.to_tuple()

  defp reference(value), do: value

  defp reference_list([]), do: []
  defp reference_list([head | tail]), do: [reference(head) | reference_list(tail)]
  defp reference_list(tail), do: reference(tail)

  # Keyword lists (including duplicate keys and near-keywords that end in a
  # non-pair), plain lists, improper lists, maps and tuples, nested.
  defp identity_term do
    leaf =
      one_of([atom(:alphanumeric), integer(), string(:alphanumeric, max_length: 4), boolean()])

    tree(leaf, fn child ->
      key = member_of([:a, :b, :c, :storage_only])

      one_of([
        list_of(tuple({key, child}), max_length: 4),
        map({list_of(tuple({key, child}), max_length: 3), child}, fn {pairs, last} ->
          pairs ++ [last]
        end),
        list_of(child, max_length: 4),
        map({child, child}, fn {head, tail} -> [head | tail] end),
        map_of(key, child, max_length: 3),
        tuple({child, child})
      ])
    end)
  end
end
