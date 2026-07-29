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

    test "returns a 32-byte SHA-256 digest" do
      assert byte_size(MaterialDigest.of(a: 1)) == 32
    end
  end

  property "serialization is deterministic for key-data-shaped material" do
    check all(material <- key_material(), max_runs: 100) do
      assert MaterialDigest.of(material) == MaterialDigest.of(material)
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

  defp key_material do
    gen all(
          identity <- list_of(path_segment(), min_length: 1, max_length: 4),
          operations <- list_of(operation_data(), max_length: 3),
          format <- member_of([:automatic, :webp, :avif, :jpeg, :png])
        ) do
      [
        schema_version: 2,
        source_identity: [kind: :path, root: "default", path: identity],
        pipelines: [operations],
        output: [mode: :explicit, format: format, quality: :default, format_qualities: %{}]
      ]
    end
  end

  defp operation_data do
    gen all(width <- integer(1..10_000), height <- one_of([constant(:auto), integer(1..10_000)])) do
      [
        op: :resize,
        mode: :fit,
        width: [unit: :logical_px, value: width],
        height: dimension_data(height),
        guide: :center,
        x_offset: {:pixels, 0.0},
        y_offset: {:pixels, 0.0}
      ]
    end
  end

  defp dimension_data(:auto), do: [unit: :auto]
  defp dimension_data(pixels), do: [unit: :logical_px, value: pixels]

  defp path_segment, do: string(:alphanumeric, min_length: 1, max_length: 16)
end
