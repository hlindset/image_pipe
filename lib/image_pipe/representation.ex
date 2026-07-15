defmodule ImagePipe.Representation do
  @moduledoc """
  Builds a response's cache key, ETag, and Vary header names from categorized,
  pre-fetch identity material.

  `build/2` is the one-way seam a dialect uses to turn its own canonical
  request data into core-owned identity: it accepts only `source_identity`
  (opaque keyword material from `ImagePipe.Source.Resolved`) and a
  `%ImagePipe.Representation.IdentityMaterial{}` — both available before any
  source fetch. There is no function anywhere in this boundary (or any other)
  that builds a key or ETag from fetched bytes; that is what lets a
  conditional GET resolve before fetch, decode, or encode.

  The cache key and the ETag answer different questions and are derived from
  different (but overlapping) slices of the same data:

    * the **key** is storage identity — every input that can select a
      different stored variant, including `storage_only` (cachebuster +
      configured storage-vary values);
    * the **ETag** is a strong byte-identity validator — deliberately
      narrower, excluding `storage_only` so that changing a cachebuster or a
      vary-only input busts storage without forcing clients to re-download
      byte-identical content.

  Both digests go through `ImagePipe.MaterialDigest`; dialects never
  concatenate key material by hand.
  """

  use Boundary,
    top_level?: true,
    deps: [ImagePipe.Cache, ImagePipe.MaterialDigest],
    exports: [IdentityMaterial]

  alias ImagePipe.Cache.Key
  alias ImagePipe.MaterialDigest
  alias ImagePipe.Representation.IdentityMaterial

  # Successor of the framework's transform key-data version for this stack —
  # bumping it invalidates every representation built by every dialect,
  # independent of any single dialect's own `dialect_behavior` epoch.
  @core_execution_epoch 1
  @etag_schema "ipr1"

  @enforce_keys [:cache_key, :etag, :vary]
  defstruct @enforce_keys

  @type t :: %__MODULE__{
          cache_key: Key.t(),
          etag: String.t(),
          vary: [String.t()]
        }

  @doc """
  Builds the cache key, ETag, and Vary header names for a representation from
  `source_identity` (opaque keyword material identifying the source byte
  content) and pre-fetch `material`.
  """
  @spec build(source_identity :: keyword(), IdentityMaterial.t()) :: t()
  def build(source_identity, %IdentityMaterial{} = material) when is_list(source_identity) do
    key_data = [
      representation_schema: 1,
      core_epoch: @core_execution_epoch,
      dialect: material.dialect_behavior,
      source_identity: source_identity,
      representation: material.representation,
      storage_only: material.storage_only
    ]

    %__MODULE__{
      cache_key: %Key{hash: digest_hex(key_data), data: key_data},
      etag: etag(Keyword.delete(key_data, :storage_only)),
      vary: material.vary_header_names
    }
  end

  @doc """
  Splits configured `storage_inputs` (header/cookie names from dialect
  config) against `conn` into `{storage_only, vary_header_names}`:

    * a `{:header, name}` entry contributes its request value to
      `storage_only` *and* its normalized name to `vary_header_names`;
    * a `{:cookie, name}` entry contributes only its request value to
      `storage_only` (cookies never enter `Vary`, which names headers only).

  Header names are normalized case-insensitively (lowercased), deduplicated,
  and both outputs are deterministically ordered — identity material and Vary
  must not depend on the configured list's order or spelling.
  """
  @spec storage_inputs(Plug.Conn.t(), [{:header, String.t()} | {:cookie, String.t()}]) ::
          {storage_only :: keyword(), vary_header_names :: [String.t()]}
  def storage_inputs(%Plug.Conn{} = conn, configured) when is_list(configured) do
    conn = Plug.Conn.fetch_cookies(conn)

    header_names =
      configured
      |> Enum.flat_map(fn
        {:header, name} -> [String.downcase(name)]
        {:cookie, _name} -> []
      end)
      |> Enum.uniq()
      |> Enum.sort()

    headers = Enum.map(header_names, &{&1, Plug.Conn.get_req_header(conn, &1)})

    cookies =
      configured
      |> Enum.flat_map(fn
        {:cookie, name} -> [name]
        {:header, _name} -> []
      end)
      |> Enum.uniq()
      |> Enum.sort()
      |> Enum.flat_map(fn name ->
        case Map.fetch(conn.req_cookies, name) do
          {:ok, value} -> [{name, value}]
          :error -> []
        end
      end)

    {[headers: headers, cookies: cookies], header_names}
  end

  defp digest_hex(data), do: data |> MaterialDigest.of() |> Base.encode16(case: :lower)

  defp etag(data) do
    digest = data |> MaterialDigest.of() |> Base.url_encode64(padding: false)
    ~s("#{@etag_schema}-#{digest}")
  end
end
