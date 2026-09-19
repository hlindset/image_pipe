defmodule ImagePipe.Representation do
  @moduledoc """
  Builds cache keys, ETags, and Vary header names before source fetch.

  `build/3` accepts opaque `source_identity` keyword material from
  `ImagePipe.Source.Resolved`, an `ImagePipe.Representation.IdentityMaterial`,
  and the source's `byte_identity`. Deriving identity from these inputs lets
  conditional GETs resolve before fetch, decode, or encode.

  ## Byte identity governs the ETag

  A source with strong byte identity contributes an `ETag`. A source with
  `byte_identity: :none` gets no ETag and `Cache-Control: no-store` from
  `response_headers/1`, preventing revalidation of potentially changed bytes.
  The HTTP, File, and S3 adapters use `:none` when no validator is available.

  The cache key and the ETag answer different questions and are derived from
  different (but overlapping) slices of the same data:

    * the **key** is storage identity — every input that can select a
      different stored variant, including `storage_only` (cachebuster +
      configured storage-vary values);
    * the **ETag** is a strong byte-identity validator — deliberately
      narrower, excluding `storage_only` so that changing a cachebuster or a
      vary-only input busts storage without forcing clients to re-download
      byte-identical content.

  Both digests go through `ImagePipe.MaterialDigest`.
  """

  use Boundary,
    top_level?: true,
    deps: [ImagePipe.Cache, ImagePipe.MaterialDigest],
    exports: [IdentityMaterial]

  alias ImagePipe.Cache.Key
  alias ImagePipe.MaterialDigest
  alias ImagePipe.Representation.IdentityMaterial

  @core_execution_epoch 1
  @etag_schema "ipr1"

  @enforce_keys [:cache_key, :etag, :vary, :no_store?]
  defstruct @enforce_keys

  # Mirrors Source.CacheSemantics without adding a Source dependency.
  # Representation owns the decision to withhold an ETag for `:none`.
  @type byte_identity :: {:strong, term()} | :none

  @type t :: %__MODULE__{
          cache_key: Key.t(),
          etag: String.t() | nil,
          vary: [String.t()],
          no_store?: boolean()
        }

  @doc """
  Builds the cache key, ETag, and Vary header names for a representation from
  `source_identity` (opaque keyword material identifying the source byte
  content), pre-fetch `material`, and the source's `byte_identity`.

  A `byte_identity` of `:none` withholds the ETag and marks the representation
  `no_store?` — see the moduledoc and `response_headers/1`. The cache key is
  computed regardless. A strong byte-identity seed contributes to both hashes,
  so a new byte revision invalidates stored output and conditional validators.
  """
  @spec build(source_identity :: keyword(), IdentityMaterial.t(), byte_identity()) :: t()
  def build(source_identity, %IdentityMaterial{} = material, byte_identity)
      when is_list(source_identity) do
    key_data = [
      representation_schema: 1,
      core_epoch: @core_execution_epoch,
      source_identity: source_identity,
      byte_identity: byte_identity,
      representation: material.representation,
      storage_only: material.storage_only
    ]

    no_store? = byte_identity == :none

    %__MODULE__{
      cache_key: %Key{hash: digest_hex(key_data), data: key_data},
      etag: if(no_store?, do: nil, else: etag(Keyword.delete(key_data, :storage_only))),
      vary: material.vary_header_names,
      no_store?: no_store?
    }
  end

  @doc """
  Returns the representation's `ETag`, or `Cache-Control: no-store` when the
  source has no stable byte identity.
  """
  @spec response_headers(t()) :: [{String.t(), String.t()}]
  def response_headers(%__MODULE__{no_store?: true}), do: [{"cache-control", "no-store"}]
  def response_headers(%__MODULE__{etag: etag}), do: [{"etag", etag}]

  @doc """
  Splits configured `storage_inputs` (header/cookie names from mount
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
