defmodule ImagePipe.MaterialDigest do
  @moduledoc """
  Deterministic digest of arbitrary identity material.

  Turns a term (the inputs that define an identity — cache key data, ETag
  material) into a stable SHA-256 digest by recursively sorting maps and keyword
  lists so incidental ordering cannot change the result, serializing
  deterministically, and hashing. Two equal-meaning inputs always produce the
  same digest, so it is a stable identity. Callers own the final encoding (hex
  for storage paths, base64 for ETag headers).
  """

  use Boundary, top_level?: true, deps: [], exports: []

  @doc """
  SHA-256 digest of `material`'s order-stable serialization. Equal-meaning terms
  (regardless of map/keyword ordering) produce the same digest. Returns the raw
  digest; callers encode it.
  """
  @spec of(term()) :: binary()
  def of(material), do: :crypto.hash(:sha256, bytes(material))

  # Order-stable serialization: recursively sort maps and keyword lists, then
  # encode deterministically, so equal-meaning terms encode to equal bytes.
  defp bytes(material) do
    material
    |> canonicalize()
    |> :erlang.term_to_binary([:deterministic])
  end

  defp canonicalize(value) when is_list(value) do
    if Keyword.keyword?(value) do
      value
      |> Enum.map(fn {key, item} -> {canonicalize(key), canonicalize(item)} end)
      |> Enum.sort_by(fn {key, _item} -> key end)
    else
      Enum.map(value, &canonicalize/1)
    end
  end

  defp canonicalize(value) when is_map(value) do
    value
    |> Enum.map(fn {key, item} -> {canonicalize(key), canonicalize(item)} end)
    |> Enum.sort()
  end

  defp canonicalize(value) when is_tuple(value) do
    value
    |> Tuple.to_list()
    |> Enum.map(&canonicalize/1)
    |> List.to_tuple()
  end

  defp canonicalize(value), do: value
end
