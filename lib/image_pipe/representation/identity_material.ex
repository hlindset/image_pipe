defmodule ImagePipe.Representation.IdentityMaterial do
  @moduledoc """
  Pre-fetch identity material a dialect hands to `ImagePipe.Representation.build/3`.

  Categorizes everything that can shape a response's identity into exactly
  the two buckets the cache key and ETag treat differently:

    * `representation` — byte-affecting data (feeds both the key and the
      ETag). Includes the canonical, normalized negotiation *outcome* (e.g.
      `{:image, :avif}`), never a raw header value.
    * `storage_only` — cachebuster plus configured storage-vary values (feeds
      the key only; excluded from the ETag, since it partitions storage
      without changing the bytes).

  `dialect_behavior` is the emitting dialect's own module + behavioral epoch,
  so a dialect-side behavior change (a parser/pipeline semantics bump) rides
  both the key and the ETag independently of the core's own execution epoch.

  `vary_header_names` are HTTP header names only (never cookie names) — the
  `Vary` response header names the dialect will actually emit.
  """

  @enforce_keys [:representation, :storage_only, :dialect_behavior, :vary_header_names]
  defstruct @enforce_keys

  @type t :: %__MODULE__{
          representation: keyword(),
          storage_only: keyword(),
          dialect_behavior: {module(), pos_integer()},
          vary_header_names: [String.t()]
        }
end
