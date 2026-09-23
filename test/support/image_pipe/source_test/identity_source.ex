defmodule ImagePipe.SourceTest.IdentitySource do
  @moduledoc false
  use Boundary, top_level?: true, deps: [ImagePipe.Source]

  alias ImagePipe.Source.{CacheSemantics, Resolved, Response}
  @behaviour ImagePipe.Source

  @impl true
  def validate_options(opts), do: {:ok, opts}

  @impl true
  def resolve(source, opts, _runtime) do
    {:ok,
     %Resolved{
       adapter: :path,
       source_kind: :path,
       identity: [path: source.segments],
       internal_cache: :enabled,
       http_cache: :inherit,
       cache_semantics: %CacheSemantics{
         byte_identity: {:strong, Keyword.fetch!(opts, :seed)},
         stable?: true
       },
       fetch: Keyword.fetch!(opts, :bytes)
     }}
  end

  @impl true
  def fetch(resolved, opts, _runtime) do
    send(Keyword.fetch!(opts, :owner), :identity_source_fetch)
    {:ok, %Response{stream: [resolved.fetch]}}
  end
end
