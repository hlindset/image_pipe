defmodule ImagePipe.Representation.IdentityMaterial do
  @moduledoc """
  Pre-fetch identity material passed to `ImagePipe.Representation.build/3`.

  Categorizes everything that can shape a response's identity into exactly
  the two buckets the cache key and ETag treat differently:

    * `representation` — byte-affecting data (feeds both the key and the
      ETag). Includes the canonical, normalized negotiation *outcome* (e.g.
      `{:image, :avif}`), never a raw header value.
    * `storage_only` — cachebuster plus configured storage-vary values (feeds
      the key only; excluded from the ETag, since it partitions storage
      without changing the bytes).

  `vary_header_names` are HTTP header names only (never cookie names) — the
  `Vary` response header names the response will emit.
  """

  @enforce_keys [:representation, :storage_only, :vary_header_names]
  defstruct @enforce_keys

  @type t :: %__MODULE__{
          representation: keyword(),
          storage_only: keyword(),
          vary_header_names: [String.t()]
        }
end
