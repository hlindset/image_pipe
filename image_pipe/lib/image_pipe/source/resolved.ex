defmodule ImagePipe.Source.Resolved do
  @moduledoc """
  Validated source information returned by an adapter's `c:ImagePipe.Source.resolve/3`.

  Source adapters construct this value from canonical source intent. The
  `identity` and `cache_semantics` fields describe cache-safe source identity;
  `fetch` contains adapter-private data needed by the later fetch callback.
  `mount` is the name of the mount that resolved the source, set by
  ImagePipe after resolution (`nil` for direct `{:file, _}` and
  `{:binary, _}` inputs); adapters leave it unset.
  """

  alias ImagePipe.Source.CacheSemantics

  @enforce_keys [
    :source_kind,
    :identity,
    :internal_cache,
    :http_cache,
    :cache_semantics,
    :fetch
  ]
  defstruct [:mount | @enforce_keys]

  @type internal_cache :: :enabled | :disabled
  @type http_cache :: :inherit | :disabled | :enabled

  @type t :: %__MODULE__{
          mount: atom() | nil,
          source_kind: :path | :url | :object | :input,
          identity: term(),
          internal_cache: internal_cache(),
          http_cache: http_cache(),
          cache_semantics: CacheSemantics.t(),
          fetch: term()
        }
end
