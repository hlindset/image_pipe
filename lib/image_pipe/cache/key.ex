defmodule ImagePipe.Cache.Key do
  @moduledoc """
  Deterministic cache key data for processed image responses.

  Built by `ImagePipe.Representation.build/3`, which owns the derivation and
  the digest; adapters receive the resulting struct and treat `hash` as the
  storage identity and `data` as its canonical, inspectable material.
  """

  @enforce_keys [:hash, :data]

  defstruct @enforce_keys

  @type t :: %__MODULE__{
          hash: String.t(),
          data: keyword()
        }
end
