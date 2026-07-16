defmodule ImagePipe.Representation do
  @moduledoc """
  Builds a response's cache key, ETag, and Vary header names from categorized,
  pre-fetch identity material.

  `build/3` is the one-way seam a dialect uses to turn its own canonical
  request data into core-owned identity: it accepts `source_identity` (opaque
  keyword material from `ImagePipe.Source.Resolved`), a
  `%ImagePipe.Representation.IdentityMaterial{}`, and the source's
  `byte_identity` — all available before any source fetch. There is no
  function anywhere in this boundary (or any other) that builds a key or ETag
  from fetched bytes; that is what lets a conditional GET resolve before fetch,
  decode, or encode.

  ## Byte identity governs the ETag

  A strong-byte-identity source contributes an `ETag`. A source whose bytes
  carry no stable identity (`byte_identity: :none` — reachable with the shipped
  `Source.HTTP`/`Source.File`/`Source.S3` adapters whenever the origin supplies
  no validator) gets **no** `ETag` and a `Cache-Control: no-store` directive
  (`response_headers/1`), so a conditional GET can never revalidate against
  content whose bytes may have changed. This is the sole boundary both dialects
  reach for that decision — it lives here rather than in each dialect so no
  dialect can re-ship the divergence. The framework's
  `ImagePipe.Request.HTTPCache` reproduces the identical decision on its own
  path (`cache_control_without_etag/2` / `do_generated_etag/4`).

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

  @enforce_keys [:cache_key, :etag, :vary, :no_store?]
  defstruct @enforce_keys

  # Mirrors `ImagePipe.Source.CacheSemantics.byte_identity/0` structurally so
  # the decision can live here without this boundary taking a dep on
  # `ImagePipe.Source`: the caller passes the plain term, this module owns the
  # `== :none` decision (the D5 discipline — one decision, one place).
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
  computed regardless (internal storage identity does not depend on HTTP byte
  identity).
  """
  @spec build(source_identity :: keyword(), IdentityMaterial.t(), byte_identity()) :: t()
  def build(source_identity, %IdentityMaterial{} = material, byte_identity)
      when is_list(source_identity) do
    key_data = [
      representation_schema: 1,
      core_epoch: @core_execution_epoch,
      dialect: material.dialect_behavior,
      source_identity: source_identity,
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
  The identity/cache response headers a dialect stamps for this representation.

  A strong-byte-identity representation contributes its `ETag`. A `no_store?`
  representation (a `:none` source) instead contributes `Cache-Control:
  no-store` and no `ETag` — routing both dialects through one decision so
  neither can 304 against changed content or let a shared cache store bytes
  with no stable identity.
  """
  @spec response_headers(t()) :: [{String.t(), String.t()}]
  def response_headers(%__MODULE__{no_store?: true}), do: [{"cache-control", "no-store"}]
  def response_headers(%__MODULE__{etag: etag}), do: [{"etag", etag}]

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
