defmodule ImagePipe.Source.CacheSemantics do
  @moduledoc """
  Source-owned cache facts used by internal and HTTP cache decisions.

  `byte_identity` seeds must be deterministic, non-secret, and stable across
  nodes for the same source bytes. The core validates the tagged shape but does
  not validate seed contents structurally.

  A strong byte identity is only valid when `stable?` is `true`. Sources that
  cannot provide a stable byte identity must use `byte_identity: :none` and
  `stable?: false`.
  """

  @enforce_keys [:byte_identity, :stable?]
  defstruct @enforce_keys ++ [policy: []]

  @type byte_identity :: {:strong, term()} | :none

  @type t :: %__MODULE__{
          byte_identity: byte_identity(),
          stable?: boolean(),
          policy: ImagePipe.Source.CachePolicy.t()
        }
end
