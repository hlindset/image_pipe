defmodule ImagePipe.Source.Resolved do
  @moduledoc """
  Validated source information returned by an adapter's `c:ImagePipe.Source.resolve/3`.

  Source adapters construct this value from canonical source intent. The
  `identity` and `cache_semantics` fields describe cache-safe source identity.
  `fetch` contains adapter-private data needed by the later fetch callback.
  `name` is the configured source that resolved this value. ImagePipe sets it
  after resolution, and it is `nil` for `{:file, _}` and `{:binary, _}`
  inputs. Adapters leave it unset.
  """

  alias ImagePipe.Source.CacheSemantics

  @enforce_keys [
    :identity,
    :internal_cache,
    :http_cache,
    :cache_semantics,
    :fetch
  ]
  defstruct [:name | @enforce_keys]

  @type internal_cache :: :enabled | :disabled
  @type http_cache :: :inherit | :validators | :auto | :public | :private

  @type t :: %__MODULE__{
          name: atom() | nil,
          identity: term(),
          internal_cache: internal_cache(),
          http_cache: http_cache(),
          cache_semantics: CacheSemantics.t(),
          fetch: term()
        }
end
