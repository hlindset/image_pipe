defmodule ImagePipe.Representation do
  # Builds cache keys, ETags, and Vary header names before source fetch.
  #
  # `build/3` accepts opaque `source_identity` keyword material from
  # `ImagePipe.Source.Resolved`, an `ImagePipe.Representation.IdentityMaterial`,
  # and the source's `byte_identity`. Deriving identity from these inputs lets
  # conditional GETs resolve before fetch, decode, or encode.
  #
  # The source's strong byte identity contributes to both the cache key and the
  # `ETag`, so a new byte revision invalidates stored output and validators.
  #
  # The cache key and the ETag answer different questions and are derived from
  # different (but overlapping) slices of the same data:
  #
  #   * the **key** is storage identity — every input that can select a
  #     different stored variant, including `storage_only` (cachebuster +
  #     configured storage-vary values);
  #   * the **ETag** is a strong byte-identity validator — deliberately
  #     narrower, excluding `storage_only` so that changing a cachebuster or a
  #     vary-only input busts storage without forcing clients to re-download
  #     byte-identical content.
  #
  # Both digests go through `ImagePipe.MaterialDigest`.
  @moduledoc false

  use Boundary,
    top_level?: true,
    deps: [ImagePipe.Cache, ImagePipe.MaterialDigest],
    exports: [IdentityMaterial]

  alias ImagePipe.Cache.Key
  alias ImagePipe.MaterialDigest
  alias ImagePipe.Representation.IdentityMaterial

  @etag_schema "ipr1"

  @enforce_keys [:cache_key, :etag, :vary]
  defstruct @enforce_keys

  @type byte_identity :: {:strong, term()}

  @type t :: %__MODULE__{
          cache_key: Key.t(),
          etag: String.t(),
          vary: [String.t()]
        }

  @doc """
  Builds the cache key, ETag, and Vary header names for a representation from
  `source_identity` (opaque keyword material identifying the source byte
  content), pre-fetch `material`, and the source's `byte_identity`. The seed
  contributes to both hashes, so a new byte revision invalidates stored output
  and conditional validators.
  """
  @spec build(source_identity :: keyword(), IdentityMaterial.t(), byte_identity()) :: t()
  def build(source_identity, %IdentityMaterial{} = material, byte_identity)
      when is_list(source_identity) do
    key_data = [
      representation_schema: 1,
      source_identity: source_identity,
      byte_identity: byte_identity,
      representation: material.representation,
      storage_only: material.storage_only
    ]

    # The ETag digests the key data without storage_only, so both come from one
    # canonical form.
    canonical = MaterialDigest.canonical(key_data)

    %__MODULE__{
      cache_key: %Key{hash: hex(canonical), data: key_data},
      etag: etag(Keyword.delete(canonical, :storage_only)),
      vary: material.vary_header_names
    }
  end

  @doc """
  Builds original-source storage identity independently of output operations.

  `fetch_context` describes the effective origin request, including headers
  and credentials that can select different source bytes. It is digested
  before entering key data. The cachebuster and configured storage partitions
  are shared with output storage; format, geometry, and output negotiation
  never enter this key. Origin Vary matching uses the effective fetch context,
  not headers from the downstream image request.
  """
  @spec input_key(keyword(), IdentityMaterial.t(), term()) :: Key.t()
  def input_key(source_identity, %IdentityMaterial{} = material, fetch_context) do
    data = [
      source_identity: source_identity,
      fetch_context: digest_hex(fetch_context),
      storage_only: material.storage_only
    ]

    %Key{hash: digest_hex([pool: :input] ++ data), data: data}
  end

  defp digest_hex(data), do: data |> MaterialDigest.canonical() |> hex()

  defp hex(canonical),
    do: canonical |> MaterialDigest.of_canonical() |> Base.encode16(case: :lower)

  defp etag(canonical) do
    digest = canonical |> MaterialDigest.of_canonical() |> Base.url_encode64(padding: false)
    ~s("#{@etag_schema}-#{digest}")
  end
end
