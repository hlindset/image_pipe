defmodule ImagePipe.MaterialDigest do
  # Deterministic digest of arbitrary identity material.
  #
  # Turns a term (the inputs that define an identity — cache key data, ETag
  # material) into a stable SHA-256 digest by recursively normalizing keyword
  # lists and map values so incidental ordering cannot change the result, serializing
  # deterministically, and hashing. Two equal-meaning inputs always produce the
  # same digest, so it is a stable identity. Callers own the final encoding (hex
  # for storage paths, base64 for ETag headers).
  #
  # Maps retain their type and exact keys, including compound keys. Map values
  # and struct fields are normalized recursively; plain list order is preserved.
  @moduledoc false

  use Boundary, top_level?: true, deps: [], exports: []

  @doc """
  SHA-256 digest of `material`'s order-stable serialization. Equal-meaning terms
  (regardless of map/keyword ordering) produce the same digest. Returns the raw
  digest; callers encode it.
  """
  @spec of(term()) :: binary()
  def of(material), do: material |> canonicalize() |> of_canonical()

  @doc """
  The order-stable form of `material` that `of/1` digests. A caller digesting
  several views of one term canonicalizes it once and digests each view with
  `of_canonical/1`. Keyword lists come back sorted by key.
  """
  @spec canonical(term()) :: term()
  def canonical(material), do: canonicalize(material)

  @doc "Digest of a term `canonical/1` returned, or a view of one."
  @spec of_canonical(term()) :: binary()
  def of_canonical(canonical),
    do: :crypto.hash(:sha256, :erlang.term_to_binary(canonical, [:deterministic]))

  defp canonicalize(value) when is_list(value), do: canonicalize_keyword(value, value, [])

  defp canonicalize(value) when is_map(value) do
    :maps.map(fn _key, item -> canonicalize(item) end, value)
  end

  defp canonicalize({first, second}), do: {canonicalize(first), canonicalize(second)}

  defp canonicalize(value) when is_tuple(value) do
    value
    |> Tuple.to_list()
    |> Enum.map(&canonicalize/1)
    |> List.to_tuple()
  end

  defp canonicalize(value), do: value

  # A keyword list is sorted by key, stably. Pairs are canonicalized while the
  # list still reads as one; anything else canonicalizes it as a plain list.
  defp canonicalize_keyword([{key, item} | rest], list, acc) when is_atom(key),
    do: canonicalize_keyword(rest, list, [{key, canonicalize(item)} | acc])

  defp canonicalize_keyword([], _list, acc), do: acc |> :lists.reverse() |> List.keysort(0)
  defp canonicalize_keyword(_other, list, _acc), do: canonicalize_list(list)

  defp canonicalize_list([]), do: []
  defp canonicalize_list([head | tail]), do: [canonicalize(head) | canonicalize_list(tail)]
  defp canonicalize_list(tail), do: canonicalize(tail)
end
