defmodule ImagePipe.Source.CacheSemantics do
  @moduledoc """
  Source-owned cache facts used by internal and HTTP cache decisions.

  `byte_identity` seeds must be deterministic, non-secret, and stable across
  nodes for the same source bytes. The core validates the tagged shape but does
  not validate seed contents structurally.

  A strong byte identity is only valid when `stable?` is `true`. A source whose
  bytes can change uses `byte_identity: :content` and `stable?: false`: its
  identity is the SHA-256 of the original bytes, taken when they're fetched.

  `copy?` asks ImagePipe to keep a local copy of the original, in the input
  pool when `internal_cache` allows, so other variants of it don't read it from
  its origin again. Remote adapters set it. A source that returns a local path
  without it is read where it is, and hashed in place when it has a content
  identity.
  """

  @enforce_keys [:byte_identity, :stable?]
  defstruct @enforce_keys ++ [policy: [], copy?: false]

  @type byte_identity :: {:strong, term()} | :content

  @type t :: %__MODULE__{
          byte_identity: byte_identity(),
          stable?: boolean(),
          policy: ImagePipe.Source.CachePolicy.t(),
          copy?: boolean()
        }
end
