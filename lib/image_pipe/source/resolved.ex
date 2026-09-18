defmodule ImagePipe.Source.Resolved do
  @moduledoc """
  Validated source information returned by `ImagePipe.Source.resolve/3`.

  Source adapters construct this value from canonical source intent. The
  `identity` and `cache_semantics` fields describe cache-safe source identity;
  `fetch` contains adapter-private data needed by the later fetch callback.
  """

  alias ImagePipe.Source.CacheSemantics

  @enforce_keys [
    :adapter,
    :source_kind,
    :identity,
    :internal_cache,
    :http_cache,
    :cache_semantics,
    :fetch
  ]
  defstruct @enforce_keys

  @type internal_cache :: :enabled | :disabled
  @type http_cache :: :inherit | :disabled | :enabled

  @type t :: %__MODULE__{
          adapter: atom(),
          source_kind: :path | :url | :object | :reference,
          identity: term(),
          internal_cache: internal_cache(),
          http_cache: http_cache(),
          cache_semantics: CacheSemantics.t(),
          fetch: term()
        }
end
